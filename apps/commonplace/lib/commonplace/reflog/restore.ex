defmodule Commonplace.Reflog.Restore do
  @moduledoc """
  The RESTORE half of the reflog (CX-0t2r): reading a past checkpoint
  back into a usable subtree.

  `Commonplace.Reflog.Snapshot` writes the checkpoints — this module
  reads them. Three public functions, deliberately kept separate (this
  is the load-bearing seam, do not blur it):

    * `list_checkpoints/3` — enumerate available checkpoints for an
      owner. Read-only.
    * `resolve/3` — turn one checkpoint commit into a flat
      `%{path => {:file, doc_uuid, commit_id_hex}}` map. **Pure,
      read-only, zero writes. Unchanged by stage 3 — kept exactly as
      it was, including its "never chain-replay a pin doc" reader
      discipline.**
    * `materialize_branch/5` (CX-0t2r stage 3) — the FORK-ANCHORED
      branch materializer. Unlike `materialize_dir/4`, which is a
      pure consumer of `resolve/3`'s flat file map, this one needs
      **directory-level** anchoring too (see "Why `resolve/3`'s
      output isn't enough" below), so it walks the checkpoint itself
      via the same two identifiers `resolve/3` takes
      (`snapshot_doc_uuid`, `checkpoint_commit_id`) rather than
      consuming a pre-flattened map. `resolve/3` itself is untouched
      by this — it remains a separately-callable, pure, read-only
      function with the exact same signature and output shape it had
      before stage 3; `materialize_dir/4` and `diff/3` keep consuming
      it exactly as before.

  ## Why `resolve/3`'s output isn't enough for fork-anchored branches

  `resolve/3` deliberately flattens to `%{path => {:file, doc_uuid,
  commit_id}}` — file (leaf) entries only. A branch materializer that
  wants real ancestry (CX-0t2r stage 3's whole point) needs more than
  that for **directories**: `Commonplace.Tree.Merge.merge/4`'s very
  first move is `CommitStore.find_common_ancestor(source_root_uuid,
  target_root_uuid)` — a check on the two **directory schema docs'
  own uuids**, before it ever looks at a single file. If the restored
  root (and every restored subdirectory) doesn't carry a `parent_id`
  reachable from the corresponding *live* directory's own commit
  chain, `find_common_ancestor` returns `:none` at the very first
  hop and the whole merge silently no-ops — exactly the ancestry gap
  stage 2 refused to ship. `resolve/3`'s flat map has no place to
  carry "this directory's own historical schema commit," since it
  only ever returns file paths. `materialize_branch/5` therefore
  performs its own recursive walk (`resolve_anchored/4`, public seam,
  same checkpoint-reading discipline as `resolve/3` — reads each pin
  commit standalone, never chain-replayed) that additionally records,
  for every directory node, the source data-directory's own uuid and
  the exact historical commit id its `__schema_cid` pointed at — the
  commit every restored directory schema anchors its first commit to.

  A future in-place-reroot materializer (pointing existing paths back
  at restored content instead of branching) is a second, independent
  consumer of `resolve/3` — it should be addable without touching
  `resolve/3` at all. Keep it that way.

  ## What the recorded checkpoint format actually supports

  This took some archaeology, so it's recorded here rather than left
  as tribal knowledge.

  A directory's `__snapshot` doc (`Snapshot.build_reflog_doc/3`) is a
  flat map:

      %{
        "__schema_cid" => <hex commit_id of this dir's OWN data-schema
                            commit at checkpoint time, or absent if the
                            data dir had no commits yet>,
        "__timestamp"  => <ISO8601 string>,
        "file.txt"     => <hex commit_id of file.txt's OWN latest
                            commit at checkpoint time>,
        "subdir"       => <hex commit_id of subdir's own reflog dir's
                            __snapshot doc commit, at checkpoint time —
                            NOT the subdir's data-schema commit>
      }

  Two things this map does **not** carry, that resolution needs:

    1. **Doc UUIDs.** Every value is a bare commit id. A commit id
       alone doesn't say which document it belongs to — `commit_id` is
       a content hash, not a pointer.
    2. **Entry type (file vs. dir).** The map has no type tag; `"doc"` /
       `"dir"` distinction lives only in the schema, not the reflog
       snapshot.

  Both gaps are closed by combining two things the store already gives
  us for free:

    * `Commit.doc_uuid` — every stored commit carries the uuid of the
      doc it was written to (`Commonplace.Store.Commit` calls this
      "Historical... debugging only": it is **not** folded into the
      commit's content-addressed id, so it is not Merkle-verified or
      tamper-evident). `CommitStoreClient.get_commit/2` is a pure
      point-read by commit id that returns it. Resolution leans on this
      field to go from "a bare commit id" back to "which document did
      this commit land on" — the only place in this module that trusts
      a non-content-addressed field, and safe here because restore only
      ever runs against the LOCAL store the caller already trusts (the
      same trust boundary `checkpoint/3` itself writes under).
    * `__schema_cid` — recorded specifically so resolution has an entry
      point: `get_commit(schema_cid).doc_uuid` gives the data
      directory's own uuid, and `reconstruct_doc_at(store, that_uuid,
      schema_cid)` replays the schema exactly as it stood at checkpoint
      time. THAT schema is where the type tag and every entry's real
      `node_id` (doc uuid) come from — the reflog map's per-entry hex
      values are then just looked up by name against this schema-typed
      entry list, joining "what type / what uuid" (from the historical
      schema) with "what commit" (from the reflog map).
    * For a `:dir` entry, the recorded hex commit id is itself the
      child's `__snapshot` doc's commit id, so `get_commit(...).doc_uuid`
      on THAT commit hands us the child snapshot doc's uuid directly —
      no name-based navigation of the (live, mutable) reflog tree is
      needed to recurse; the child snapshot lookup is fully determined
      by the values already in hand.

  What is **not** recoverable: any entry whose name was excluded from
  the recorded map at checkpoint time. As of CX-0t2r, presence-transient
  `.usr` entries (configurable via
  `Application.get_env(:commonplace, :reflog_exclude_suffixes, [".usr"])`)
  are deliberately excluded from the write side to keep heartbeat churn
  from defeating the checkpoint cursor. `resolve/3` cannot distinguish
  "excluded at write time" from "genuinely absent at that path" — both
  simply produce no entry in the resolved map. If a data dir had zero
  commits at checkpoint time (`schema_cid_hex == nil`), the whole
  subtree resolves to `%{}`.

  ## Acceptance scope (see `restore_test.exs`)

  The test suite for this module covers the BRANCH materializer
  (`materialize_branch/5`) — round-trip fidelity, ancestry (every
  restored doc's first commit chains to the checkpoint's recorded
  source commit), merge-back (the capability ancestry buys — a branch
  edit merges cleanly back toward the live tree via
  `Commonplace.Tree.Merge.merge/3`), enforce-mode signing, and the
  resolve-is-read-only seam property. An in-place materializer, when
  it exists, needs its own acceptance tests; passing this suite says
  nothing about that path.
  """

  alias Commonplace.Projection
  alias Commonplace.Tree.{Schema, DocBuilder}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Document.ContentType
  alias Commonplace.Crypto.{NodeIdentity, SigningContext}
  alias Commonplace.WriterHand
  alias Commonplace.DerivationRecord
  alias Commonplace.Reflog.Snapshot
  alias Commonplace.Sync.{Export, CheckoutRegistry}

  require Logger

  @default_owner "server"

  @doc """
  List available checkpoints for `owner` under `root_uuid`'s reflog
  branch, newest first. Each entry is `{commit_id, timestamp,
  signer_id}` — one per commit on the root reflog dir's `__snapshot`
  doc (each such commit IS one checkpoint).

  Read-mostly: `Snapshot.ensure_reflog_branch/3` mints the `__reflog`
  scaffolding if it doesn't exist yet (mirrors `checkpoint/3`'s own
  behavior) — a no-op once a single checkpoint has ever been taken.

  Filters out the synthetic genesis commit `create_chained_commit/5`
  auto-mints as the first commit of every fresh `__snapshot` doc
  (`metadata.kind == :genesis`) — it carries no checkpoint content, so
  counting it as a checkpoint would off-by-one every listing.
  """
  @spec list_checkpoints(GenServer.server(), String.t(), String.t()) ::
          [{binary(), DateTime.t(), String.t() | nil}]
  def list_checkpoints(store \\ CommitStoreClient, root_uuid, owner \\ @default_owner) do
    case root_snapshot_uuid(store, root_uuid, owner) do
      {:ok, snapshot_uuid} ->
        CommitStoreClient.commit_log(store, snapshot_uuid)
        |> Enum.reject(&genesis_commit?/1)
        |> Enum.map(fn commit -> {commit.id, commit.timestamp, commit.signer_id} end)

      :error ->
        []
    end
  end

  defp genesis_commit?(%{metadata: %{kind: :genesis}}), do: true
  defp genesis_commit?(_), do: false

  @doc """
  Resolve the root reflog dir's own `__snapshot` doc uuid for `owner`
  under `root_uuid` — the handle `resolve/3` needs as its second
  argument. Exposed separately from `list_checkpoints/3` so callers
  (the CLI, tests) that already have a checkpoint commit id in hand
  don't have to re-derive it by re-listing.
  """
  @spec root_snapshot_uuid(GenServer.server(), String.t(), String.t()) ::
          {:ok, String.t()} | :error
  def root_snapshot_uuid(store \\ CommitStoreClient, root_uuid, owner \\ @default_owner) do
    {:ok, owner_uuid} = Snapshot.ensure_reflog_branch(root_uuid, owner, store)
    owner_schema = load_schema(owner_uuid, store)

    case Schema.get_entry(owner_schema, "__snapshot") do
      {:ok, entry} -> {:ok, entry.node_id}
      :error -> :error
    end
  end

  @doc """
  Resolve one checkpoint into a flat `%{path => {:file, doc_uuid,
  commit_id_hex}}` map. `snapshot_doc_uuid` is a reflog dir's own
  `__snapshot` doc uuid (the root's, from `root_snapshot_uuid/3`, for a
  whole-tree restore); `checkpoint_commit_id` is a commit id on that
  doc's chain (from `list_checkpoints/3`).

  Pure and read-only — issues no writes. See the moduledoc's "What the
  recorded checkpoint format actually supports" for exactly what this
  can and cannot recover.

  Returns `{:ok, resolved}` or `{:error, reason}`.
  """
  @spec resolve(GenServer.server(), String.t(), binary()) ::
          {:ok, %{optional(String.t()) => {:file, String.t(), String.t()}}}
          | {:error, term()}
  def resolve(store \\ CommitStoreClient, snapshot_doc_uuid, checkpoint_commit_id) do
    case single_commit_doc(store, checkpoint_commit_id, snapshot_doc_uuid) do
      {:ok, doc} ->
        content = ContentType.get_content(doc) || %{}
        resolve_from_content(store, content)

      :none ->
        {:error, {:checkpoint_not_found, checkpoint_commit_id}}

      {:error, _} = err ->
        err
    end
  end

  # Every write on the `__snapshot` doc's chain (`Snapshot.build_reflog_doc/3`)
  # mints a BRAND NEW `Yelixer.Doc.new(client_id: WriterHand.for_doc(uuid))`
  # each round — the SAME stable client_id every time, but starting a fresh
  # op-clock from 0, not continuing from the previous round's state. That
  # stable-client choice is deliberate (CX-41qg.3, to cap state-vector
  # growth) and is safe for the doc's actual read path
  # (`Snapshot.read_snapshot/2` uses `reconstruct_snapshot/2`: apply only
  # the LATEST commit's own update to a fresh doc). It is NOT safe to
  # chain-replay multiple rounds together via `DocBuilder.reconstruct_doc/2`
  # or `reconstruct_doc_at/4` — round 2's ops reuse (client, clock) pairs
  # round 1 already used, so Yjs's idempotent merge treats them as
  # already-applied duplicates and silently drops them, leaving the replay
  # stuck on round 1's content forever. (Confirmed empirically while
  # building this module — a naive `reconstruct_doc_at` implementation
  # returned checkpoint 1's content for checkpoint 2's commit id.)
  #
  # The fix mirrors `reconstruct_snapshot/2` but at an arbitrary historical
  # commit rather than always the latest: fetch that ONE commit's own
  # `update` bytes (a self-contained full state, by construction) and apply
  # it alone to a throwaway fresh doc. Same hazard, same fix, for the DATA
  # DIRECTORY's schema commits reached via `__schema_cid` below — schema
  # docs are documented as "always store full snapshots"
  # (`DocBuilder.reconstruct_snapshot/2`'s moduledoc) for the same reason.
  #
  # CX-6scm: **this logic is now `Commonplace.Projection`'s.** What used
  # to be a `defp` here — the only implementation of the per-commit pin
  # read in the whole codebase, per the conflicted-pins census — is the
  # promoted public API, and this function is a thin adapter onto it.
  # Everything above still describes WHY the read is per-commit; what
  # changed is that the read now comes back with a VERDICT, and this
  # module has to handle the declining outcomes rather than being
  # structurally unable to hear them.
  #
  # `head_path: :direct` is a POPULATION DECLARATION, not a preference
  # (VP §7.7 R2). The rule it has to satisfy: declare `:direct` only for
  # documents production actually reads through the latest-commit path,
  # never over a delta chain, where the single-commit read returns silent
  # partial state.
  #
  # The claim, checkable: the docs reached here are the reflog
  # `__snapshot` doc and the DATA DIRECTORY's schema commits reached via
  # `__schema_cid`. Both are full-state-rewrite chains — every round
  # re-encodes the whole state from a fresh `Yelixer.Doc` under a stable
  # client_id (`Snapshot.build_reflog_doc/3`), and schema docs are
  # documented as always storing full snapshots
  # (`DocBuilder.reconstruct_snapshot/2`'s moduledoc). Neither is a delta
  # chain. Chain replay is the side that sticks on round 1 here, which
  # is the whole reason the paragraph above exists.
  #
  # Consequence, accepted: where the two paths disagree this yields the
  # `:declared` grade, which is BELOW corroborated and cannot satisfy a
  # `:corroborated` floor. Restore reads at the default `:any` floor —
  # display/materialisation grade — so it may take those bytes; an
  # export path asking the same question would correctly be refused.
  #
  # `expected_doc_uuid`, when given, is a defensive cross-check: the
  # checkpoint commit id the caller handed us should belong to the doc
  # uuid the caller believes it does. `Projection` performs it.
  defp single_commit_doc(store, commit_id, expected_doc_uuid \\ nil) do
    case CommitStoreClient.get_commit(store, commit_id) do
      {:ok, %{doc_uuid: doc_uuid}} ->
        pin_read(store, doc_uuid, commit_id, expected_doc_uuid)

      :none ->
        :none
    end
  end

  defp pin_read(store, doc_uuid, commit_id, expected_doc_uuid) do
    uuid = expected_doc_uuid || doc_uuid

    case Projection.project_doc_at(uuid, commit_id,
           store: store,
           head_path: :direct
         ) do
      {:ok, doc, _verdict} ->
        {:ok, doc}

      # A hole in a restore is a NAMED refusal, never a silently-wrong
      # tree. Display and restore both surface this rather than
      # laundering it into bytes.
      {:unknown, reason} ->
        {:error, {:projection_unknown, commit_id, reason}}

      {:error, {:commit_not_found, _}} ->
        :none

      {:error, {:commit_not_on_chain, _}} ->
        :none

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_from_content(store, content) when is_map(content) do
    case Map.get(content, "__schema_cid") do
      nil ->
        # No schema_cid recorded — the data dir had no commits yet at
        # checkpoint time, so it had no entries either. Empty subtree.
        {:ok, %{}}

      schema_cid_hex ->
        resolve_via_schema_cid(store, schema_cid_hex, content)
    end
  end

  defp resolve_from_content(_store, _content), do: {:ok, %{}}

  defp resolve_via_schema_cid(store, schema_cid_hex, content) do
    schema_commit_id = Base.decode16!(schema_cid_hex, case: :lower)

    case single_commit_doc(store, schema_commit_id) do
      {:ok, schema_doc} ->
        entries =
          Schema.list_entries(schema_doc)
          |> Enum.reject(&String.starts_with?(&1.name, "__"))

        resolve_entries(store, entries, content)

      :none ->
        {:error, {:schema_commit_not_found, schema_cid_hex}}

      {:error, _} = err ->
        err
    end
  end

  defp resolve_entries(store, entries, content) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, acc} ->
      case Map.get(content, entry.name) do
        nil ->
          # Not in the recorded map — either excluded at write time
          # (e.g. `.usr`) or a schema/reflog inconsistency. Either way
          # there is nothing to resolve for this name; skip it rather
          # than fail the whole checkpoint.
          {:cont, {:ok, acc}}

        hex ->
          resolve_entry(store, entry, hex, acc)
      end
    end)
  end

  defp resolve_entry(_store, %Schema.Entry{type: :doc, node_id: node_id, name: name}, hex, acc) do
    {:cont, {:ok, Map.put(acc, name, {:file, node_id, hex})}}
  end

  defp resolve_entry(store, %Schema.Entry{type: :dir, name: name}, hex, acc) do
    commit_id = Base.decode16!(hex, case: :lower)

    case CommitStoreClient.get_commit(store, commit_id) do
      {:ok, child_commit} ->
        case resolve(store, child_commit.doc_uuid, commit_id) do
          {:ok, child_resolved} ->
            prefixed =
              Map.new(child_resolved, fn {path, v} -> {name <> "/" <> path, v} end)

            {:cont, {:ok, Map.merge(acc, prefixed)}}

          {:error, _} = err ->
            {:halt, err}
        end

      :none ->
        {:halt, {:error, {:child_snapshot_commit_not_found, hex}}}
    end
  end

  defp resolve_entry(_store, _entry, _hex, acc), do: {:cont, {:ok, acc}}

  @doc """
  Fork-anchored branch materializer (CX-0t2r stage 3): materialize one
  checkpoint as a brand-new branch grafted onto `root_uuid`, with real
  ancestry — the shared-history property `Commonplace.Tree.Fork`
  gives its forks, so a later `Commonplace.Tree.Merge.merge/3` back
  toward the live tree works.

  `snapshot_doc_uuid` and `checkpoint_commit_id` are the exact same
  two identifiers `resolve/3` takes (a reflog dir's own `__snapshot`
  doc uuid, and a checkpoint commit id on its chain) — `root_uuid` is
  the *live* directory this checkpoint was taken of (the checkpoint's
  own top-level anchor, and where the new branch gets attached).

  For every file the checkpoint recorded, mints a fresh doc under a
  new uuid whose first commit's `parent_id` is the *exact* commit id
  the checkpoint recorded for that path (`Commit.create_commit/6`,
  mirroring `Commonplace.Tree.Fork`'s per-doc materialization — the
  exact-cut upgrade of `fork_directory_at/4`'s timestamp-nearest
  anchoring, since a checkpoint's recorded commit ids are already
  precise). For every directory (including the new root), assembles a
  fresh schema doc referencing the newly-minted children and anchors
  *its* first commit to the exact historical commit id the source
  directory's own `__schema_cid` pointed at when the checkpoint was
  taken — see the moduledoc's "Why `resolve/3`'s output isn't enough"
  for why this can't be derived from `resolve/3`'s flat map alone. No
  restored doc — file or directory — starts with `parent_id: nil`
  (mirrors `Fork`'s "no new doc starts with parent_id: nil" invariant;
  the sole exception, matching `Fork`'s own degenerate case, is a
  directory that genuinely had zero commits at checkpoint time — there
  is no commit to anchor to because none ever existed).

  The new root directory is attached to `root_uuid` under `opts[:as]`
  (default `"restored-<ISO8601 basic timestamp>"`).

  All writes are node-signed by default via
  `Commonplace.Crypto.NodeIdentity.signing_context/0` (falls back to
  unsigned only if no node identity is available — a bare
  library-embedding/test context) — this is a node-authored system
  operation, not a session's own write, the same posture
  `Snapshot.checkpoint/3` takes (CX-cl65's lesson: enforce-mode
  round-trips need a real signer, not just a permissive test). Pass
  `opts[:signing_context]` to override with a specific context.

  Returns `{:ok, %{root_entry: name, docs: count, derivation_record:
  record}}` where `count` is every fresh doc minted (files + directory
  schemas, including the new root), or `{:error, reason}` if the
  checkpoint itself can't be resolved (same failure shapes `resolve/3`
  can return). `derivation_record` (CX-vt9l.2, additive — existing
  callers reading `root_entry`/`docs` see no change) is a
  `Commonplace.DerivationRecord` whose `sources_pin` is the single
  `%{snapshot_doc_uuid => checkpoint_commit_id}` pin that fully
  determines this materialization (the same pin `resolve_anchored/4`
  walks from — regenerating from that one pin alone reproduces this
  same branch) and whose `output` is `{new_root_uuid, commit_id}` for
  the freshly attached root.
  """
  @spec materialize_branch(GenServer.server(), String.t(), binary(), String.t(), keyword()) ::
          {:ok, %{root_entry: String.t(), docs: non_neg_integer(), derivation_record: DerivationRecord.t()}}
          | {:error, term()}
  def materialize_branch(
        store \\ CommitStoreClient,
        snapshot_doc_uuid,
        checkpoint_commit_id,
        root_uuid,
        opts \\ []
      ) do
    with {:ok, anchored} <-
           resolve_anchored(store, snapshot_doc_uuid, checkpoint_commit_id, root_uuid) do
      signing_opts = resolve_signing_opts(opts)
      name = Keyword.get(opts, :as) || default_branch_name()

      {new_root_uuid, docs} = materialize_anchored_tree(store, anchored, signing_opts)
      attach_to_root(store, root_uuid, name, new_root_uuid, signing_opts)

      record =
        branch_derivation_record(store, snapshot_doc_uuid, checkpoint_commit_id, new_root_uuid)

      {:ok, %{root_entry: name, docs: docs, derivation_record: record}}
    end
  end

  # CX-vt9l.2: sources_pin is the SAME two identifiers materialize_branch/5
  # itself took (snapshot_doc_uuid, checkpoint_commit_id) — that one pin
  # is what resolve_anchored/4 walks to reproduce the whole tree, so it is
  # what makes this branch regenerable ("staleness decidable" per the
  # convention doc), not the many per-file pins the walk touches along the
  # way.
  defp branch_derivation_record(store, snapshot_doc_uuid, checkpoint_commit_id, new_root_uuid) do
    output_ref =
      case CommitStoreClient.latest_commit(store, new_root_uuid) do
        {:ok, commit} -> {new_root_uuid, commit.id}
        :none -> nil
      end

    DerivationRecord.new(
      %{snapshot_doc_uuid => checkpoint_commit_id},
      "reflog-restore-materialize_branch-v1",
      output_ref
    )
  end

  # --- anchored resolution (stage 3, private — resolve/3 stays untouched) --
  #
  # Structurally the same recursive walk `resolve/3` performs (same
  # `__schema_cid` / reflog-map archaeology, same "read each pin commit
  # standalone, never chain-replay" discipline via `single_commit_doc/2,3`),
  # but where `resolve/3` discards everything except the flat file map,
  # this keeps the two things a directory needs to anchor its own restored
  # schema commit: `dir_uuid` (the source data-directory's own uuid — for
  # a `:dir` schema entry this is `entry.node_id`, the SAME live uuid
  # Commonplace.Tree.Fork would fork from) and `schema_commit_id` (the
  # exact historical commit `__schema_cid` pointed at, decoded once here
  # instead of being thrown away after `resolve_via_schema_cid/3` reads
  # its content).
  @doc """
  The ancestry-carrying resolver — the tree-shaped sibling of `resolve/3`.

  Public because it is the SEAM for store-side materializers (CX-0t2r):
  `materialize_branch/5` consumes it today, and a future in-place-reroot
  materializer (stage-4 decision) must consume the SAME resolver rather
  than growing its own walk — same rule that keeps `resolve/3` shared
  between `materialize_dir/4` and `diff/3`. Read-only, per-commit pin
  reads (never chain-replayed), zero writes.
  """
  def resolve_anchored(store, snapshot_doc_uuid, checkpoint_commit_id, dir_uuid) do
    case single_commit_doc(store, checkpoint_commit_id, snapshot_doc_uuid) do
      {:ok, doc} ->
        content = ContentType.get_content(doc) || %{}
        resolve_anchored_from_content(store, content, dir_uuid)

      :none ->
        {:error, {:checkpoint_not_found, checkpoint_commit_id}}

      {:error, _} = err ->
        err
    end
  end

  defp resolve_anchored_from_content(store, content, dir_uuid) when is_map(content) do
    case Map.get(content, "__schema_cid") do
      nil ->
        # No schema_cid recorded — the data dir had no commits yet at
        # checkpoint time. Nothing to anchor to; this is the one case
        # (mirroring Fork's own "source has no commits" fallback) where
        # the eventual schema commit has no legitimate parent.
        {:ok, %{dir_uuid: dir_uuid, schema_commit_id: nil, files: %{}, dirs: %{}}}

      schema_cid_hex ->
        resolve_anchored_via_schema_cid(store, schema_cid_hex, content, dir_uuid)
    end
  end

  defp resolve_anchored_from_content(_store, _content, dir_uuid),
    do: {:ok, %{dir_uuid: dir_uuid, schema_commit_id: nil, files: %{}, dirs: %{}}}

  defp resolve_anchored_via_schema_cid(store, schema_cid_hex, content, dir_uuid) do
    schema_commit_id = Base.decode16!(schema_cid_hex, case: :lower)

    case single_commit_doc(store, schema_commit_id) do
      {:ok, schema_doc} ->
        entries =
          Schema.list_entries(schema_doc)
          |> Enum.reject(&String.starts_with?(&1.name, "__"))

        resolve_anchored_entries(store, entries, content, dir_uuid, schema_commit_id)

      :none ->
        {:error, {:schema_commit_not_found, schema_cid_hex}}

      {:error, _} = err ->
        err
    end
  end

  defp resolve_anchored_entries(store, entries, content, dir_uuid, schema_commit_id) do
    base = %{dir_uuid: dir_uuid, schema_commit_id: schema_commit_id, files: %{}, dirs: %{}}

    Enum.reduce_while(entries, {:ok, base}, fn entry, {:ok, acc} ->
      case Map.get(content, entry.name) do
        nil ->
          # Not in the recorded map — excluded at write time (e.g. `.usr`)
          # or a schema/reflog inconsistency. Skip rather than fail the
          # whole checkpoint (same policy as resolve/3's resolve_entries/3).
          {:cont, {:ok, acc}}

        hex ->
          resolve_anchored_entry(store, entry, hex, acc)
      end
    end)
  end

  defp resolve_anchored_entry(_store, %Schema.Entry{type: :doc, node_id: node_id, name: name}, hex, acc) do
    commit_id = Base.decode16!(hex, case: :lower)
    {:cont, {:ok, put_in(acc, [:files, name], {node_id, commit_id})}}
  end

  defp resolve_anchored_entry(store, %Schema.Entry{type: :dir, node_id: node_id, name: name}, hex, acc) do
    commit_id = Base.decode16!(hex, case: :lower)

    case CommitStoreClient.get_commit(store, commit_id) do
      {:ok, child_commit} ->
        case resolve_anchored(store, child_commit.doc_uuid, commit_id, node_id) do
          {:ok, subtree} -> {:cont, {:ok, put_in(acc, [:dirs, name], subtree)}}
          {:error, _} = err -> {:halt, err}
        end

      :none ->
        {:halt, {:error, {:child_snapshot_commit_not_found, hex}}}
    end
  end

  defp resolve_anchored_entry(_store, _entry, _hex, acc), do: {:cont, {:ok, acc}}

  # Depth-first materialization of an anchored tree: children (files and
  # subdirectories) materialize before the parent's schema is written, so
  # remapped child uuids already exist in the store when the parent
  # schema references them — same ordering Fork uses. Returns
  # `{new_dir_uuid, doc_count}`.
  defp materialize_anchored_tree(store, %{files: files, dirs: dirs, schema_commit_id: parent_id}, signing_opts) do
    {schema, count} =
      Enum.reduce(files, {Schema.new_schema(), 0}, fn {name, {doc_uuid, commit_id}}, {schema_acc, count_acc} ->
        {new_uuid, added} = materialize_file(store, doc_uuid, commit_id, signing_opts)
        {Schema.add_file(schema_acc, name, new_uuid), count_acc + added}
      end)

    {schema, count} =
      Enum.reduce(dirs, {schema, count}, fn {name, subtree}, {schema_acc, count_acc} ->
        {child_uuid, added} = materialize_anchored_tree(store, subtree, signing_opts)
        {Schema.add_directory(schema_acc, name, child_uuid), count_acc + added}
      end)

    new_dir_uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(schema)
    {meta, commit_opts} = split_opts(signing_opts)

    # Branch-point commit: the restored directory schema chains to the
    # EXACT historical commit the checkpoint's __schema_cid recorded for
    # this source directory — the same fork-anchoring Commonplace.Tree.Fork
    # gives every directory it forks, and the property
    # Commonplace.Tree.Merge.find_common_ancestor/3 needs at every
    # directory hop for merge-back to work, not just at the root.
    if parent_id do
      CommitStoreClient.create_commit(store, new_dir_uuid, update, parent_id, meta, commit_opts)
    else
      # No historical commit ever existed for this directory (see
      # resolve_anchored_from_content/3) — nothing to anchor to.
      CommitStoreClient.create_chained_commit(store, new_dir_uuid, update, meta, commit_opts)
    end

    {new_dir_uuid, count + 1}
  end

  defp resolve_signing_opts(opts) do
    case Keyword.fetch(opts, :signing_context) do
      {:ok, %SigningContext{} = sc} ->
        [signing_context: sc]

      :error ->
        case NodeIdentity.signing_context() do
          {:ok, sc} ->
            [signing_context: sc]

          {:error, reason} ->
            Logger.debug(
              "Reflog restore: no node identity (#{inspect(reason)}), writing unsigned"
            )

            []
        end
    end
  end

  defp default_branch_name do
    "restored-" <> DateTime.to_iso8601(DateTime.utc_now(), :basic)
  end

  # `commit_id` is already a decoded binary here — resolve_anchored_entry/4
  # decodes the checkpoint's recorded hex once when building the anchored
  # tree, so materialization never re-decodes it.
  defp materialize_file(store, source_doc_uuid, commit_id, signing_opts) do
    new_uuid = UUID.uuid4()

    # CX-6scm: this MATERIALISES a branch — it turns a pin read into new
    # committed history — so an undecidable pin must refuse rather than
    # pick a candidate. Picking here would launder a conflicted pin into
    # a fresh commit that looks authoritative forever, which is the
    # no-retroactive-WITNESSED rule violated in the other direction.
    update =
      case Projection.project_at(source_doc_uuid, commit_id, store: store) do
        {:ok, bytes, _verdict} ->
          bytes

        {:error, reason} when elem(reason, 0) in [:commit_not_found, :commit_not_on_chain] ->
          Yelixer.Encoding.encode_update(Yelixer.Doc.new())

        other ->
          throw({:materialize_refused, source_doc_uuid, commit_id, other})
      end

    {meta, commit_opts} = split_opts(signing_opts)
    # Branch-point commit: chains to the exact source commit that was
    # checkpointed, same provenance shape as Fork's leaf materialization.
    CommitStoreClient.create_commit(store, new_uuid, update, commit_id, meta, commit_opts)

    {new_uuid, 1}
  end

  defp attach_to_root(store, root_uuid, name, new_root_uuid, signing_opts) do
    schema =
      case DocBuilder.reconstruct_snapshot(store, root_uuid, client_id: WriterHand.for_doc(root_uuid)) do
        {:ok, doc} -> doc
        :none -> Schema.new_schema()
      end

    schema = Schema.add_directory(schema, name, new_root_uuid)
    update = Yelixer.Encoding.encode_update(schema)
    {meta, commit_opts} = split_opts(signing_opts)
    CommitStoreClient.create_chained_commit(store, root_uuid, update, meta, commit_opts)
  end

  defp split_opts([]), do: {%{}, []}
  defp split_opts(signing_opts), do: {%{}, signing_opts}

  @doc """
  Materialize a `resolve/3` result to plain files on disk under
  `dest_dir` — the LOCAL CHECKOUT materializer (stage 2, variant a).

  Unlike `materialize_branch/5`, this issues **zero store writes**: it
  is a pure read (reconstruct each pinned commit) fanned out to
  ordinary file I/O, using the same atomic-write convention
  `Commonplace.Sync.Export` uses for regular sync. There is no CRDT
  doc minted, no schema, no commit — restoring to a directory is not a
  commonplace tree operation at all, just a snapshot dump.

  Each `{path, {:file, doc_uuid, commit_id_hex}}` in `resolved` is
  reconstructed via `DocBuilder.reconstruct_doc_at/3` — data docs are
  ordinary delta-chained docs (unlike the reflog/schema pin docs
  `resolve/3` itself reads), so this is the correct reconstruction
  path here, deliberately different from how `resolve/3` reads pins.

  Refuses (returns `{:error, reason}`, writes nothing) when:

    * `dest_dir` resolves inside a checkout registered in
      `opts[:config_path]` (a `checkouts.json` path, checked via
      `Commonplace.Sync.CheckoutRegistry.find_for_cwd/2`) — this
      guarantees a checkout materialization never touches a live sync
      tree. Skipped (best-effort only) if `opts[:config_path]` is
      omitted; callers that care about this guarantee (the CLI) must
      pass it.
    * `dest_dir` exists and is non-empty, unless `opts[:force] == true`.

  `opts[:owner]` and `opts[:at]` are carried through unchanged into
  the returned map's `:witness` / `:at` fields purely for labeling —
  this function has no way to derive them itself (`resolved` carries
  no checkpoint metadata), so the caller (which has the checkpoint's
  owner/timestamp from `list_checkpoints/3`) is responsible for
  passing them. Output built from this function's result must be
  labelled "as seen by witness `<owner>` at `<at>`" and must NOT be
  presented as invariant-safe (per the CX-0t2r summit's coherence
  bound: a checkpoint is coherent-with-what-the-witness-saw, not a
  guarantee nothing was mid-mutation).

  Returns `{:ok, %{files: count, dest: dest_dir, witness: owner, at: at,
  derivation_record: record}}`. `derivation_record` (CX-vt9l.2,
  additive — every other key is unchanged) is a
  `Commonplace.DerivationRecord` whose `sources_pin` is `resolved`
  itself reshaped to `%{doc_uuid => commit_id}` (the `Black.Query` pin
  shape) and whose `output` is the plain filesystem path `dest_dir` —
  materialize_dir writes ordinary files, not a commonplace doc, so the
  output ref is a path rather than a `{uuid, commit_id}` pair.
  """
  @spec materialize_dir(GenServer.server(), map(), String.t(), keyword()) ::
          {:ok,
           %{
             files: non_neg_integer(),
             dest: String.t(),
             witness: String.t() | nil,
             at: term(),
             derivation_record: DerivationRecord.t()
           }}
          | {:error, term()}
  def materialize_dir(store \\ CommitStoreClient, resolved, dest_dir, opts \\ []) do
    with :ok <- check_not_inside_checkout(dest_dir, opts),
         :ok <- check_dest_writable(dest_dir, opts) do
      File.mkdir_p!(dest_dir)
      files = write_files(store, resolved, dest_dir)

      record =
        DerivationRecord.new(
          dir_sources_pin(resolved),
          "reflog-restore-materialize_dir-v1",
          dest_dir
        )

      {:ok,
       %{
         files: files,
         dest: dest_dir,
         witness: Keyword.get(opts, :owner, @default_owner),
         at: Keyword.get(opts, :at),
         derivation_record: record
       }}
    end
  end

  # Reshape resolve/3's `%{path => {:file, doc_uuid, commit_id_hex}}`
  # into the `Black.Query` pin shape `%{doc_uuid => commit_id}` (binary,
  # not hex) DerivationRecord expects — same reuse-not-reinvent rule the
  # convention doc names.
  defp dir_sources_pin(resolved) do
    Map.new(resolved, fn {_path, {:file, doc_uuid, commit_id_hex}} ->
      {doc_uuid, Base.decode16!(commit_id_hex, case: :lower)}
    end)
  end

  defp check_not_inside_checkout(dest_dir, opts) do
    case Keyword.get(opts, :config_path) do
      nil ->
        :ok

      config_path ->
        abs_dest = Path.expand(dest_dir)

        case CheckoutRegistry.find_for_cwd(config_path, abs_dest) do
          {:ok, checkout} -> {:error, {:dest_inside_checkout, checkout}}
          :none -> :ok
        end
    end
  end

  defp check_dest_writable(dest_dir, opts) do
    force? = Keyword.get(opts, :force, false)

    case File.ls(dest_dir) do
      {:ok, []} -> :ok
      {:ok, _entries} when force? -> :ok
      {:ok, _entries} -> {:error, {:dest_not_empty, dest_dir}}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:dest_unreadable, dest_dir, reason}}
    end
  end

  defp write_files(store, resolved, dest_dir) do
    Enum.reduce(resolved, 0, fn {path, {:file, doc_uuid, commit_id_hex}}, count ->
      content = reconstruct_file_content(store, doc_uuid, commit_id_hex)
      Export.atomic_write(Path.join(dest_dir, path), content)
      count + 1
    end)
  end

  # CX-6scm: a materialised file's bytes come from the verdict-bearing
  # API. A pin whose two reconstruction paths disagree writes a NAMED
  # marker rather than one of the two candidate contents — writing either
  # would be the silent-wrong-bytes failure this layer exists to close,
  # and a checkout that silently contains the wrong version of a file is
  # worse than one that says which file it could not decide.
  defp reconstruct_file_content(store, doc_uuid, commit_id_hex) do
    commit_id = Base.decode16!(commit_id_hex, case: :lower)

    case Projection.project_doc_at(doc_uuid, commit_id, store: store) do
      {:ok, doc, _verdict} -> doc_content(doc)
      {:unknown, reason} -> unresolved_marker(commit_id_hex, reason)
      {:error, {:commit_not_found, _}} -> ""
      {:error, {:commit_not_on_chain, _}} -> ""
      {:error, reason} -> unresolved_marker(commit_id_hex, reason)
    end
  end

  defp unresolved_marker(commit_id_hex, reason) do
    "<<commonplace: could not project #{commit_id_hex} — #{inspect(reason)}>>\n"
  end

  defp doc_content(doc) do
    case ContentType.get_type(doc) do
      :text -> ContentType.get_content(doc) || ""
      _ -> ContentType.get_content(doc) |> inspect()
    end
  end

  @doc """
  Resolver-based diff — no materialization, pure reads. Compares an
  already-`resolve/3`d checkpoint map against either:

    * `{:current, root_uuid}` (the default shape a caller should pass
      for "diff against the live tree") — walks `root_uuid`'s CURRENT
      schema tree, reading each doc's **`:latest` commit** (not a
      pin), and compares against `resolved`; or
    * another `resolve/3`-shaped map, wrapped `{:checkpoint,
      other_resolved}` — compares two checkpoints directly.

  Output is `{:ok, %{added: [path], removed: [path], changed:
  [{path, :changed | :replaced}]}}`, all lists sorted:

    * `added` — paths present in `against` but not in `resolved`.
    * `removed` — paths present in `resolved` but not in `against`.
    * `changed` — same path in both, same `doc_uuid`, different
      `commit_id` (`:changed`); or same path, DIFFERENT `doc_uuid`
      (`:replaced` — the name was reused for an unrelated doc).

  `resolved` is always treated as the baseline ("before") and
  `against` as the comparand ("after") — matching how the CLI reads
  `reflog diff <checkpoint> [<other-checkpoint>]` (checkpoint is the
  older/base side, current heads or the other checkpoint is the newer
  side).
  """
  @spec diff(GenServer.server(), map(), {:current, String.t()} | {:checkpoint, map()}) ::
          {:ok,
           %{
             added: [String.t()],
             removed: [String.t()],
             changed: [{String.t(), :changed | :replaced}]
           }}
  def diff(store \\ CommitStoreClient, resolved, against) do
    other = resolve_comparand(store, against)
    {:ok, compute_diff(resolved, other)}
  end

  defp resolve_comparand(_store, {:checkpoint, other_resolved}) when is_map(other_resolved) do
    other_resolved
  end

  defp resolve_comparand(store, {:current, root_uuid}) do
    current_tree(store, root_uuid)
  end

  # Live-tree walk, structurally the same shape resolve/3 returns but
  # reading each doc's CURRENT latest commit instead of a historical
  # pin — this is the "current :latest heads of the same docs" side of
  # the diff, deliberately NOT going through resolve/3 (there is no
  # checkpoint to resolve; there is only the live schema tree).
  defp current_tree(store, root_uuid) do
    root_uuid
    |> load_schema(store)
    |> live_entries()
    |> current_tree_entries(store, "")
  end

  defp live_entries(schema_doc) do
    Schema.list_entries(schema_doc)
    |> Enum.reject(&String.starts_with?(&1.name, "__"))
  end

  defp current_tree_entries(entries, store, prefix) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      path = if prefix == "", do: entry.name, else: prefix <> "/" <> entry.name

      case entry.type do
        :doc ->
          case CommitStoreClient.latest_commit(store, entry.node_id) do
            {:ok, commit} ->
              Map.put(acc, path, {:file, entry.node_id, Base.encode16(commit.id, case: :lower)})

            :none ->
              acc
          end

        :dir ->
          sub =
            entry.node_id
            |> load_schema(store)
            |> live_entries()
            |> current_tree_entries(store, path)

          Map.merge(acc, sub)
      end
    end)
  end

  defp compute_diff(resolved, other) do
    old_paths = resolved |> Map.keys() |> MapSet.new()
    new_paths = other |> Map.keys() |> MapSet.new()

    added = new_paths |> MapSet.difference(old_paths) |> Enum.sort()
    removed = old_paths |> MapSet.difference(new_paths) |> Enum.sort()

    changed =
      old_paths
      |> MapSet.intersection(new_paths)
      |> Enum.sort()
      |> Enum.map(fn path -> {path, entry_change(Map.fetch!(resolved, path), Map.fetch!(other, path))} end)
      |> Enum.reject(fn {_path, kind} -> is_nil(kind) end)

    %{added: added, removed: removed, changed: changed}
  end

  defp entry_change({:file, uuid1, cid1}, {:file, uuid2, cid2}) do
    cond do
      uuid1 != uuid2 -> :replaced
      cid1 != cid2 -> :changed
      true -> nil
    end
  end

  defp load_schema(uuid, store) do
    case DocBuilder.reconstruct_snapshot(store, uuid, client_id: WriterHand.for_doc(uuid)) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end
end
