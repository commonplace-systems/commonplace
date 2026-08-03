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
  must never let two concurrent writers both observe the same
  `:latest`, both produce children rooted at the same parent, and
  both write — the second writer's `:latest` bump would win and the
  first writer's commit, though persisted as a row, would be silently
  dropped from every linear walk that started at `:latest`.

  The ORIGINAL fix (pre-CX-3erd) bundled the whole read+build+sign+write
  sequence inside one `handle_call`, so the GenServer mailbox serialized
  concurrent writers per doc — correctness rested on nothing else
  running between the read and the write.

  CX-3erd hoists the CPU-heavy build+sign work OUT of that serialized
  section (see `Commonplace.Store.CommitBuilder` and
  `CommitStoreClient`'s local-mode `create_chained_commit/5`): the
  client now reads `:latest`, builds+signs the commit in its OWN
  process, and lands it via `put_built_commit/4`, a CAS'd verb. The
  trust structure changed, but the invariant didn't:

    * The caller-side read is **never** the source of correctness.
      CubDB supports concurrent readers via MVCC snapshots, so the
      read is safe to run outside the mailbox; it may simply be
      *stale* by the time the write reaches the store.
    * Correctness rests entirely on the CAS check that
      `put_built_commit/4` runs INSIDE the store's serialized
      `handle_call`, comparing `:latest` to the exact value the
      caller observed before it built. A stale read costs a retry
      (`{:error, :parent_moved}` — the client rebuilds against the
      fresh `:latest` and tries again, bounded, then falls back to
      the legacy serialized verb below), never a wrong write. This is
      the exact same structure `write_snapshot_cas/5` already had.
    * CX-l7j's invariant is therefore now **CAS-rejection** instead of
      **mailbox-bundling** — two racing writers can no longer both
      silently land children on the same parent; the loser is told
      so explicitly and retries.

  The two `{:create_commit, ...}` / `{:create_chained_commit, ...}`
  `handle_call` clauses below (via `do_write_commit/6`) are the
  RETAINED legacy serialized path — still real bundling, still
  correct — used by remote-mode callers (who have no local CubDB
  handle to read from) and as `CommitStoreClient`'s fallback once the
  bounded caller-side retry loop is exhausted (pathological, sustained
  contention only).

  Callers that don't need the "chain to current latest" semantics —
  e.g. snapshot construction that compares-and-swaps against an
  observed parent — use `write_snapshot_cas/5` or
  `write_prebuilt_commit_cas/2`, which encode the same atomicity
  with explicit CAS rejection (`{:error, :parent_moved}`) instead of
  silent re-anchoring. `put_built_commit/4` is a third member of this
  CAS family, differing only in what it CASes against (an
  independently-supplied `expected_parent_id` rather than
  `commit.parent_id`) and in optionally landing a genesis row
  alongside.

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
    * `CommitBuilder.resolve_genesis/3` (private, CX-3erd — formerly
      this module's own `maybe_stamp_genesis/3`) — when a caller
      passes `parent_id = nil` for a uuid that has no `:latest`,
      resolve the genesis id and use it as the parent. Pre-umbrella
      docs that already have a `:latest` keep the nil parent (legacy
      hatch — empty metadata, no `:kind`): back-filling a genesis
      ancestor beneath already-written history would change those
      commits' parent chains and ids, so the hatch deliberately leaves
      pre-umbrella docs untouched. Unlike `ensure_genesis/2`, this
      variant does not write the genesis row itself (it can't — it
      may run in the caller's process, see CX-3erd below); the row
      rides along with whichever put lands the commit.
    * `CommitBuilder.stamp_snapshot_parent/3` (private, CX-a04,
      formerly this module's own `maybe_stamp_snapshot_parent/3`) —
      `:regular` commits inherit `snapshot_parent` from the parent's
      `Namespace.current_namespace/1` unless the caller set one
      explicitly. Non-`:regular` and legacy-empty metadata are
      left untouched.

  Both now live in `Commonplace.Store.CommitBuilder` (CX-3erd) so the
  server-serialized path (`do_write_commit/6`) and the caller-side
  hoisted path (`CommitStoreClient`'s local-mode `create_commit` /
  `create_chained_commit`) run the EXACT SAME implementation — there
  is exactly one place genesis/snapshot_parent stamping semantics can
  be defined, so the two paths can never silently diverge.

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

  R4c rung-0 write-path instrumentation (CX-9hql) adds three more,
  documented in full in `Commonplace.Telemetry`'s moduledoc:

      [:commonplace, :commit_store, :call]         (per WRITE-verb handle_call)
      [:commonplace, :commit_store, :write_cpu]     (CPU breakdown: build/sign/validate/persist)
      [:commonplace, :commit_store, :queue_depth]   (periodic mailbox-depth poll)

  `:latest_read` exists so the reflog amortization tests
  (`Reflog.Snapshot`, CX-o8tx) can prove that clean subtrees were
  short-circuited without a read. Production cost is negligible
  when no handler is attached.

  ## Signing (CX-hoj, CX-o3r7)

  Commit signing is opt-in and per-write. `CommitBuilder.build/6` (CX-3erd
  — the single build pipeline shared by `do_write_commit/6` and the
  caller-side hoisted path) calls `CommitBuilder.maybe_sign_commit/2`
  with the `:signing_context` option:

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
  the workspace — `init/1` probes the database with a full key scan
  (CX-xrds: deepened from the original take-1 probe, which only
  touched a single entry and could miss corruption located later in
  the file), and on failure archives the corrupt dir to
  `<path>.corrupt.<unix-ts>` and starts fresh. This is **lossy** by
  design: a corrupt commits/ DB cannot be recovered in-process, and
  the alternative is an unbootable workspace. The
  `<path>.corrupt.<ts>` directory is preserved on disk for
  out-of-band recovery — see `salvage_corrupt_archive/2` below.

  The scan is bounded by **time, not count**: it runs in a supervised
  `Task` capped at `Application.get_env(:commonplace,
  :corruption_probe_timeout_ms, 5_000)` milliseconds. A raise during
  the scan means real corruption → archive-and-recover. A timeout
  means the store is just large — availability wins over paranoia, so
  a timeout is logged as a partial scan and treated as HEALTHY rather
  than triggering a lossy rename of a store that may be perfectly
  fine. This keeps `init/1`'s boot-time cost bounded regardless of
  store size while still catching corruption anywhere in a
  store that scans within the timeout.

  Recovery granularity stays **whole-store**: `init/1` never attempts
  per-key quarantine of a corrupt CubDB (a materially bigger design —
  CubDB offers no supported way to skip past a damaged region mid-scan
  and keep using the same handle). What CX-xrds adds instead is
  `salvage_corrupt_archive/2`, an out-of-band tool that opens an
  archived `.corrupt.<ts>` directory **read-only in a separate
  process**, walks whatever entries are still readable (rescuing
  per-entry so one bad record doesn't abort the walk), and
  re-imports each recovered commit into a live store via the normal
  `import_commit/3` front door — content-addressed, so re-importing
  an already-present commit is a safe no-op and Gate A/B validation
  still applies to every salvaged commit.

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
  require Logger

  alias Commonplace.Store.{Commit, CommitBuilder}
  alias Commonplace.Trust.CodeDocHeuristic

  # Shared ceiling for commit_log walks (CX-klpi). Callers that hit
  # exactly this many results should treat the log as possibly-truncated
  # — the walk stopped because it hit the cap, not because it reached
  # the genesis commit.
  @max_commit_log_limit 10_000

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
  Atomically persist a caller-BUILT commit — the CX-3erd hoisted write
  path's landing verb.

  Unlike `write_prebuilt_commit_cas/2` (whose CAS compares `:latest` to
  `commit.parent_id`), the CAS here compares `:latest` to the
  independently-supplied `expected_parent_id` — the value the caller
  observed `:latest` to be *before* it ran `CommitBuilder.build/6`
  (`nil` means "expect no `:latest` yet"). This is what lets
  `create_commit`'s explicit-parent writes (whose `commit.parent_id`
  may be an arbitrary caller-supplied id, not derived from `:latest` at
  all) share this same landing verb as `create_chained_commit`'s
  observed-latest writes: both pass whatever they read `:latest` as
  right before building, and CAS-fail only if that specific observation
  went stale.

  When `genesis` is non-nil (the caller's build newly resolved a
  genesis parent — see `CommitBuilder.resolve_genesis/3`), it rides the
  SAME `put_multi` as the commit + `:latest` rows, so genesis and the
  first real commit land atomically together. Two concurrent
  first-writers on a fresh doc both compute the same genesis id
  (`Commit.genesis/1` is pure); the loser's CAS fails and it retries
  chained onto the winner instead of double-writing genesis (idempotent
  either way — `put_multi` collapses same-bytes duplicates).

  Returns `{:ok, commit}` on a successful land, `{:error, :parent_moved}`
  on CAS mismatch (nothing written).
  """
  @spec put_built_commit(GenServer.server(), Commit.t(), binary() | nil, Commit.t() | nil) ::
          {:ok, Commit.t()} | {:error, :parent_moved}
  def put_built_commit(server \\ __MODULE__, %Commit{} = commit, expected_parent_id, genesis \\ nil) do
    GenServer.call(server, {:put_built_commit, commit, expected_parent_id, genesis})
  end

  @doc """
  Expose the live CubDB handle for `server` (wraps `resolve_db/1`).

  Public so `Commonplace.Store.CommitStoreClient`'s CX-3erd caller-side
  build path can run `CommitBuilder.build/6`'s point-reads (genesis /
  `:latest` / `snapshot_parent` lookups) in the CALLING process, exactly
  like the R4(a) read helpers (`get_commit/2`, `latest_commit/2`, etc.)
  already do — never a `GenServer.call` into this store's own mailbox.
  Only writes need the serialized section; `db_handle/1` hands out
  nothing but read access to CubDB, which supports concurrent readers
  safely (MVCC snapshots).
  """
  @spec db_handle(GenServer.server()) :: CubDB.t()
  def db_handle(server \\ __MODULE__), do: resolve_db(server)

  @doc """
  Return the `Commonplace.Store.TrustSideStore` name/pid registered as this
  CommitStore instance's companion (R4c carve-out). Defaults to the bare
  module name when the instance was started without an explicit
  `:trust_side_store` opt (e.g. a bare `CommitStore.start_link/1` in a test
  that never touches capability/execute_clean behavior). Resolved via
  `persistent_term`, same pattern as `resolve_db/1`, so it's a cheap
  same-process read for callers (notably `CommitStoreClient`) that need to
  address the correct companion instance in a multi-trio test suite.
  """
  @spec trust_side_store_name(GenServer.server()) :: GenServer.server()
  def trust_side_store_name(server \\ __MODULE__) do
    case :persistent_term.get({__MODULE__, :trust_side_store, server}, nil) do
      nil -> GenServer.call(server, :get_trust_side_store)
      name -> name
    end
  end

  @doc """
  Return the `Commonplace.Store.PendingImports` name/pid registered as this
  CommitStore instance's companion (R4c carve-out). See
  `trust_side_store_name/1` for the resolution pattern.
  """
  @spec pending_imports_name(GenServer.server()) :: GenServer.server()
  def pending_imports_name(server \\ __MODULE__) do
    case :persistent_term.get({__MODULE__, :pending_imports, server}, nil) do
      nil -> GenServer.call(server, :get_pending_imports)
      name -> name
    end
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
  Persist a capability cert (CX-tdkq.22b). Content-addressed by its CID;
  idempotent. The cert is the immutable trust VALUE — not a CRDT doc.

  R4c carve-out: this is now a thin back-compat shim. The actual row lives
  in `Commonplace.Store.TrustSideStore`, and the `handle_call` below
  delegates to it (raises if this instance's TrustSideStore companion isn't
  running — see `trust_side_store_name/1`). Retained here because
  `Commonplace.Store.CommitStoreClient`'s remote mode addresses this
  GenServer's registered name directly over BEAM distribution.
  """
  def store_capability(server \\ __MODULE__, %Commonplace.Trust.Capability{} = cap) do
    GenServer.call(server, {:store_capability, cap})
  end

  @doc """
  Fetch a capability cert by CID. Returns `{:ok, cap}` or `:none`. Pure
  point-read, runs in the caller process (mirrors `get_commit/2`).
  """
  def get_capability(server \\ __MODULE__, cid) do
    case CubDB.get(resolve_db(server), {:capability, cid}) do
      nil -> :none
      cap -> {:ok, cap}
    end
  end

  # --- execute_clean watermark cache (CX-tdkq.27) ---
  #
  # A node-LOCAL, NON-SYNCED derived verdict: "is the chain ending at this
  # snapshot/commit execute-clean under the trust config fingerprinted by `fp`?"
  # It is NOT a commit and NOT part of any commit's content address — federation
  # never reads or writes these keys, so the phase-2.5 deterministic-snapshot
  # property is untouched. Keying on `fp` (a fingerprint of the trusted set) means
  # a trust-config change self-invalidates stale verdicts. Correctness never
  # depends on it: Gate B's continue-default re-walks full append-only history on a
  # miss. See `Commonplace.Trust.authorized_to_execute?`.
  #
  # R4c carve-out: the underlying rows now live in
  # `Commonplace.Store.TrustSideStore`. Reads stay direct db point-reads here
  # (no TrustSideStore process needed — mirrors `get_capability/2`); the
  # mutating verbs (`put_execute_clean/4`, `flush_execute_clean/1`) delegate
  # to TrustSideStore, so an instance exercising these needs its
  # TrustSideStore companion running (e.g. via `Commonplace.Store.Supervisor`).

  @doc """
  Read a cached execute-clean verdict. `{:ok, boolean}` or `:miss`. Pure point-read
  in the caller process (mirrors `get_capability/2`).
  """
  @spec get_execute_clean(GenServer.server(), term(), binary()) :: {:ok, boolean()} | :miss
  def get_execute_clean(server \\ __MODULE__, fp, commit_id) do
    do_get_execute_clean(resolve_db(server), fp, commit_id)
  end

  @doc """
  Cache an execute-clean verdict. Fire-and-forget cast — a lost write just means
  the verdict is recomputed on the next walk, so the compile hot path never blocks
  on cache I/O. Forwarded to `Commonplace.Store.TrustSideStore` (cast-to-cast,
  still fire-and-forget end to end).
  """
  @spec put_execute_clean(GenServer.server(), term(), binary(), boolean()) :: :ok
  def put_execute_clean(server \\ __MODULE__, fp, commit_id, bool) when is_boolean(bool) do
    GenServer.cast(server, {:put_execute_clean, fp, commit_id, bool})
  end

  @doc "Drop every execute-clean cache entry (e.g. on a trust-config change — CX-tdkq.21)."
  @spec flush_execute_clean(GenServer.server()) :: :ok
  def flush_execute_clean(server \\ __MODULE__), do: GenServer.call(server, :flush_execute_clean)

  # --- revocation records (CX-bepn) ---
  #
  # Thin back-compat shims, same shape as store_capability/get_capability:
  # the actual rows live in `Commonplace.Store.TrustSideStore`; retained
  # here because `CommitStoreClient`'s remote mode addresses this
  # GenServer's registered name directly over BEAM distribution.

  @doc "Persist a revocation record (CX-bepn design §1/§8 step 2). See `TrustSideStore.store_revocation/2`."
  def store_revocation(server \\ __MODULE__, %Commonplace.Trust.Revocation{} = rev) do
    GenServer.call(server, {:store_revocation, rev})
  end

  @doc "Fetch every revocation filed against `revoked_cid`. `[]` if none. Pure point-read."
  def get_revocations(server \\ __MODULE__, revoked_cid) do
    case CubDB.get(resolve_db(server), {:revocation, revoked_cid}) do
      nil -> []
      list -> list
    end
  end

  @doc "The per-store revocation-set watermark (design §4). Pure point-read."
  def revocation_set_hash(server \\ __MODULE__) do
    case CubDB.get(resolve_db(server), {:revocation_meta, :set_hash}) do
      nil -> 0
      hash -> hash
    end
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

  @doc """
  The shared ceiling for `commit_log/3` walks (CX-klpi). Callers that
  pass this as `:limit` and get back exactly this many results should
  treat the log as possibly-truncated — the walk may have stopped
  before reaching genesis.
  """
  @spec max_commit_log_limit() :: pos_integer()
  def max_commit_log_limit, do: @max_commit_log_limit

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
  CX-xrds: out-of-band salvage for a `.corrupt.<ts>` archive directory
  left behind by `init/1`'s recovery path (see the moduledoc "CubDB
  crash recovery" section).

  Recovery granularity elsewhere in this module stays whole-store —
  this is deliberately NOT per-key quarantine wired into `init/1`
  itself. It's a separate, explicitly-invoked tool: opens the archived
  CubDB **read-only, in its own process**, so it never touches (or
  risks corrupting further) the archive, then streams every
  `{:commit, id}` entry it can still read and re-imports each one into
  `target_server` (a live `CommitStore` pid/name, default
  `__MODULE__`) via the normal `import_commit/3` front door — so Gate
  A id-verification and Gate B trust/namespace validation apply to
  every salvaged commit exactly as they would to a freshly-written
  one, and re-importing a commit already present in the target store
  is a safe no-op (content-addressed idempotency).

  Each entry is read and imported inside its own `rescue`/`catch`, so
  one damaged record doesn't abort the walk — the corruption that put
  the store here rarely announces itself in advance.

  Returns `{:ok, %{salvaged: n, skipped: n}}` on success (`skipped`
  counts entries that failed to read, failed to decode, or were
  rejected by `import_commit/3`'s validation), or `{:error, reason}`
  if the archive itself couldn't be opened at all.
  """
  def salvage_corrupt_archive(corrupt_dir, target_server \\ __MODULE__) do
    case CubDB.start_link(data_dir: corrupt_dir, auto_file_sync: false, auto_compact: false) do
      {:ok, db} ->
        try do
          {:ok, walk_and_salvage(db, target_server)}
        after
          CubDB.stop(db)
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp walk_and_salvage(db, target_server) do
    keys =
      try do
        db
        |> CubDB.select()
        |> Stream.filter(fn {key, _value} -> match?({:commit, _id}, key) end)
        |> Stream.map(fn {key, _value} -> key end)
        |> Enum.to_list()
      rescue
        _ -> []
      catch
        _, _ -> []
      end

    Enum.reduce(keys, %{salvaged: 0, skipped: 0}, fn key, acc ->
      salvage_one(db, key, target_server, acc)
    end)
  end

  defp salvage_one(db, key, target_server, acc) do
    case CubDB.get(db, key) do
      %Commonplace.Store.Commit{} = commit ->
        case import_commit(target_server, commit) do
          result when result in [:ok, :already_exists] ->
            %{acc | salvaged: acc.salvaged + 1}

          _other ->
            %{acc | skipped: acc.skipped + 1}
        end

      _other ->
        %{acc | skipped: acc.skipped + 1}
    end
  rescue
    _ -> %{acc | skipped: acc.skipped + 1}
  catch
    _, _ -> %{acc | skipped: acc.skipped + 1}
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

    # R4c carve-out: the names of this instance's companion processes
    # (Commonplace.Store.TrustSideStore, Commonplace.Store.PendingImports).
    # Default to `nil` — NOT the bare module names — so a bare
    # `CommitStore.start_link/1` (started standalone, e.g. by a test that
    # only exercises plain commit reads/writes) never silently addresses
    # whatever process happens to be registered under the production
    # default name (notably the real singleton `Commonplace.Application`
    # boots for the whole test run). `nil` is a genuine "no companion"
    # sentinel: pending-import casts become no-ops (see
    # `maybe_notify_landed/2` / `maybe_enqueue_pending/4` below) and the capability/
    # execute_clean shims raise if actually invoked (correctly — those
    # verbs need `Commonplace.Store.Supervisor`'s trio wiring, which always
    # passes explicit names, never relies on this default).
    trust_side_store = Keyword.get(opts, :trust_side_store, nil)
    pending_imports = Keyword.get(opts, :pending_imports, nil)

    case open_cubdb(path) do
      {:ok, db} ->
        case probe_integrity(db) do
          :ok ->
            ready(name, db, trust_side_store, pending_imports)

          {:error, reason} ->
            require Logger
            Logger.warning("CubDB corrupt on probe (#{inspect(reason)}). Archiving and starting fresh.")
            CubDB.stop(db)
            recover_cubdb(name, path, trust_side_store, pending_imports)
        end

      {:error, reason} ->
        require Logger
        Logger.warning("CubDB failed to open (#{inspect(reason)}). Archiving and starting fresh.")
        recover_cubdb(name, path, trust_side_store, pending_imports)
    end
  end

  # R4(a): publish the CubDB handle so reads can run in the caller process
  # against it directly, never queuing behind a write in this GenServer's
  # mailbox (CX-tdkq.4). Keyed by the registered name so isolated test stores
  # and the production singleton don't collide; resolve_db/1 falls back to a
  # cheap `:get_db` call for callers that hold a pid rather than the name.
  #
  # R4c carve-out: the R11 pending-imports queue and the capability/
  # execute_clean rows no longer live in this GenServer's state — they were
  # extracted to `Commonplace.Store.TrustSideStore` (capability certs +
  # execute_clean watermarks) and `Commonplace.Store.PendingImports` (the R11
  # retry queue). This state only remembers WHICH instances of those
  # companion processes belong to this CommitStore, so the back-compat shims
  # below know where to delegate.
  defp ready(name, db, trust_side_store, pending_imports) do
    :persistent_term.put({__MODULE__, :db, name}, db)
    :persistent_term.put({__MODULE__, :trust_side_store, name}, trust_side_store)
    :persistent_term.put({__MODULE__, :pending_imports, name}, pending_imports)
    queue_poller = maybe_start_queue_poller(name)

    {:ok,
     %{
       db: db,
       name: name,
       queue_poller: queue_poller,
       trust_side_store: trust_side_store,
       pending_imports: pending_imports
     }}
  end

  # CX-9hql (R4c rung-0): start the companion mailbox-depth poller unless
  # disabled via `config :commonplace, commit_store_queue_poll_ms: nil | false`
  # (disabled by default in the test env — see config/test.exs). Started
  # unlinked so a poller crash never takes the store down; it only monitors
  # us, not vice versa.
  defp maybe_start_queue_poller(name) do
    case Application.get_env(:commonplace, :commit_store_queue_poll_ms, 5_000) do
      ms when is_integer(ms) and ms > 0 ->
        case Commonplace.Store.CommitStoreQueuePoller.start(
               target_pid: self(),
               store_name: name,
               interval_ms: ms
             ) do
          {:ok, pid} -> pid
          _ -> nil
        end

      _disabled ->
        nil
    end
  end

  @impl true
  def terminate(_reason, %{name: name} = state) do
    :persistent_term.erase({__MODULE__, :db, name})
    :persistent_term.erase({__MODULE__, :trust_side_store, name})
    :persistent_term.erase({__MODULE__, :pending_imports, name})

    case Map.get(state, :queue_poller) do
      pid when is_pid(pid) ->
        try do
          GenServer.stop(pid, :normal, 100)
        catch
          :exit, _ -> :ok
        end

      _ ->
        :ok
    end

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

  defp recover_cubdb(name, path, trust_side_store, pending_imports) do
    archive_corrupt_db(path)

    {:ok, db} =
      CubDB.start_link(
        data_dir: path,
        auto_file_sync: true,
        auto_compact: true
      )

    ready(name, db, trust_side_store, pending_imports)
  end

  @impl true
  def handle_call({:create_commit, doc_uuid, update, parent_id, metadata}, _from, state) do
    instrumented(:create_commit, doc_uuid, fn ->
      commit = do_write_commit(:create_commit, state, doc_uuid, update, parent_id, metadata, [])
      {:reply, commit, state}
    end)
  end

  @impl true
  def handle_call(
        {:create_commit, doc_uuid, update, parent_id, metadata, opts},
        _from,
        state
      ) do
    instrumented(:create_commit, doc_uuid, fn ->
      commit = do_write_commit(:create_commit, state, doc_uuid, update, parent_id, metadata, opts)
      {:reply, commit, state}
    end)
  end

  @impl true
  def handle_call(
        {:write_snapshot_cas, doc_uuid, update, metadata, expected_parent_id},
        _from,
        state
      ) do
    instrumented(:write_snapshot_cas, doc_uuid, fn ->
      case CubDB.get(state.db, {:latest, doc_uuid}) do
        ^expected_parent_id ->
          metadata = Map.put(metadata, :kind, :snapshot)

          commit = Commit.new(doc_uuid, update, expected_parent_id, metadata)
          warn_if_non_system_cas(commit, :snapshot_cas)
          commit = maybe_sign_commit(commit)

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
    end)
  end

  @impl true
  def handle_call({:write_prebuilt_commit_cas, %Commit{} = commit}, _from, state) do
    instrumented(:write_prebuilt_commit_cas, commit.doc_uuid, fn ->
      # Phase 2.5 (CX-tdkq.24): a prebuilt commit is a system-minted merge
      # (Merger/CrossEpochMerge → Commit.new, never signed). Node-sign it
      # so strict mode accepts it. Signing is over the id, which is already
      # bound — so the CAS dedup (keyed on id) is unaffected.
      #
      # CX-hoj: only system kinds (:snapshot / :merge) are meant to reach
      # this bare (no signing_context) call — a future user-payload path
      # through prebuilt-CAS must not silently inherit ambient/node
      # identity, so warn + telemetry loudly if one ever does.
      warn_if_non_system_cas(commit, :prebuilt_cas)
      commit = maybe_sign_commit(commit)

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
    end)
  end

  @impl true
  def handle_call({:put_built_commit, %Commit{} = commit, expected_parent_id, genesis}, _from, state) do
    instrumented(:put_built_commit, commit.doc_uuid, fn ->
      {cas_result, persist_ns} =
        timed(fn ->
          case CubDB.get(state.db, {:latest, commit.doc_uuid}) do
            ^expected_parent_id ->
              # CX-qat5.3: the local-write gate runs HERE — after the CAS
              # match (so a stale-parent retry never even reaches the trust
              # check) and BEFORE put_multi (so a rejection persists
              # nothing, including the piggy-backed genesis row — see
              # local_write_gate_check/2).
              case local_write_gate_check(commit, state) do
                :ok ->
                  rows =
                    case genesis do
                      %Commit{} = g -> [{{:commit, g.id}, g}]
                      nil -> []
                    end ++
                      [
                        {{:commit, commit.id}, commit},
                        {{:latest, commit.doc_uuid}, commit.id}
                      ]

                  CubDB.put_multi(state.db, rows)
                  :ok

                {:error, _reason} = error ->
                  error
              end

            _other ->
              :parent_moved
          end
        end)

      case cas_result do
        :ok ->
          emit_write_cpu(:put_built_commit, commit.doc_uuid, 0, 0, 0, persist_ns)

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

        :parent_moved ->
          {:reply, {:error, :parent_moved}, state}

        {:error, _reason} = error ->
          {:reply, error, state}
      end
    end)
  end

  # R4(a): hand a caller the live CubDB handle. O(1), no disk I/O — the cheap
  # fallback for resolve_db/1 when persistent_term has no entry for the given
  # server reference (e.g. a pid rather than the registered name).
  @impl true
  def handle_call(:get_db, _from, state) do
    {:reply, state.db, state}
  end

  @impl true
  def handle_call(:get_trust_side_store, _from, state) do
    {:reply, state.trust_side_store, state}
  end

  @impl true
  def handle_call(:get_pending_imports, _from, state) do
    {:reply, state.pending_imports, state}
  end

  # execute_clean cache (CX-tdkq.27). Read also exposed as a remote-routable call
  # for clustered stores; writes are casts; flush is a call.
  @impl true
  def handle_call({:get_execute_clean, fp, commit_id}, _from, state) do
    {:reply, do_get_execute_clean(state.db, fp, commit_id), state}
  end

  @impl true
  def handle_call(:flush_execute_clean, _from, state) do
    # R4c carve-out: delegate to this instance's TrustSideStore companion —
    # it owns the execute_clean rows now. Synchronous on purpose (callers
    # need the guarantee stale verdicts are wiped before this returns).
    reply = Commonplace.Store.TrustSideStore.flush_execute_clean(state.trust_side_store)
    {:reply, reply, state}
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
    instrumented(:create_chained_commit, doc_uuid, fn ->
      parent_id =
        case CubDB.get(state.db, {:latest, doc_uuid}) do
          nil -> nil
          commit_id -> commit_id
        end

      commit = do_write_commit(:create_chained_commit, state, doc_uuid, update, parent_id, metadata, opts)
      {:reply, commit, state}
    end)
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
    instrumented(:import_commit, commit.doc_uuid, fn ->
      # CX-gwz: verify the claimed content address BEFORE trusting any
      # metadata on the commit — a hostile peer could retag a delta as
      # `%{kind: :snapshot}` and drive reconstruction to skip history.
      # Timed as part of the "validate" write_cpu phase (CX-9hql) —
      # federation/catch-up import bursts are the credible source of
      # rung-2 mailbox pressure, so import_commit's CPU share matters.
      {verify_result, verify_ns} = timed(fn -> Commonplace.Store.Commit.verify_id(commit) end)

      case verify_result do
        :ok ->
          handle_validated_import(commit, opts, state, verify_ns)

        {:error, {:id_mismatch, computed, claimed}} ->
          emit_write_cpu(:import_commit, commit.doc_uuid, 0, 0, verify_ns, 0)

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
    end)
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
  def handle_call({:store_capability, %Commonplace.Trust.Capability{} = cap}, _from, state) do
    instrumented(:store_capability, nil, fn ->
      # R4c carve-out: delegate to this instance's TrustSideStore companion,
      # which owns the {:capability, cid} row and notifies PendingImports
      # (CX-tdkq.22e) once the cert is durably stored.
      reply = Commonplace.Store.TrustSideStore.store_capability(state.trust_side_store, cap)
      {:reply, reply, state}
    end)
  end

  @impl true
  def handle_call({:get_capability, cid}, _from, state) do
    reply =
      case CubDB.get(state.db, {:capability, cid}) do
        nil -> :none
        cap -> {:ok, cap}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:store_revocation, %Commonplace.Trust.Revocation{} = rev}, _from, state) do
    # R4c carve-out shape: delegate to this instance's TrustSideStore
    # companion, which owns the {:revocation, cid} row + the :set_hash
    # watermark (atomic multi-put — see TrustSideStore's moduledoc).
    reply = Commonplace.Store.TrustSideStore.store_revocation(state.trust_side_store, rev)
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:get_revocations, revoked_cid}, _from, state) do
    reply =
      case CubDB.get(state.db, {:revocation, revoked_cid}) do
        nil -> []
        list -> list
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:revocation_set_hash, _from, state) do
    reply =
      case CubDB.get(state.db, {:revocation_meta, :set_hash}) do
        nil -> 0
        hash -> hash
      end

    {:reply, reply, state}
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

  # execute_clean watermark cache write (CX-tdkq.27) — fire-and-forget.
  # R4c carve-out: forwarded to TrustSideStore's own cast (cast-to-cast, so
  # this stays fire-and-forget end to end). A no-op if this instance's
  # TrustSideStore companion isn't running — same "lost write, recomputed on
  # next walk" tolerance the doc above already promises.
  @impl true
  def handle_cast({:put_execute_clean, fp, commit_id, bool}, state) do
    Commonplace.Store.TrustSideStore.put_execute_clean(state.trust_side_store, fp, commit_id, bool)
    {:noreply, state}
  end

  defp handle_validated_import(commit, opts, state, verify_ns) do
    {validation_result, validation_ns} = timed(fn -> import_validation(commit, opts, state) end)
    validate_ns = verify_ns + validation_ns

    case validation_result do
      :ok ->
        case CubDB.get(state.db, {:commit, commit.id}) do
          nil ->
            {state, persist_ns} = timed(fn -> do_store_imported(commit, state) end)
            emit_write_cpu(:import_commit, commit.doc_uuid, 0, 0, validate_ns, persist_ns)
            # R11 / R4c carve-out: a freshly-landed commit may be the
            # reference (or the cert) an earlier out-of-order arrival was
            # waiting on. Notify this instance's PendingImports companion
            # (a no-op when this instance has none configured — see
            # `maybe_notify_landed/2`); it re-submits its whole held queue
            # through THIS SAME import_commit/3 front door.
            maybe_notify_landed(state, commit.id)
            {:reply, :ok, state}

          _existing ->
            emit_write_cpu(:import_commit, commit.doc_uuid, 0, 0, validate_ns, 0)
            {:reply, :already_exists, state}
        end

      # CX-tdkq.22e: a commit awaiting its authorizing cert DEFERS (the cert
      # may land later), exactly like a namespace out-of-order reference.
      {:error, {:trust, :awaiting_capability}} ->
        emit_write_cpu(:import_commit, commit.doc_uuid, 0, 0, validate_ns, 0)
        maybe_enqueue_pending(state, commit, opts, :awaiting_capability)

        {:reply, {:error, {:trust_rejected, :awaiting_capability}}, state}

      # R1: other trust rejections are HARD — they never resolve by waiting.
      {:error, {:trust, reason}} ->
        emit_write_cpu(:import_commit, commit.doc_uuid, 0, 0, validate_ns, 0)

        :telemetry.execute(
          [:commonplace, :commit, :rejected, :trust],
          %{system_time: System.system_time()},
          %{commit_id: commit.id, doc_uuid: commit.doc_uuid, signer_id: commit.signer_id, reason: reason}
        )

        {:reply, {:error, {:trust_rejected, reason}}, state}

      # CX-obfb: a delta-merge (merge_parents non-empty, or a
      # MergeSnapshotter-shaped 2+ element snapshot_parents) targeting a
      # code doc is a HARD reject — it never resolves by waiting, same
      # rationale as R1 trust rejections. The classifier is best-effort
      # content-sniffing (Commonplace.Trust.CodeDocHeuristic), so this is
      # defense-in-depth alongside the sibling-merge and explicit-merge
      # seams, not a substitute for Gate B.
      {:error, {:code_doc_delta_merge, _doc_uuid} = reason} ->
        emit_write_cpu(:import_commit, commit.doc_uuid, 0, 0, validate_ns, 0)

        :telemetry.execute(
          [:commonplace, :commit, :rejected, :code_doc_delta_merge],
          %{system_time: System.system_time()},
          %{doc_uuid: commit.doc_uuid, commit_id: commit.id}
        )

        {:reply, {:error, reason}, state}

      {:error, {:namespace, reason}} ->
        emit_write_cpu(:import_commit, commit.doc_uuid, 0, 0, validate_ns, 0)
        emit_namespace_rejection(commit, reason)
        # R11: hold the rejected commit and retry once its dependency lands.
        maybe_enqueue_pending(state, commit, opts, reason)
        {:reply, {:error, {:namespace_rejected, reason}}, state}
    end
  end

  # R4c carve-out: `state.pending_imports` is `nil` unless this instance was
  # started with an explicit companion (see `init/1`) — notably, always
  # non-nil when started via `Commonplace.Store.Supervisor`, always `nil`
  # for a standalone `CommitStore.start_link/1`. `nil` means "this instance
  # has no PendingImports companion," so these are no-ops rather than
  # addressing whatever process happens to be registered under the bare
  # `Commonplace.Store.PendingImports` module name (which, in a running
  # `Commonplace.Application` — including during the test suite — is a
  # REAL, unrelated singleton; silently talking to it would leak held
  # commits across otherwise-isolated test instances).
  defp maybe_notify_landed(%{pending_imports: nil}, _commit_id), do: :ok

  defp maybe_notify_landed(%{pending_imports: pending_imports}, commit_id),
    do: Commonplace.Store.PendingImports.notify_landed(pending_imports, commit_id)

  defp maybe_enqueue_pending(%{pending_imports: nil}, _commit, _opts, _reason), do: :ok

  defp maybe_enqueue_pending(%{pending_imports: pending_imports}, commit, opts, reason),
    do: Commonplace.Store.PendingImports.enqueue(pending_imports, commit, opts, reason)

  # The full import validation pipeline — trust gate, THEN the
  # no-delta-merge-on-code-docs guard, THEN namespace — run identically
  # by the initial import and the R11 retry, so a commit deferred for one
  # reason (e.g. an absent cert) is re-checked against ALL gates when it
  # is retried (never bypasses an earlier check).
  defp import_validation(commit, opts, state) do
    with :ok <- trust_check(commit, state),
         :ok <- code_doc_delta_merge_check(commit, state),
         :ok <- namespace_check(commit, opts, state) do
      :ok
    end
  end

  # CX-obfb: forbid delta-merges from landing on code docs. Gate B
  # (`Commonplace.Trust.authorized_to_execute?`) walks a doc's commit
  # chain via `parent_id` only, so a merge commit's `merge_parents`
  # side-line — or a MergeSnapshotter two-parent snapshot — is never
  # visited by the execute-authorization walk, even though its absorbed
  # bytes reach a compile read. Rather than teach the walk to traverse
  # merge edges, code-doc convergence is required to happen by
  # re-authorship instead: an `:execute`-authorized signer mints a
  # regular full-state commit.
  #
  # `state.name` (not the routing default) is threaded through so the
  # classifier's reconstruct read resolves THIS store's CubDB handle —
  # safe to call from inside this GenServer's own handle_call because
  # `reconstruct_snapshot` bottoms out in `resolve_db/1`, which reads a
  # `:persistent_term` handle directly rather than `GenServer.call`ing
  # back into this same (currently busy) process.
  defp code_doc_delta_merge_check(commit, state) do
    if delta_merge_shaped?(commit) and CodeDocHeuristic.code_doc?(commit.doc_uuid, state.name) do
      {:error, {:code_doc_delta_merge, commit.doc_uuid}}
    else
      :ok
    end
  end

  # A delta-merge commit is either:
  #   - a `:translate`-style merge: non-empty `merge_parents`, or
  #   - a MergeSnapshotter-style merge-snapshot: `metadata.snapshot_parents`
  #     carrying 2+ entries (the two-parent shape; a normal single-lineage
  #     snapshot carries exactly one).
  defp delta_merge_shaped?(%Commit{merge_parents: merge_parents}) when merge_parents != [], do: true

  defp delta_merge_shaped?(%Commit{metadata: %{snapshot_parents: snapshot_parents}})
       when is_list(snapshot_parents) and length(snapshot_parents) > 1,
       do: true

  defp delta_merge_shaped?(_commit), do: false

  defp trust_check(commit, state) do
    # Thread this store's own name so the phase-3 capability path fetches
    # certs from THIS db (not the routing default).
    case Commonplace.Trust.authorized?(
           commit,
           :write,
           {:doc, commit.doc_uuid},
           Commonplace.Trust.config(),
           state.name
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:trust, reason}}
    end
  end

  # ── CX-qat5.3: the local-write gate ──────────────────────────────────
  #
  # The third `Trust.authorized?` call-site family (Gate A gates
  # federation import, Gate B gates code execution — this gates every
  # LOCALLY-created commit at the CommitStore create seam, mirroring
  # import_validation's `trust_check/2` above: same verifier, same
  # `{:doc, doc_uuid}` scope, same store-name threading for the
  # deadlock-safety reasoning (phase-3 capability fetches must read via
  # `state.name`, never `GenServer.call` back into this store's own
  # mailbox).
  #
  # Three-position knob (`Application.get_env(:commonplace,
  # :local_write_gate, :dry_run)`):
  #
  #   * `:off`     — skip the check entirely (emergency escape hatch).
  #   * `:dry_run` — run the check; a would-deny is logged + given
  #     telemetry but the write still lands. DEFAULT — under the
  #     workspace's default permissive trust config `authorized?`
  #     returns `:ok` for everything, so this is a no-op observation
  #     window until a workspace flips `accept_unsigned: false` /
  #     pins identities.
  #   * `:enforce` — a would-deny is REJECTED: nothing is persisted,
  #     a red event fires on the doc's topic, and
  #     `{:error, {:trust_rejected, reason}}` is returned to the
  #     caller instead of the commit.
  #
  # Genesis commits (synthetic, unsigned, `kind: :genesis`) are exempt —
  # mirroring the exemption Gate B's `authorized_to_execute?` walk
  # already gives genesis. In practice the primary commit gated here is
  # never genesis-shaped (genesis rides ALONGSIDE a real commit as the
  # `built.genesis` / CAS `genesis` companion, never as the gated
  # struct itself) — this clause is a defensive backstop, and it is
  # exactly what makes "genesis rides only when the gated commit
  # passes" true: the companion genesis row is written in the SAME
  # `put_multi` as the gated commit, so it never lands independently of
  # whether the gate accepted the write it rode in with.
  defp local_write_gate_check(%Commit{metadata: %{kind: :genesis}}, _state), do: :ok

  defp local_write_gate_check(commit, state) do
    case Application.get_env(:commonplace, :local_write_gate, :dry_run) do
      :off ->
        :ok

      mode when mode in [:dry_run, :enforce] ->
        # CX-fogy: use `authorized_to_write?` (not a fixed `:write`) so a
        # CODE-content write FORKS the required capability by re-running the
        # safe-verb allowlist on the after-state — a valid sandboxed safe-verb
        # needs `:define_verb` (the citizen's home grant), raw/unsafe code needs
        # `:execute` (Gate-B, node-only), data needs `:write`. Fail-closed to
        # `:execute`. See `Trust.authorized_to_write?` for the interim layering
        # note + the (c)-refined destination.
        case Commonplace.Trust.authorized_to_write?(
               commit,
               {:doc, commit.doc_uuid},
               Commonplace.Trust.config(),
               state.name
             ) do
          :ok -> :ok
          {:error, reason} -> handle_local_write_denial(mode, commit, reason)
        end
    end
  end

  defp handle_local_write_denial(:dry_run, commit, reason) do
    Logger.warning(
      "CommitStore: local write would be DENIED by trust gate (dry_run — write still lands) " <>
        "doc_uuid=#{commit.doc_uuid} commit_id=#{Base.encode16(commit.id, case: :lower)} " <>
        "reason=#{inspect(reason)}"
    )

    :telemetry.execute(
      [:commonplace, :commit, :rejected, :local_trust],
      %{system_time: System.system_time()},
      %{mode: :dry_run, doc_uuid: commit.doc_uuid, commit_id: commit.id, reason: reason}
    )

    :ok
  end

  defp handle_local_write_denial(:enforce, commit, reason) do
    Logger.warning(
      "CommitStore: local write DENIED by trust gate (enforce) " <>
        "doc_uuid=#{commit.doc_uuid} commit_id=#{Base.encode16(commit.id, case: :lower)} " <>
        "reason=#{inspect(reason)}"
    )

    :telemetry.execute(
      [:commonplace, :commit, :rejected, :local_trust],
      %{system_time: System.system_time()},
      %{mode: :enforce, doc_uuid: commit.doc_uuid, commit_id: commit.id, reason: reason}
    )

    Commonplace.Dataflow.PubSub.broadcast_red(
      commit.doc_uuid,
      {:trust, :local_write_denied,
       %{doc_uuid: commit.doc_uuid, signer_id: commit.signer_id, reason: reason}}
    )

    {:error, {:trust_rejected, reason}}
  end

  defp namespace_check(commit, opts, state) do
    case validator_for(opts, state).(commit) do
      :ok -> :ok
      {:error, reason} -> {:error, {:namespace, reason}}
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

  # ── CX-9hql (R4c rung-0): write-path telemetry helpers ──────────────────
  #
  # `instrumented/3` wraps a single WRITE-verb handle_call body so the
  # timing/mailbox-depth code isn't duplicated at every call site. It must
  # add negligible overhead on the hot path: no extra GenServer calls, no
  # cross-process work — `Process.info(self(), ...)` and
  # `System.monotonic_time/0` are both cheap same-process reads.

  defp instrumented(verb, doc_uuid, fun) do
    queue_len =
      case Process.info(self(), :message_queue_len) do
        {:message_queue_len, n} -> n
        nil -> 0
      end

    {result, duration} = timed(fun)

    :telemetry.execute(
      [:commonplace, :commit_store, :call],
      %{duration: duration, queue_len: queue_len},
      %{verb: verb, doc_uuid: doc_uuid}
    )

    result
  end

  # Time a zero-arg function, returning `{result, elapsed_native_time}`.
  defp timed(fun) do
    start = System.monotonic_time()
    result = fun.()
    {result, System.monotonic_time() - start}
  end

  # Every emission from this module runs inside the GenServer's
  # serialized section, hence `site: :server` (the rung-1 signal). The
  # hoisted caller-side build/sign timings are emitted by
  # `CommitStoreClient` with `site: :caller` (CX-3erd follow-up).
  defp emit_write_cpu(verb, doc_uuid, build_ns, sign_ns, validate_ns, persist_ns) do
    :telemetry.execute(
      [:commonplace, :commit_store, :write_cpu],
      %{build: build_ns, sign: sign_ns, validate: validate_ns, persist: persist_ns},
      %{verb: verb, doc_uuid: doc_uuid, site: :server}
    )
  end

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

  defp do_get_execute_clean(db, fp, commit_id) do
    case CubDB.get(db, {:execute_clean, fp, commit_id}) do
      nil -> :miss
      bool when is_boolean(bool) -> {:ok, bool}
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

  # CX-3erd: the build/sign pipeline itself now lives in
  # `CommitBuilder.build/6` — the SAME implementation the caller-side
  # hoisted path (`CommitStoreClient`) uses. This retained
  # server-serialized path just calls it and persists inline (already
  # running inside this GenServer's handle_call, so no extra CAS is
  # needed — the mailbox itself is the serialization).
  defp do_write_commit(verb, state, doc_uuid, update, parent_id, metadata, opts) do
    built = CommitBuilder.build(state.db, doc_uuid, update, parent_id, metadata, opts)

    # CX-qat5.3: local-write gate — post-build/sign (the commit id and
    # signature are final), pre-persist. Mirrors import_validation's
    # trust_check (see that function below); see local_write_gate_check/2
    # for the knob semantics and genesis exemption.
    case local_write_gate_check(built.commit, state) do
      :ok ->
        {_, persist_ns} =
          timed(fn ->
            rows =
              case built.genesis do
                %Commit{} = g -> [{{:commit, g.id}, g}]
                nil -> []
              end ++
                [
                  {{:commit, built.commit.id}, built.commit},
                  {{:latest, doc_uuid}, built.commit.id}
                ]

            CubDB.put_multi(state.db, rows)
          end)

        emit_write_cpu(verb, doc_uuid, built.build_ns, built.sign_ns, 0, persist_ns)

        :telemetry.execute(
          [:commonplace, :commit, :create],
          %{system_time: System.system_time()},
          %{doc_uuid: doc_uuid}
        )

        Phoenix.PubSub.broadcast(
          Commonplace.PubSub,
          "commits:#{doc_uuid}",
          {:commit, doc_uuid, built.commit.id, built.commit.metadata}
        )

        # Also broadcast on the blue:UUID topic so UI subscribers (WikiLive,
        # TreeLive) see live updates from CommandRouter-initiated writes (MCP,
        # CLI) — not just edits that already flow through Document.Server.
        # CX-4im. Eventually the blue/commits topic duality should be unified;
        # see the CX-4im notes for the refactor plan.
        Phoenix.PubSub.broadcast(
          Commonplace.PubSub,
          "blue:#{doc_uuid}",
          {:commit, doc_uuid, built.commit.id, built.commit.metadata}
        )

        built.commit

      {:error, _reason} = error ->
        emit_write_cpu(verb, doc_uuid, built.build_ns, built.sign_ns, 0, 0)
        error
    end
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

  # CX-xrds: deepened from the original take-1 probe. Streams every
  # entry (touching each key cheaply — no deserialization beyond what
  # `CubDB.select` already forces) so corruption located anywhere in the
  # file is caught, not just at the head. Bounded by TIME, not count,
  # via `Application.get_env(:commonplace, :corruption_probe_timeout_ms,
  # 5_000)`: a raise during the scan is real corruption, but a timeout
  # just means the store is large — we favor availability and treat a
  # timed-out (partial) scan as healthy rather than lossily archiving a
  # store that may be fine. See the moduledoc "CubDB crash recovery"
  # section for the full rationale.
  defp probe_integrity(db) do
    timeout_ms = Application.get_env(:commonplace, :corruption_probe_timeout_ms, 5_000)

    task =
      Task.async(fn ->
        try do
          db
          |> CubDB.select()
          |> Enum.each(fn {_key, _value} -> :ok end)

          :ok
        rescue
          e -> {:error, e}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, _reason} = error} ->
        error

      nil ->
        require Logger

        Logger.warning(
          "CubDB integrity probe exceeded #{timeout_ms}ms (partial scan) — " <>
            "treating store as healthy; availability wins over paranoia for a " <>
            "large-but-fine store"
        )

        :ok
    end
  end

  defp archive_corrupt_db(path) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    archive_path = "#{path}.corrupt.#{timestamp}"
    File.rename!(path, archive_path)
    File.mkdir_p!(path)
  end

  # CX-hoj: the CAS write paths (`write_snapshot_cas/5`,
  # `write_prebuilt_commit_cas/2`) call `maybe_sign_commit/1` with no
  # context deliberately — today only node-signed system kinds
  # (`:snapshot`/`:merge`) route through them. If a commit of any other
  # kind reaches one of these bare calls, it would silently inherit
  # ambient identity (global key or node key) with no per-call
  # signing_context to say otherwise. Surface that loudly instead.
  defp warn_if_non_system_cas(%Commit{metadata: metadata, doc_uuid: doc_uuid, id: id}, via)
       when via in [:snapshot_cas, :prebuilt_cas] do
    kind = Map.get(metadata, :kind)

    unless kind in [:snapshot, :merge] do
      Logger.warning(
        "CommitStore: non-system-kind commit (kind=#{inspect(kind)}) reached #{via} " <>
          "unsigned-context CAS path — this path is meant only for node-signed " <>
          "system commits (doc_uuid=#{doc_uuid})"
      )

      :telemetry.execute(
        [:commonplace, :commit, :ambient_signed],
        %{system_time: System.system_time()},
        %{doc_uuid: doc_uuid, commit_id: id, via: :cas}
      )
    end

    :ok
  end

  # CX-3erd: signing itself now lives in `CommitBuilder.maybe_sign_commit/2`
  # — the SAME implementation `do_write_commit/6` (via `CommitBuilder.build/6`)
  # and the caller-side hoisted path both use. The CAS write paths keep
  # calling it directly (bare, no signing_context) since they sit above
  # this build pipeline (see the module-level "Signing" section).
  defp maybe_sign_commit(commit), do: CommitBuilder.maybe_sign_commit(commit)
end
