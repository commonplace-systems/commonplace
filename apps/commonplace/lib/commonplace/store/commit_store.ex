defmodule Commonplace.Store.CommitStore do
  @moduledoc """
  The persistent storage layer for Commonplace's commit Merkle DAG —
  one singleton `GenServer` over a single CubDB instance at
  `<data_dir>/commits/`. Every observable change to every document in
  the workspace ends up here as a commit; nothing in the system
  reconstructs doc state without consulting this store.

  ## What's in the store

  CubDB is a single key/value space, partitioned by tuple-keyed
  namespaces:

      {:commit, commit_id}                  — the Commit struct itself.
      {:latest, doc_uuid}                   — pointer to the head commit
                                              on the local branch of
                                              `doc_uuid`'s DAG.
      {:merge_point, target, source}        — the source-side commit id
                                              that was last folded into
                                              `target` from `source`
                                              (incremental merge bound).
      {:last_merge_commit, target, source}  — the target-side commit id
                                              produced by that merge.
      {:latest_merge_head, target}          — most-recent target-side
                                              merge commit from *any*
                                              source. Used by red-channel
                                              audit / merge bookkeeping.
      {:attestation, attestation_id}        — gold-channel attestation
                                              records (CX-9rl).
      {:latest_attestation, doc_uuid}       — head of the attestation
                                              chain for `doc_uuid`.

  (Attestations are proof-of-authorship records on the **gold** color-
  channel — see `Commonplace.Dataflow.Channel` for the channel
  vocabulary. They live here because they must be durably bound
  alongside the commits they attest; `Commonplace.Gold.Chain` owns
  their API, CommitStore is only their durable tier.)

  Commits are append-only — `do_write_commit/6` and friends use
  `CubDB.put_multi/2` so the new `{:commit, id}` row and the
  `{:latest, doc_uuid}` advance land atomically. Commit-shaped rows
  (`{:commit, id}`, `{:attestation, id}`) are immutable once
  written; head pointers (`{:latest, _}`, `{:latest_attestation, _}`,
  `{:merge_point, _, _}`, `{:last_merge_commit, _, _}`,
  `{:latest_merge_head, _}`) are rewritten as the head advances.

  ## The `:latest` pointer

  `:latest` is the **local** head of a doc's DAG. It is per-node, not
  global. Two nodes in the same cluster can have different `:latest`
  for the same `doc_uuid` until catch-up sync runs; cross-node merging
  — reconciling two nodes' divergent `:latest` heads back into one — is
  a separate concern (see `Commonplace.Store.CrossEpochMerge`).

  Three operations touch `:latest`:

    1. **Local writes** (`create_commit`, `create_chained_commit`,
       `create_snapshot_commit`, `write_snapshot_cas`,
       `write_prebuilt_commit_cas`, `do_write_commit/6`) advance
       `:latest` to the new commit id, unconditionally for plain
       creates and conditionally for the CAS variants.
    2. **`set_latest/3`** — explicit re-point, used when a caller has
       already validated a commit and wants to install it as the new
       head (e.g. cross-epoch merge writes the merge commit, then
       calls `set_latest`).
    3. **`import_commit/3`** (catch-up sync, CX-bv3 / CX-ch5) —
       persists the commit row but **only** advances `:latest` when
       there is no existing `:latest` for that uuid. If a local
       `:latest` already exists, the imported commit is stored as a
       sibling (a divergent commit off a shared ancestor, kept but
       off the `:latest` linear walk) and `:latest` is left alone.
       This is what stops a remote catch-up burst from clobbering a
       newer local head.

  ## Chained vs imported writes

  These two paths exist because they serve different roles:

    * `create_commit/6` / `create_chained_commit/5` build a brand-new
      commit *here*. The commit is content-addressed at construction
      time (`Commit.new/4`), signed via the signing context (see
      "Signing" below), persisted, and `:latest` is moved to it.
      `create_chained_commit/5` reads the current `:latest` inside the
      same `handle_call` and uses it as `parent_id` — the read+write
      atomicity is the *whole point*; see CX-l7j below.
    * `import_commit/3` accepts a fully-formed `Commit{}` struct from
      a peer. The id is re-verified against the bytes via
      `Commit.verify_id/1` (CX-gwz — defends against a hostile peer
      retagging a delta as `kind: :snapshot` to skip history); the
      content is passed through a namespace validator (CX-ch5 — the
      default is `Namespace.validate_commit_from_db/2`, which checks
      the snapshot-parent chain for membership, rejecting a commit
      whose claimed lineage the node never authorized so a peer can't
      graft forged history onto a doc's namespace); on success the
      commit row is written and `:latest` is **only** advanced if the
      doc has no existing local head.

  Use `create_*` for local edits. Use `import_commit` for everything
  arriving over the wire — even if you're tempted to call
  `create_commit` because "the data's the same." Importing as a
  create clobbers a newer local `:latest` and silently orphans local
  work; see the CLAUDE.md note "use `import_commit` (not
  `create_commit`) when storing remote commits."

  ## Atomicity of `create_chained_commit/5` (CX-l7j)

  The "read latest, build a child off it, write the child" sequence
  must happen inside one `handle_call`. The original implementation
  split that across two GenServer calls — `latest_commit/2` followed
  by `create_commit/6` — which let two concurrent writers both
  observe the same `:latest`, both produce children rooted at the
  same parent, and both write. The second writer's `:latest` bump
  won and the first writer's commit, though persisted as a row, was
  silently dropped from every linear walk that started at `:latest`.
  Bundling the read+write under one mailbox slot serializes
  concurrent writers per doc and prevents that orphaning.

  Callers that don't need the "chain to current latest" semantics —
  e.g. snapshot construction that compares-and-swaps against an
  observed parent — use `write_snapshot_cas/5` or
  `write_prebuilt_commit_cas/2`, which encode the same atomicity
  with explicit CAS rejection (`{:error, :parent_moved}`) instead of
  silent re-anchoring.

  `import_commit/3` needs no such bundling. It doesn't derive a parent
  from a `:latest` read — the commit arrives with its `parent_id`
  already fixed — so there's no read-then-write window for two writers
  to race over. Its only `:latest` interaction is the conditional
  advance, itself serialized by the GenServer mailbox.

  ## Snapshots and the umbrella metadata (CX-6sc, CX-bgy, CX-u7p)

  Three layers of "snapshot" exist:

    1. `create_snapshot_commit/4` — primitive that chains a
       caller-supplied snapshot payload onto the current `:latest`
       and tags `kind: :snapshot`. Readers that know snapshots
       (notably `DocBuilder.reconstruct_doc/2`) short-circuit the
       backward walk on hitting one.
    2. `snapshot/2` — convenience that reconstructs the doc,
       generates a deterministic snapshot via
       `Snapshotter.build_snapshot/3`, and calls
       `create_snapshot_commit`. The deterministic-anyone property —
       `Snapshotter` is built to emit byte-identical output for the
       same parent state — means two nodes snapshotting the same
       parent produce byte-identical `update`s and `derivation_map`s,
       so *anyone* can mint the canonical snapshot.
    3. `write_snapshot_cas/5` — atomic CAS variant of #1. The caller
       (typically `Snapshotter`) has already built the payload and
       commits it iff `:latest` still equals `expected_parent_id`.
       Two callers that observed the same parent produce the same
       commit id (CX-umz deterministic-anyone) and the second write
       collapses to a no-op.

  The "umbrella" snapshot metadata (`snapshot_parents`,
  `derivation_map`, `snapshotter_version`) is built by `Snapshotter`
  and passed through verbatim. CommitStore stamps `kind: :snapshot`
  itself so callers cannot forget it.

  ## Genesis stamping (CX-fzi, CX-m3x, CX-a04)

  Every `:regular` commit needs a parent — either an earlier commit
  on the same DAG or the doc's deterministic genesis. Two pieces of
  back-fill machinery handle this:

    * `ensure_genesis/2` is the explicit primitive — `Commit.genesis/1`
      is a pure function of the uuid, so calling it twice returns the
      same struct and stores to the same id. `:latest` is **not**
      touched; this is just "make sure the genesis commit row exists."
    * `maybe_stamp_genesis/3` (private, write-side) — when a caller
      passes `parent_id = nil` for a uuid that has no `:latest`,
      stamp the genesis row and use its id as the parent.
      Pre-umbrella docs that already have a `:latest` keep the nil
      parent (legacy hatch — empty metadata, no `:kind`): back-filling
      a genesis ancestor beneath already-written history would change
      those commits' parent chains and ids, so the hatch deliberately
      leaves pre-umbrella docs untouched.
    * `maybe_stamp_snapshot_parent/3` (private, write-side, CX-a04) —
      `:regular` commits inherit `snapshot_parent` from the parent's
      `Namespace.current_namespace/1` unless the caller set one
      explicitly. Non-`:regular` and legacy-empty metadata are
      left untouched.

  ## PubSub broadcast contract (CX-4im)

  Every successful write fans out on **two** Phoenix.PubSub topics:

      "commits:<doc_uuid>"   {:commit, doc_uuid, commit.id, metadata}
      "blue:<doc_uuid>"      {:commit, doc_uuid, commit.id, metadata}

  Both topics carry the same message shape. The duality is a
  known wart documented in CX-4im — `commits:` is the historical
  storage-layer topic, `blue:` is the color-channel topic that
  `Tree.DocCache`, `WikiLive`, `TreeLive`, and other UI subscribers
  hang off of. Until they're unified, the write path emits both so
  that CommandRouter-initiated writes (MCP, CLI) reach UI subscribers
  the same way Document.Server edits do.

  Broadcast happens **after** the CubDB write returns. There is no
  rollback on PubSub failure — a subscriber that crashed will miss
  the event, and the durable record is the row in CubDB, not the
  broadcast.

  The CAS variants emit the same pair. `import_commit/3` deliberately
  does *not* broadcast — catch-up sync produces large bursts of
  commits and the historical subscribers (UI live views, DocCache)
  would re-reconstruct on every one. The catch-up path uses its own
  end-of-burst signal instead.

  Telemetry emits in parallel with PubSub:

      [:commonplace, :commit, :create]                        (writes)
      [:commonplace, :commit, :latest_read]                   (reads, CX-o8tx)
      [:commonplace, :commit, :rejected, :id_mismatch]        (CX-gwz)
      [:commonplace, :commit, :rejected, :namespace_mismatch] (CX-ch5)
      [:commonplace, :commit, :rejected, :unknown_reference]  (CX-fbs6)

  `:latest_read` exists so the reflog amortization tests
  (`Reflog.Snapshot`, CX-o8tx) can prove that clean subtrees were
  short-circuited without a read. Production cost is negligible
  when no handler is attached.

  ## Signing (CX-hoj, CX-o3r7)

  Commit signing is opt-in and per-write. `do_write_commit/6` calls
  `maybe_sign_commit/2` with the `:signing_context` option:

    * `%Commonplace.Crypto.SigningContext{}` — sign with the
      supplied identity + private key. MCP-bound sessions use this
      so commits attest to the agent's identity rather than the
      human's default key.
    * `:unsigned` — explicitly skip signing even when a global key
      is configured. MCP-MVP agent commits use this to avoid
      inheriting the human's identity.
    * `nil` (default) — fall back to the global
      `Commonplace.Store.SecretStore` key. If the SecretStore
      isn't running or has no key, the commit is unsigned.
      Preserved as legacy behavior for callers that haven't been
      updated.

  The CAS write paths (`write_snapshot_cas/5`,
  `write_prebuilt_commit_cas/2`) do **not** wire signing-context
  forwarding — snapshot construction happens above this layer and
  prebuilt commits are already assembled by the caller. This is a
  layering choice, not an idempotency constraint: signatures sit
  *outside* the content address (they never change a commit id), so
  the omission is only about where the signing context is threaded,
  not about keeping deterministic-anyone writes byte-identical. Signed
  callers route through `create_commit` / `create_chained_commit`.

  ## CommitStoreClient access discipline

  Callers should route through `Commonplace.Store.CommitStoreClient`,
  not call CommitStore directly. The client is a thin dispatcher that
  routes to either the local GenServer or a remote `serve` node
  depending on whether the CLI is running standalone or against a
  long-lived BEAM. Direct `CommitStore.foo/n` calls work when the
  process is local but silently break the "talk to serve" mode that
  the CLI uses to share a single CubDB across invocations.

  Tests can pass a custom server pid; the client normalizes its
  `server` argument so the CLI alias resolves to the real
  CommitStore but explicit pids pass through.

  ## CubDB crash recovery (`init/1`)

  CubDB occasionally fails to open after an unclean shutdown. Rather
  than crash the whole supervision tree on boot — which would brick
  the workspace — `init/1` probes the database with a small range
  scan, and on failure archives the corrupt dir to
  `<path>.corrupt.<unix-ts>` and starts fresh. This is **lossy** by
  design: a corrupt commits/ DB cannot be recovered in-process, and
  the alternative is an unbootable workspace. The
  `<path>.corrupt.<ts>` directory is preserved on disk for
  out-of-band recovery.

  The `open_cubdb/1` helper traps exits while starting CubDB so an
  init crash in CubDB itself doesn't take the GenServer down before
  the recovery branch runs. Any pending `:EXIT` message from a
  failed CubDB process is drained before the trap is restored.

  ## Merge bookkeeping

  Four keys track merge state per `(target, source)` pair:

    * `:merge_point` — the source-side commit id last folded in.
      Used by `Tree.Merge` to find the lower bound for an
      incremental three-way merge so re-merges skip already-folded
      commits.
    * `:last_merge_commit` — the target-side commit produced by
      that merge. Forms the upper bound used by audit / reflog.
    * `:latest_merge_head` — the same target-side id, but keyed by
      target alone. Answers "was this target ever merged from
      anywhere?" without iterating all sources.
    * Storage is direct K/V — no DAG walking required for these
      bookkeeping reads.

  ## Worked example

  A local edit, the orphan its split predecessor used to cause, and a
  clobber-safe import — for doc A whose `:latest` starts at `c1`:

      # 1. Local chained write.
      create_chained_commit(A, update, ...)
      #   reads :latest (c1) and writes child c2 INSIDE one handle_call,
      #   advances :latest -> c2, broadcasts on commits:A and blue:A.
      #   Because read+write share one mailbox slot, a second concurrent
      #   writer can't also read c1 and root a child there (CX-l7j) — it
      #   observes c2 and chains off it instead of orphaning c2.

      # 2. CAS snapshot — two nodes both observed parent c2.
      write_snapshot_cas(A, payload, expected_parent_id: c2)
      #   first writer: :latest still c2 -> writes snapshot s1, :latest -> s1.
      #   second writer: :latest now s1 (!= c2) -> {:error, :parent_moved},
      #   a clean no-op. Both nodes computed the same s1 id anyway
      #   (deterministic-anyone), so nothing is lost.

      # 3. Import a peer's sibling — clobber-protected.
      import_commit(%Commit{id: c3, parent_id: c1, ...})
      #   verify_id passes, namespace validator passes; c3 row is stored.
      #   A already has a local :latest (s1), so :latest is LEFT at s1
      #   and c3 is kept as a divergent sibling off c1 — newer local work
      #   is never silently replaced. A later Tree.Merge reconciles them.

  ## Invariants

    * Commits are immutable. `{:commit, id}` rows are never
      overwritten with new content (idempotent re-puts of the same
      bytes are fine).
    * `:latest` always points at a stored commit. Concurrent
      writers per doc are serialized through the GenServer mailbox.
    * Imported commits never clobber a present local `:latest`.
    * Every successful local write broadcasts on both
      `commits:<uuid>` and `blue:<uuid>`.
    * Every successful local write emits
      `[:commonplace, :commit, :create]` telemetry.
    * `verify_id/1` runs before any `import_commit` is trusted.

  ## What this module is NOT

    * **Not the CRDT layer.** Yelixer owns CRDT semantics; this
      module only stores opaque update bytes.
    * **Not the read path.** Reconstruction lives in
      `Tree.DocBuilder` (and cached results in `Tree.DocCache`);
      this module returns raw commits.
    * **Not the namespace validator.** That logic lives in
      `Commonplace.Store.Namespace`; CommitStore just wires it into
      `import_commit/3`.
    * **Not the merge engine.** `Tree.Merge` and
      `Store.CrossEpochMerge` compute merge updates; CommitStore
      stores their output.
    * **Not the signing engine.** `Commonplace.Crypto.Signing` does
      the actual signing; CommitStore decides *whether* to invoke
      it based on the per-call context.
    * **Not the remote transport.** `CommitStoreClient` handles
      local-vs-remote routing.
    * **Not the attestation API.** `Commonplace.Gold.Chain` owns the
      gold-channel attestation surface and calls into CommitStore's
      `{:store_attestation, ...}` / `{:latest_attestation, ...}` /
      `{:attestation_chain, ...}` handle_calls directly via
      `GenServer.call/2`. There are deliberately no public wrappers
      here — attestation verbs live with their owner; CommitStore is
      just the durable tier.

  ## Cross-version handle_call shapes

  Two pairs of `handle_call` clauses match arity-shorter tuples
  that no current public function emits:

      {:create_commit, doc_uuid, update, parent_id, metadata}
      {:create_chained_commit, doc_uuid, update, metadata}

  These exist for cross-version `GenServer.call/2` from older
  client builds (notably CLI escripts pinned to a pre-CX-o3r7
  release) connecting to a newer `serve` node. New clients always
  send the longer tuple with the trailing `opts` keyword list; old
  clients send the shorter shape and the handler delegates to the
  full path with `opts = []`. Drop these only after a release
  audit confirms no in-flight escripts still emit the short form.
  """

  use GenServer

  alias Commonplace.Store.Commit

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Persist a commit at a caller-supplied `parent_id` and advance
  `:latest` to it.

  The lowest-level write entry point — callers that already know
  exactly which commit they want to chain off use this. For the
  "chain off whatever is currently latest" semantics that virtually
  all local edits want, use `create_chained_commit/5` so the
  read+write is atomic (CX-l7j).

  `parent_id = nil` on a doc that has no prior `:latest` triggers
  deterministic-genesis stamping (CX-m3x): the genesis commit row
  is materialized and used as the parent. Pre-umbrella docs that
  already have a `:latest` retain legacy behavior — the nil parent
  is preserved.

  `opts[:signing_context]` selects the signing identity for this
  commit; see the module-level "Signing" section.
  """
  def create_commit(server \\ __MODULE__, doc_uuid, update, parent_id, metadata \\ %{}, opts \\ []) do
    GenServer.call(
      server,
      {:create_commit, doc_uuid, update, parent_id, metadata, opts}
    )
  end

  @doc """
  Create a commit that automatically chains to the latest commit on
  this UUID.

  CX-l7j: the read-latest + write-commit pair is atomicized inside a
  single `handle_call` so the GenServer mailbox serializes concurrent
  writers per-UUID. A prior split across two GenServer calls let two
  callers read the same `:latest`, both write chained to the same
  parent, and produce siblings — the second write's `:latest` bump won
  and the first was silently orphaned from linear walks.
  """
  def create_chained_commit(server \\ __MODULE__, doc_uuid, update, metadata \\ %{}, opts \\ []) do
    GenServer.call(server, {:create_chained_commit, doc_uuid, update, metadata, opts})
  end

  @doc """
  Create a snapshot commit (CX-u7p compaction primitive).

  Chains normally to the latest commit so replication walks back through
  history as usual, but tags the commit metadata with `kind: :snapshot`.
  Readers that know about snapshots (see `DocBuilder.reconstruct_doc/2`)
  short-circuit the backward walk on hitting one and apply only the
  snapshot plus any newer commits chained on top.

  The snapshot's `update` payload should be a self-contained Yjs update
  encoding the full materialized observable state under a single
  client_id (see `Yelixer.Doc.snapshot_update/1`). Applied to a fresh
  `Doc.new()`, it must reproduce the source doc's observable content.
  """
  def create_snapshot_commit(server \\ __MODULE__, doc_uuid, update, metadata \\ %{}) do
    metadata = Map.put(metadata, :kind, :snapshot)

    parent_id = case latest_commit(server, doc_uuid) do
      {:ok, commit} -> commit.id
      :none -> nil
    end

    create_commit(server, doc_uuid, update, parent_id, metadata)
  end

  @doc """
  Create an umbrella-shaped snapshot commit for `doc_uuid` (CX-6sc /
  CX-bgy build 5).

  Reconstructs the doc from its current `:latest`, emits a deterministic
  snapshot via `Yelixer.Doc.snapshot_update/1`, and tags the commit
  with the full umbrella metadata:

      %{kind: :snapshot,
        snapshot_parents: [namespace(parent)],
        derivation_map: %{source_snapshot_hash => %{new_id => old_id}},
        snapshotter_version: N}

  `namespace(parent)` is `Namespace.current_namespace(parent_commit)`
  — for a `:regular` parent this is the inherited `snapshot_parent`;
  for a `:genesis` or `:snapshot` parent it's the parent's own id.

  The MVP triggers on explicit caller invocation only — there is no
  automatic cadence. Two independent nodes snapshotting the same
  parent produce the same `update` bytes and the same `derivation_map`
  contents (deterministic-anyone property — see tests).

  Returns `{:ok, snapshot_commit}`, `{:error, :not_found}` if the doc has
  no `:latest` commit, or `{:error, {:nested_subtypes, names}}` if the doc
  carries CRDT sub-types nested inside maps/arrays that cannot be snapshotted
  without data loss (R5 guard, CX-tdkq.5 — refusing keeps the full chain).
  """
  def snapshot(server \\ __MODULE__, doc_uuid) do
    case latest_commit(server, doc_uuid) do
      :none ->
        {:error, :not_found}

      {:ok, parent} ->
        case Commonplace.Store.Snapshotter.build_snapshot(server, doc_uuid, parent) do
          {:ok, update_bytes, metadata} ->
            commit = create_snapshot_commit(server, doc_uuid, update_bytes, metadata)
            {:ok, commit}

          {:error, {:nested_subtypes, _names}} = error ->
            error
        end
    end
  end

  @doc """
  Atomically write a snapshot commit to `doc_uuid` iff the current
  `:latest` equals `expected_parent_id` (CX-4e2g).

  The compare-and-swap is performed inside the GenServer handle_call,
  so concurrent callers that observed the same parent produce the
  same commit id (deterministic-anyone, CX-umz) and collapse to a
  single write; callers whose observed parent has since been
  superseded receive `{:error, :parent_moved}` and can treat the
  operation as a no-op.

  The caller is responsible for computing `update` + `metadata` (via
  `Snapshotter.build_snapshot/3`). The `:kind => :snapshot` tag is
  stamped here so callers cannot forget it.
  """
  @spec write_snapshot_cas(GenServer.server(), String.t(), binary(), map(), binary()) ::
          {:ok, Commit.t()} | {:error, :parent_moved}
  def write_snapshot_cas(server \\ __MODULE__, doc_uuid, update, metadata, expected_parent_id) do
    GenServer.call(
      server,
      {:write_snapshot_cas, doc_uuid, update, metadata, expected_parent_id}
    )
  end

  @doc """
  Atomically persist a pre-built commit and advance `:latest` iff the
  current `:latest` for the commit's doc still matches `commit.parent_id`
  (CX-4qn1).

  Unlike `write_snapshot_cas/5`, the commit struct is already fully
  assembled by the caller — the caller is expected to have derived it
  from `Merger.merge/4` (or another byte-deterministic builder) so its
  content-addressed id is already bound to its parent. Two callers that
  observed the same `:latest` and merged against the same counterpart
  will produce the same commit id; the CAS makes the second writer a
  no-op. Callers whose `:latest` observation is stale get
  `{:error, :parent_moved}`.

  Idempotent for same-id re-writes: CubDB's `put_multi` collapses
  duplicates, and `:latest` is re-pointed to the same id.
  """
  @spec write_prebuilt_commit_cas(GenServer.server(), Commit.t()) ::
          {:ok, Commit.t()} | {:error, :parent_moved}
  def write_prebuilt_commit_cas(server \\ __MODULE__, %Commit{} = commit) do
    GenServer.call(server, {:write_prebuilt_commit_cas, commit})
  end

  @doc """
  Return a MapSet of every commit id persisted for `doc_uuid`, including
  commits that are NOT reachable from `:latest` (i.e. siblings imported
  via `import_commit/2` that have no descendant on the local head's
  chain). Unlike `commit_ids_for_doc/2`, this scans the commit index
  rather than walking backward from `:latest`, so it finds siblings
  that were imported but never merged in.
  """
  @spec all_commit_ids_for_doc(GenServer.server(), String.t()) :: MapSet.t()
  def all_commit_ids_for_doc(server \\ __MODULE__, doc_uuid) do
    do_all_commit_ids_for_doc(resolve_db(server), doc_uuid)
  end

  @doc """
  Look up a single commit by id. Returns `{:ok, commit}` or `:none`.
  Does not walk the DAG and does not consult `:latest` — pure
  point-read on the `{:commit, id}` row.
  """
  def get_commit(server \\ __MODULE__, commit_id) do
    do_get_commit(resolve_db(server), commit_id)
  end

  @doc """
  Return the local head commit for `doc_uuid` as `{:ok, commit}`,
  or `:none` if the doc has no `:latest` entry on this node.

  Emits a `[:commonplace, :commit, :latest_read]` telemetry event so
  the reflog amortization tests (CX-o8tx) can prove that clean
  subtrees were short-circuited without a read.
  """
  def latest_commit(server \\ __MODULE__, doc_uuid) do
    do_latest_commit(resolve_db(server), doc_uuid)
  end

  @doc "Walk the commit chain for a doc, returning commits newest-first."
  def commit_log(server \\ __MODULE__, doc_uuid, opts \\ []) do
    do_commit_log(resolve_db(server), doc_uuid, opts)
  end

  @doc "Return a MapSet of all document UUIDs that have a `:latest` entry."
  def all_doc_uuids(server \\ __MODULE__) do
    do_all_doc_uuids(resolve_db(server))
  end

  @doc "Check if `ancestor_id` is an ancestor of `descendant_id` in the commit DAG."
  def is_ancestor?(server \\ __MODULE__, ancestor_id, descendant_id) do
    do_is_ancestor(resolve_db(server), ancestor_id, descendant_id)
  end

  @doc """
  Point `doc_uuid`'s `:latest` at an existing commit without
  creating a new one. The caller is responsible for ensuring the
  target commit is already persisted and that re-pointing is
  causally safe — there is no ancestry check here.

  Used by cross-epoch merge to install a pre-built merge commit
  (CX-fdjh) and by tests that need to construct specific DAG
  shapes. Not a substitute for the CAS variants when concurrent
  writers might race.
  """
  def set_latest(server \\ __MODULE__, doc_uuid, commit_id) do
    GenServer.call(server, {:set_latest, doc_uuid, commit_id})
  end

  @doc "Return a MapSet of all commit IDs for a document (walks the chain)."
  def commit_ids_for_doc(server \\ __MODULE__, doc_uuid) do
    collect_commit_ids(resolve_db(server), doc_uuid)
  end

  @doc """
  Idempotently stamp the deterministic genesis commit for `doc_uuid`
  (CX-fzi). Returns `{:ok, genesis}`.

  Genesis is a pure function of `doc_uuid` (see `Commit.genesis/1`), so
  two calls for the same uuid return the same commit and store to the
  same id. `:latest` is NOT touched — callers wire genesis in as the
  parent of the first real commit themselves (deferred to the bead that
  flips on namespace validation). This is the primitive; auto-wiring
  into `create_commit` is explicitly out of scope for CX-fzi.
  """
  def ensure_genesis(server \\ __MODULE__, doc_uuid) do
    GenServer.call(server, {:ensure_genesis, doc_uuid})
  end

  @doc """
  Store a commit without updating :latest. Used for catch-up sync.

  Accepts an optional `:validator` keyword function of arity 1 that
  receives the incoming commit and returns `:ok | {:error, reason}`.
  When rejected, the commit is NOT persisted and `:latest` is NOT
  modified (CX-bv3). The default validator is a no-op stub that
  accepts every commit; CX-ch5 replaces the default with the real
  Yelixer namespace-membership check once the primitive lands.
  """
  def import_commit(server \\ __MODULE__, commit, opts \\ []) do
    GenServer.call(server, {:import_commit, commit, opts})
  end

  @doc """
  Legacy pass-through — retained for back-compat.

  Prior to CX-ch5 this was the default validator; the real default is
  now `Commonplace.Store.Namespace.validate_commit_from_db/2`, invoked
  directly from `handle_call({:import_commit, ...})` with the state's
  CubDB handle. Callers that still pass this function explicitly via
  `validator:` get stub pass-through behavior, matching the pre-swap
  contract.
  """
  def default_namespace_validator(_commit), do: :ok

  @doc "Find the most recent common ancestor between two UUID chains."
  def find_common_ancestor(server \\ __MODULE__, uuid_a, uuid_b) do
    do_find_common_ancestor(resolve_db(server), uuid_a, uuid_b)
  end

  @doc "Store the commit ID of the source at the time of a merge, for incremental merging."
  def set_merge_point(server \\ __MODULE__, target_uuid, source_uuid, commit_id) do
    GenServer.call(server, {:set_merge_point, target_uuid, source_uuid, commit_id})
  end

  @doc "Retrieve the stored merge point commit ID for a (target, source) pair."
  def get_merge_point(server \\ __MODULE__, target_uuid, source_uuid) do
    CubDB.get(resolve_db(server), {:merge_point, target_uuid, source_uuid})
  end

  @doc "Record the target's head commit after any merge (keyed by target+source and target-only)."
  def set_last_merge_commit(server \\ __MODULE__, target_uuid, source_uuid, commit_id) do
    GenServer.call(server, {:set_last_merge_commit, target_uuid, source_uuid, commit_id})
  end

  @doc "Get the target's head commit after the most recent merge from any source."
  def get_latest_merge_head(server \\ __MODULE__, target_uuid) do
    CubDB.get(resolve_db(server), {:latest_merge_head, target_uuid})
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    data_dir = Keyword.fetch!(opts, :data_dir)
    path = Path.join(data_dir, "commits")
    File.mkdir_p!(path)

    case open_cubdb(path) do
      {:ok, db} ->
        case probe_integrity(db) do
          :ok ->
            ready(name, db)

          {:error, reason} ->
            require Logger
            Logger.warning("CubDB corrupt on probe (#{inspect(reason)}). Archiving and starting fresh.")
            CubDB.stop(db)
            recover_cubdb(name, path)
        end

      {:error, reason} ->
        require Logger
        Logger.warning("CubDB failed to open (#{inspect(reason)}). Archiving and starting fresh.")
        recover_cubdb(name, path)
    end
  end

  # R4(a): publish the CubDB handle so reads can run in the caller process
  # against it directly, never queuing behind a write in this GenServer's
  # mailbox (CX-tdkq.4). Keyed by the registered name so isolated test stores
  # and the production singleton don't collide; resolve_db/1 falls back to a
  # cheap `:get_db` call for callers that hold a pid rather than the name.
  defp ready(name, db) do
    :persistent_term.put({__MODULE__, :db, name}, db)
    # pending_imports (R11 / CX-tdkq.11): commits that failed namespace
    # validation because a commit they reference hasn't landed yet. Held and
    # retried after each successful import, so out-of-order delivery (PubSub
    # + catch-up interleaving) no longer drops legitimate commits. In-memory:
    # on restart, catch-up sync re-sends. commit.id => {commit, opts}.
    {:ok, %{db: db, name: name, pending_imports: %{}}}
  end

  @impl true
  def terminate(_reason, %{name: name}) do
    :persistent_term.erase({__MODULE__, :db, name})
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp open_cubdb(path) do
    # Trap exits so CubDB init crashes don't kill us
    old_trap = Process.flag(:trap_exit, true)

    result =
      try do
        CubDB.start_link(
          data_dir: path,
          auto_file_sync: true,
          auto_compact: true
        )
      rescue
        e -> {:error, e}
      catch
        :exit, reason -> {:error, reason}
        kind, reason -> {:error, {kind, reason}}
      end

    # Drain any EXIT message from the failed CubDB process
    receive do
      {:EXIT, _pid, _reason} -> :ok
    after
      0 -> :ok
    end

    Process.flag(:trap_exit, old_trap)
    result
  end

  defp recover_cubdb(name, path) do
    archive_corrupt_db(path)

    {:ok, db} =
      CubDB.start_link(
        data_dir: path,
        auto_file_sync: true,
        auto_compact: true
      )

    ready(name, db)
  end

  @impl true
  def handle_call({:create_commit, doc_uuid, update, parent_id, metadata}, _from, state) do
    commit = do_write_commit(state, doc_uuid, update, parent_id, metadata, [])
    {:reply, commit, state}
  end

  @impl true
  def handle_call(
        {:create_commit, doc_uuid, update, parent_id, metadata, opts},
        _from,
        state
      ) do
    commit = do_write_commit(state, doc_uuid, update, parent_id, metadata, opts)
    {:reply, commit, state}
  end

  @impl true
  def handle_call(
        {:write_snapshot_cas, doc_uuid, update, metadata, expected_parent_id},
        _from,
        state
      ) do
    case CubDB.get(state.db, {:latest, doc_uuid}) do
      ^expected_parent_id ->
        metadata = Map.put(metadata, :kind, :snapshot)

        commit =
          Commit.new(doc_uuid, update, expected_parent_id, metadata) |> maybe_sign_commit()

        CubDB.put_multi(state.db, [
          {{:commit, commit.id}, commit},
          {{:latest, doc_uuid}, commit.id}
        ])

        :telemetry.execute(
          [:commonplace, :commit, :create],
          %{system_time: System.system_time()},
          %{doc_uuid: doc_uuid}
        )

        Phoenix.PubSub.broadcast(
          Commonplace.PubSub,
          "commits:#{doc_uuid}",
          {:commit, doc_uuid, commit.id, metadata}
        )

        Phoenix.PubSub.broadcast(
          Commonplace.PubSub,
          "blue:#{doc_uuid}",
          {:commit, doc_uuid, commit.id, metadata}
        )

        {:reply, {:ok, commit}, state}

      _other ->
        {:reply, {:error, :parent_moved}, state}
    end
  end

  @impl true
  def handle_call({:write_prebuilt_commit_cas, %Commit{} = commit}, _from, state) do
    case CubDB.get(state.db, {:latest, commit.doc_uuid}) do
      latest_id when latest_id == commit.parent_id ->
        CubDB.put_multi(state.db, [
          {{:commit, commit.id}, commit},
          {{:latest, commit.doc_uuid}, commit.id}
        ])

        :telemetry.execute(
          [:commonplace, :commit, :create],
          %{system_time: System.system_time()},
          %{doc_uuid: commit.doc_uuid}
        )

        Phoenix.PubSub.broadcast(
          Commonplace.PubSub,
          "commits:#{commit.doc_uuid}",
          {:commit, commit.doc_uuid, commit.id, commit.metadata}
        )

        Phoenix.PubSub.broadcast(
          Commonplace.PubSub,
          "blue:#{commit.doc_uuid}",
          {:commit, commit.doc_uuid, commit.id, commit.metadata}
        )

        {:reply, {:ok, commit}, state}

      _other ->
        {:reply, {:error, :parent_moved}, state}
    end
  end

  # R4(a): hand a caller the live CubDB handle. O(1), no disk I/O — the cheap
  # fallback for resolve_db/1 when persistent_term has no entry for the given
  # server reference (e.g. a pid rather than the registered name).
  @impl true
  def handle_call(:get_db, _from, state) do
    {:reply, state.db, state}
  end

  @impl true
  def handle_call({:all_commit_ids_for_doc, doc_uuid}, _from, state) do
    {:reply, do_all_commit_ids_for_doc(state.db, doc_uuid), state}
  end

  @impl true
  def handle_call({:create_chained_commit, doc_uuid, update, metadata}, from, state) do
    handle_call(
      {:create_chained_commit, doc_uuid, update, metadata, []},
      from,
      state
    )
  end

  @impl true
  def handle_call(
        {:create_chained_commit, doc_uuid, update, metadata, opts},
        _from,
        state
      ) do
    parent_id =
      case CubDB.get(state.db, {:latest, doc_uuid}) do
        nil -> nil
        commit_id -> commit_id
      end

    commit = do_write_commit(state, doc_uuid, update, parent_id, metadata, opts)
    {:reply, commit, state}
  end

  @impl true
  def handle_call({:get_commit, commit_id}, _from, state) do
    {:reply, do_get_commit(state.db, commit_id), state}
  end

  @impl true
  def handle_call({:latest_commit, doc_uuid}, _from, state) do
    {:reply, do_latest_commit(state.db, doc_uuid), state}
  end

  @impl true
  def handle_call({:commit_log, doc_uuid, opts}, _from, state) do
    {:reply, do_commit_log(state.db, doc_uuid, opts), state}
  end

  @impl true
  def handle_call(:all_doc_uuids, _from, state) do
    {:reply, do_all_doc_uuids(state.db), state}
  end

  @impl true
  def handle_call({:is_ancestor, ancestor_id, descendant_id}, _from, state) do
    {:reply, do_is_ancestor(state.db, ancestor_id, descendant_id), state}
  end

  @impl true
  def handle_call({:set_latest, doc_uuid, commit_id}, _from, state) do
    CubDB.put(state.db, {:latest, doc_uuid}, commit_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:commit_ids_for_doc, doc_uuid}, _from, state) do
    {:reply, collect_commit_ids(state.db, doc_uuid), state}
  end

  @impl true
  def handle_call({:ensure_genesis, doc_uuid}, _from, state) do
    genesis = Commit.genesis(doc_uuid)
    CubDB.put(state.db, {:commit, genesis.id}, genesis)
    {:reply, {:ok, genesis}, state}
  end

  @impl true
  def handle_call({:import_commit, commit}, from, state) do
    handle_call({:import_commit, commit, []}, from, state)
  end

  @impl true
  def handle_call({:import_commit, commit, opts}, _from, state) do
    # CX-gwz: verify the claimed content address BEFORE trusting any
    # metadata on the commit — a hostile peer could retag a delta as
    # `%{kind: :snapshot}` and drive reconstruction to skip history.
    case Commonplace.Store.Commit.verify_id(commit) do
      :ok ->
        handle_validated_import(commit, opts, state)

      {:error, {:id_mismatch, computed, claimed}} ->
        :telemetry.execute(
          [:commonplace, :commit, :rejected, :id_mismatch],
          %{system_time: System.system_time()},
          %{
            claimed_id: claimed,
            computed_id: computed,
            doc_uuid: commit.doc_uuid
          }
        )

        {:reply, {:error, {:id_mismatch, computed, claimed}}, state}
    end
  end

  @impl true
  def handle_call({:find_common_ancestor, uuid_a, uuid_b}, _from, state) do
    {:reply, do_find_common_ancestor(state.db, uuid_a, uuid_b), state}
  end

  @impl true
  def handle_call({:set_merge_point, target_uuid, source_uuid, commit_id}, _from, state) do
    CubDB.put(state.db, {:merge_point, target_uuid, source_uuid}, commit_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_merge_point, target_uuid, source_uuid}, _from, state) do
    result = CubDB.get(state.db, {:merge_point, target_uuid, source_uuid})
    {:reply, result, state}
  end

  @impl true
  def handle_call({:set_last_merge_commit, target_uuid, source_uuid, commit_id}, _from, state) do
    CubDB.put(state.db, {:last_merge_commit, target_uuid, source_uuid}, commit_id)
    # Also store a target-only key so we can check "was this target merged from any source?"
    CubDB.put(state.db, {:latest_merge_head, target_uuid}, commit_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_latest_merge_head, target_uuid}, _from, state) do
    result = CubDB.get(state.db, {:latest_merge_head, target_uuid})
    {:reply, result, state}
  end

  @impl true
  def handle_call({:store_attestation, doc_uuid, attestation}, _from, state) do
    CubDB.put_multi(state.db, [
      {{:attestation, attestation.id}, attestation},
      {{:latest_attestation, doc_uuid}, attestation.id}
    ])

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:latest_attestation, doc_uuid}, _from, state) do
    case CubDB.get(state.db, {:latest_attestation, doc_uuid}) do
      nil ->
        {:reply, :none, state}

      att_id ->
        case CubDB.get(state.db, {:attestation, att_id}) do
          nil -> {:reply, :none, state}
          att -> {:reply, {:ok, att}, state}
        end
    end
  end

  @impl true
  def handle_call({:attestation_chain, doc_uuid, limit}, _from, state) do
    case CubDB.get(state.db, {:latest_attestation, doc_uuid}) do
      nil -> {:reply, [], state}
      att_id ->
        chain = collect_attestation_chain(state.db, att_id, limit, [])
        {:reply, chain, state}
    end
  end

  # R11 (CX-tdkq.11): cap on commits held awaiting an out-of-order
  # dependency. Beyond this we fall back to a hard reject (as before) rather
  # than grow memory unbounded — a small queue, not a durable store.
  @max_pending_imports 1024

  defp handle_validated_import(commit, opts, state) do
    case validator_for(opts, state).(commit) do
      :ok ->
        case CubDB.get(state.db, {:commit, commit.id}) do
          nil ->
            state = do_store_imported(commit, state)
            # R11: a freshly-landed commit may be the reference an earlier
            # out-of-order arrival was waiting on — retry the pending queue.
            state = retry_pending_imports(state)
            {:reply, :ok, state}

          _existing ->
            {:reply, :already_exists, state}
        end

      {:error, reason} ->
        emit_namespace_rejection(commit, reason)
        # R11: hold the rejected commit and retry it once a later import lands
        # the reference it's waiting on, instead of dropping a legitimate
        # commit that merely arrived before its dependency (§6.1).
        {:reply, {:error, {:namespace_rejected, reason}}, maybe_queue_pending(commit, opts, reason, state)}
    end
  end

  defp validator_for(opts, state) do
    Keyword.get(opts, :validator) ||
      fn c -> Commonplace.Store.Namespace.validate_commit_from_db(state.db, c) end
  end

  # Persist an imported commit. If the doc has no local :latest, point it
  # here; otherwise leave :latest alone (don't clobber a newer local head).
  defp do_store_imported(commit, state) do
    case CubDB.get(state.db, {:latest, commit.doc_uuid}) do
      nil ->
        CubDB.put_multi(state.db, [
          {{:commit, commit.id}, commit},
          {{:latest, commit.doc_uuid}, commit.id}
        ])

      _existing_latest ->
        CubDB.put(state.db, {:commit, commit.id}, commit)
    end

    state
  end

  defp emit_namespace_rejection(commit, reason) do
    # CX-fbs6: a distinct event for reference-axis rejections so handlers can
    # tell which check caught the commit; the legacy :namespace_mismatch
    # event still fires as a catch-all so existing subscribers keep working.
    case reason do
      {:unknown_reference, outside} ->
        :telemetry.execute(
          [:commonplace, :commit, :rejected, :unknown_reference],
          %{system_time: System.system_time()},
          %{commit_id: commit.id, doc_uuid: commit.doc_uuid, outside: outside}
        )

      _ ->
        :ok
    end

    :telemetry.execute(
      [:commonplace, :commit, :rejected, :namespace_mismatch],
      %{system_time: System.system_time()},
      %{commit_id: commit.id, doc_uuid: commit.doc_uuid, reason: reason}
    )
  end

  defp maybe_queue_pending(commit, opts, reason, state) do
    pending = state.pending_imports

    cond do
      Map.has_key?(pending, commit.id) ->
        state

      map_size(pending) >= @max_pending_imports ->
        # Queue full — leave it hard-rejected (telemetry already fired).
        state

      true ->
        :telemetry.execute(
          [:commonplace, :commit, :deferred, :out_of_order],
          %{system_time: System.system_time()},
          %{commit_id: commit.id, doc_uuid: commit.doc_uuid, reason: reason}
        )

        %{state | pending_imports: Map.put(pending, commit.id, {commit, opts})}
    end
  end

  # Fixpoint retry: re-validate every queued commit against the now-updated
  # store; persist any that pass (each one may unblock others) and drop them
  # from the queue, repeating until a full pass makes no progress. Terminates
  # because each progressing pass removes at least one finite-set entry.
  defp retry_pending_imports(state) do
    {state, progressed} =
      Enum.reduce(state.pending_imports, {state, false}, fn {id, {commit, opts}}, {st, prog} ->
        case validator_for(opts, st).(commit) do
          :ok ->
            st =
              if CubDB.get(st.db, {:commit, commit.id}) == nil,
                do: do_store_imported(commit, st),
                else: st

            {%{st | pending_imports: Map.delete(st.pending_imports, id)}, true}

          {:error, _reason} ->
            {st, prog}
        end
      end)

    if progressed, do: retry_pending_imports(state), else: state
  end

  # ── R4(a): caller-side reads ─────────────────────────────────────────────
  #
  # These `do_*` functions hold the read logic so it can run either inside the
  # GenServer (the `handle_call` clauses above, used by remote/cross-version
  # clients via CommitStoreClient) or directly in the caller process (the
  # public functions, via resolve_db/1). Running in the caller means the
  # disk-bound CubDB btree traversal — which `CubDB.get/select` perform in the
  # calling process, not the CubDB GenServer — no longer queues behind a write
  # in this store's mailbox. Reads stay consistent: each CubDB.get takes its
  # own snapshot, exactly as before. Writes remain serialized here. (CX-tdkq.4)

  defp resolve_db(server) do
    case :persistent_term.get({__MODULE__, :db, server}, nil) do
      nil -> GenServer.call(server, :get_db)
      db -> db
    end
  end

  defp do_get_commit(db, commit_id) do
    case CubDB.get(db, {:commit, commit_id}) do
      nil -> :none
      commit -> {:ok, commit}
    end
  end

  defp do_latest_commit(db, doc_uuid) do
    # CX-o8tx: emit telemetry per latest_commit read so the reflog
    # amortization tests can prove that clean subtrees were short-circuited
    # without a read. Production cost is negligible when no handler is
    # attached.
    :telemetry.execute(
      [:commonplace, :commit, :latest_read],
      %{system_time: System.system_time()},
      %{doc_uuid: doc_uuid}
    )

    case CubDB.get(db, {:latest, doc_uuid}) do
      nil -> :none
      commit_id -> {:ok, CubDB.get(db, {:commit, commit_id})}
    end
  end

  defp do_commit_log(db, doc_uuid, opts) do
    limit = Keyword.get(opts, :limit, 100)

    case CubDB.get(db, {:latest, doc_uuid}) do
      nil -> []
      commit_id -> collect_log(db, commit_id, limit, [])
    end
  end

  defp do_all_doc_uuids(db) do
    CubDB.select(db,
      min_key: {:latest, ""},
      max_key: {:latest, <<255>>}
    )
    |> Enum.map(fn {{:latest, uuid}, _commit_id} -> uuid end)
    |> MapSet.new()
  end

  defp do_all_commit_ids_for_doc(db, doc_uuid) do
    CubDB.select(db,
      min_key: {:commit, ""},
      max_key: {:commit, <<255>>}
    )
    |> Enum.reduce(MapSet.new(), fn
      {{:commit, id}, %{doc_uuid: ^doc_uuid}}, acc -> MapSet.put(acc, id)
      _, acc -> acc
    end)
  end

  defp do_is_ancestor(_db, nil, _descendant_id), do: false
  defp do_is_ancestor(db, ancestor_id, descendant_id), do: walk_ancestors(db, ancestor_id, descendant_id)

  defp do_find_common_ancestor(db, uuid_a, uuid_b) do
    ids_a = collect_commit_ids(db, uuid_a)
    walk_to_ancestor(db, uuid_b, ids_a)
  end

  defp do_write_commit(state, doc_uuid, update, parent_id, metadata, opts) do
    parent_id = maybe_stamp_genesis(state.db, doc_uuid, parent_id)
    metadata = maybe_stamp_snapshot_parent(state.db, parent_id, metadata)

    commit =
      Commit.new(doc_uuid, update, parent_id, metadata)
      |> maybe_sign_commit(Keyword.get(opts, :signing_context))

    CubDB.put_multi(state.db, [
      {{:commit, commit.id}, commit},
      {{:latest, doc_uuid}, commit.id}
    ])

    :telemetry.execute(
      [:commonplace, :commit, :create],
      %{system_time: System.system_time()},
      %{doc_uuid: doc_uuid}
    )

    Phoenix.PubSub.broadcast(
      Commonplace.PubSub,
      "commits:#{doc_uuid}",
      {:commit, doc_uuid, commit.id, metadata}
    )

    # Also broadcast on the blue:UUID topic so UI subscribers (WikiLive,
    # TreeLive) see live updates from CommandRouter-initiated writes (MCP,
    # CLI) — not just edits that already flow through Document.Server.
    # CX-4im. Eventually the blue/commits topic duality should be unified;
    # see the CX-4im notes for the refactor plan.
    Phoenix.PubSub.broadcast(
      Commonplace.PubSub,
      "blue:#{doc_uuid}",
      {:commit, doc_uuid, commit.id, metadata}
    )

    commit
  end

  defp collect_commit_ids(db, doc_uuid) do
    case CubDB.get(db, {:latest, doc_uuid}) do
      nil -> MapSet.new()
      commit_id -> collect_ids(db, commit_id, MapSet.new())
    end
  end

  defp collect_ids(_db, nil, acc), do: acc

  defp collect_ids(db, commit_id, acc) do
    acc = MapSet.put(acc, commit_id)

    case CubDB.get(db, {:commit, commit_id}) do
      nil -> acc
      commit -> collect_ids(db, commit.parent_id, acc)
    end
  end

  defp walk_to_ancestor(db, doc_uuid, ancestor_ids) do
    case CubDB.get(db, {:latest, doc_uuid}) do
      nil -> :none
      commit_id -> find_in_chain(db, commit_id, ancestor_ids)
    end
  end

  defp find_in_chain(_db, nil, _ids), do: :none

  defp find_in_chain(db, commit_id, ancestor_ids) do
    if MapSet.member?(ancestor_ids, commit_id) do
      {:ok, CubDB.get(db, {:commit, commit_id})}
    else
      case CubDB.get(db, {:commit, commit_id}) do
        nil -> :none
        commit -> find_in_chain(db, commit.parent_id, ancestor_ids)
      end
    end
  end

  defp collect_attestation_chain(_db, nil, _limit, acc), do: Enum.reverse(acc)
  defp collect_attestation_chain(_db, _id, 0, acc), do: Enum.reverse(acc)

  defp collect_attestation_chain(db, att_id, limit, acc) do
    case CubDB.get(db, {:attestation, att_id}) do
      nil -> Enum.reverse(acc)
      att -> collect_attestation_chain(db, att.prev_attestation_id, limit - 1, [att | acc])
    end
  end

  defp collect_log(_db, nil, _limit, acc), do: Enum.reverse(acc)
  defp collect_log(_db, _id, 0, acc), do: Enum.reverse(acc)

  defp collect_log(db, commit_id, limit, acc) do
    case CubDB.get(db, {:commit, commit_id}) do
      nil -> Enum.reverse(acc)
      commit -> collect_log(db, commit.parent_id, limit - 1, [commit | acc])
    end
  end

  defp walk_ancestors(_db, _ancestor_id, nil), do: false

  defp walk_ancestors(db, ancestor_id, current_id) do
    case CubDB.get(db, {:commit, current_id}) do
      nil ->
        false

      commit ->
        cond do
          commit.parent_id == ancestor_id -> true
          commit.parent_id == nil -> false
          true -> walk_ancestors(db, ancestor_id, commit.parent_id)
        end
    end
  end

  defp probe_integrity(db) do
    try do
      # Read a small slice — forces CubDB to touch the data file
      CubDB.select(db, min_key: :_, max_key: :_, pipe: [take: 1])
      :ok
    rescue
      e -> {:error, e}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp archive_corrupt_db(path) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    archive_path = "#{path}.corrupt.#{timestamp}"
    File.rename!(path, archive_path)
    File.mkdir_p!(path)
  end

  # CX-m3x: if a caller hands us `parent_id=nil` for a doc_uuid that
  # has never been written before, stamp the deterministic genesis and
  # use its id as the parent. Pre-umbrella docs with an existing :latest
  # retain legacy behavior (parent_id stays nil) — the write-side rule
  # so the read-side legacy hatch (empty metadata, no :kind) keeps
  # working without retroactive genesis insertions.
  defp maybe_stamp_genesis(_db, _doc_uuid, parent_id) when parent_id != nil, do: parent_id

  defp maybe_stamp_genesis(db, doc_uuid, nil) do
    case CubDB.get(db, {:latest, doc_uuid}) do
      nil ->
        genesis = Commit.genesis(doc_uuid)
        CubDB.put(db, {:commit, genesis.id}, genesis)
        genesis.id

      _existing ->
        nil
    end
  end

  # CX-a04: when the caller produces a `:regular` commit without an
  # explicit `:snapshot_parent`, stamp it from the parent's
  # `current_namespace` (snapshot.id / genesis.id / inherited). Callers
  # that set their own snapshot_parent keep it. Non-`:regular` and
  # legacy `%{}` metadata are untouched.
  defp maybe_stamp_snapshot_parent(db, parent_id, %{kind: :regular} = metadata) do
    if Map.has_key?(metadata, :snapshot_parent) do
      metadata
    else
      case stamp_target(db, parent_id) do
        nil -> metadata
        sp_id -> Map.put(metadata, :snapshot_parent, sp_id)
      end
    end
  end

  defp maybe_stamp_snapshot_parent(_db, _parent_id, metadata), do: metadata

  defp stamp_target(_db, nil), do: nil

  defp stamp_target(db, parent_id) do
    case CubDB.get(db, {:commit, parent_id}) do
      nil -> nil
      parent -> Commonplace.Store.Namespace.current_namespace(parent)
    end
  end

  # CX-hoj: prefer the per-call signing context when one is supplied.
  # Pass `signing_context: :unsigned` to deliberately skip signing even
  # when the global SecretStore has a key configured (used by MCP-MVP
  # agent commits that should not inherit the human's identity).
  # Default (nil context) falls back to the global SecretStore — the
  # legacy behavior, preserved for callers that haven't been updated.
  defp maybe_sign_commit(commit, signing_context \\ nil)

  defp maybe_sign_commit(commit, :unsigned), do: commit

  defp maybe_sign_commit(commit, %Commonplace.Crypto.SigningContext{} = ctx) do
    signer_id = Commonplace.Crypto.Signing.signer_id(ctx.identity_uuid, ctx.public_key)
    Commonplace.Crypto.Signing.sign_commit(commit, ctx.private_key, signer_id)
  end

  defp maybe_sign_commit(commit, nil) do
    case Process.whereis(Commonplace.Store.SecretStore) do
      nil ->
        commit

      _pid ->
        with {:ok, encoded_key} <- Commonplace.Store.SecretStore.get("signing_key:default"),
             {:ok, private_key} <- Base.decode64(encoded_key),
             {:ok, encoded_pub} <- Commonplace.Store.SecretStore.get("signing_pub:default"),
             {:ok, public_key} <- Base.decode64(encoded_pub) do
          identity_uuid =
            case Commonplace.Store.SecretStore.get("signing_identity") do
              {:ok, uuid} -> uuid
              :not_found -> "anonymous"
            end

          signer_id = Commonplace.Crypto.Signing.signer_id(identity_uuid, public_key)
          Commonplace.Crypto.Signing.sign_commit(commit, private_key, signer_id)
        else
          _ -> commit
        end
    end
  end
end
