defmodule Commonplace.Tree.Fork do
  @moduledoc """
  Deep-copy a directory subtree under fresh UUIDs, linked back to the
  source via the commit DAG.

  A *fork* in Commonplace is not a fork in the git sense — no diff,
  no rebase, no upstream. It is a **deep copy** of a
  `Commonplace.Tree.Schema` directory tree (and all its leaf docs)
  under brand-new UUIDs. Each new doc's first commit carries a
  `parent_id` pointing at the source doc's most recent commit. The
  new tree is fully independent — edits to the fork don't touch the
  source — but every new UUID has one ancestor edge in the global
  commit DAG that records exactly which source doc it branched from.

  ## DAG branch structure

      source_root  ── commitS₁ ── commitS₂ (HEAD)
                                       │
                                       ▼ parent_id
                                       │
      forked_root  ── commitF₁ (HEAD of new doc)
                         └─ same schema content, child node_ids
                            remapped to forked children's UUIDs

  `commitF₁` is `forked_root`'s first commit. Its `parent_id` points
  at `commitS₂` (the source commit we forked from). From there the
  two chains grow independently. Cherrypick and three-way merge use
  the shared ancestor commit to anchor later operations.

  Every doc reachable from the forked root gets the same treatment:
  fresh UUID, one-commit chain, `parent_id` pointing at the
  source-side commit it branched from.

  ## No ForkManifest — provenance lives in the DAG

  Some design documents (the MUD-on-commonplace and
  beads-on-commonplace specs) describe a *ForkManifest*: an explicit
  table mapping every source UUID to its forked UUID, returned to
  callers for downstream DocRef remapping. That artifact does not
  exist in this implementation.

  Provenance is carried entirely by the commit DAG. To recover a
  forked doc's source UUID, walk back to its first commit's
  `parent_id` and look up which doc that commit belongs to — no
  side table needed.

  Consequences for callers:

    - **DocRef remap is not free.** A `DocRef` pointing into the
      source subtree does *not* automatically remap to the fork.
      The caller must know it just forked and reissue the reference.
    - **`uuid_map` stays internal.** Fork builds a
      `source_uuid => new_uuid` map during recursion and uses it to
      remap child entries in the rebuilt schema; it is not returned.
      A future caller that needs manifest-equivalent data would need
      to thread the map out of the recursion.

  Keeping the map internal holds Fork's surface area small and puts
  provenance audits on `commit_log` walks rather than a side table.
  The cost is on callers that need bulk DocRef remapping.

  ## Algorithm: depth-first copy with parent_id link

  `fork_directory/2` is the entry point. Pseudocode for the
  recursive worker (depth-first means children are fully forked
  before the parent's schema commit is written, so remapped child
  UUIDs already exist in the store when the parent references them):

      fork_node(source_uuid, store, uuid_map):
        commit = latest_commit(source_uuid)
        new_uuid = mint
        uuid_map[source_uuid] = new_uuid
        if doc is a schema (has entries):
          for each entry:
            recurse on entry.node_id        # children first
          rebuild schema with remapped child node_ids
          create_commit(new_uuid, update, parent_id: commit.id)
        else:                               # leaf doc
          create_commit(new_uuid, source_doc_update, parent_id: commit.id)
        return {new_uuid, uuid_map}

  Every `create_commit` call is synchronous. By the time
  `fork_directory/2` returns, every new UUID is materialized in the
  store.

  ## Time-travel fork (CX-65n)

  `fork_directory_at/3` has the same recursive shape as
  `fork_directory/2`, but anchors each node to a historical snapshot
  rather than HEAD:

    - The caller names a `target_commit_id` on the source root's
      chain. That commit's `timestamp` becomes the **reference time**.
    - Each descendant is anchored *independently*: `commit_at_or_before/3`
      picks the latest commit on that descendant's own chain whose
      `timestamp <= reference_time` and forks from there. The root's
      anchor does not cascade down — every doc finds its own.
    - The result is a **snapshot-consistent** fork: the entire copied
      tree reflects what the source looked like at the reference time,
      even when sub-documents have independent commit timelines that
      interleave with the root's.

  Fallback: when no commit on a descendant's chain precedes the
  reference time, the earliest available commit is used. This can
  arise only under cross-replica clock skew — commit timestamps come
  from the writing replica's wall clock, so a replica running fast can
  stamp a child commit later than the root commit it logically
  descends from. Forking from the child's earliest commit is the safe
  floor: it still yields a coherent ancestor state rather than failing.
  On a single replica, or one with synced clocks, it never triggers.

  ## Interactions with `Commonplace.Tree.Schema`

  Remapping child `node_id`s calls `Schema.remove_entry/2` followed
  by `Schema.add_file/3` or `Schema.add_directory/3`. Two semantics
  worth noting:

    - **Sync flag resets to `true`.** `add_file/3` and
      `add_directory/3` write entries with `sync: true` (via
      `encode_entry/3`'s default). Source entries that were
      `:nosync` (deactivated branches — see `Tree.Schema`'s "sync
      flag" section) come back active in the fork. This is the right
      default for the typical "fork to try a what-if" use case, but
      it is a real semantic change. Callers that need to preserve
      `:nosync` must call `Schema.deactivate/2` on those entries
      after forking.
    - **Honorific extensions are not re-checked.** `Schema.forbid_honorific!/1`
      is the user-input guard; forking is a trusted internal copy, so
      it bypasses that check — the same bypass used by
      `Commonplace.Presence.create/3` on the canonical write path. A
      `.usr` entry in the source comes back as a `.usr` entry in the
      fork.

  ## `__processes.json` filtering

  Directories containing a `__processes.json` doc get a defensive
  filter pass via `Commonplace.Process.Config.filter_json_for_fork/1`.
  Not every process registered in the source workspace should
  auto-launch in the fork (e.g. processes that own a port or are
  tagged non-fork-safe). When the filter removes entries, the forked
  `__processes.json` is rewritten with only the fork-safe subset by
  appending a *second* commit to the already-forked doc, chained to
  the same source `parent_id` as the first. Because that rewrite is
  written last, it is the latest commit on the doc's chain, so
  latest-commit-wins reconstruction returns the filtered content and
  never the unfiltered first commit. This is the one forked doc that
  carries two commits rather than one — both are still branch-point
  commits off the source, so the invariants below hold. When the
  filter removes nothing, the original content is preserved.

  This is the only place Fork names a specific filename. Every other
  doc is treated as opaque content.

  ## Dependencies

    - `Commonplace.Tree.Schema` — directory-doc primitive; its entries
      map is what gets remapped.
    - `Commonplace.Tree.DocBuilder` — `reconstruct_doc/2` and
      `reconstruct_doc_at/3` read source state at HEAD or at a
      specific commit.
    - `Commonplace.Store.CommitStoreClient` — `create_commit/4`,
      `latest_commit/2`, `commit_log/3`, `get_commit/2`. All store
      access routes through this client so the fork works identically
      against a local CubDB and a remote serve node.
    - `Commonplace.Process.Config` — only for `filter_json_for_fork/1`.
    - `Yelixer.Doc` and `Yelixer.Encoding` — empty-doc construction in
      fallback paths; encoding rebuilt schemas as wire updates.

  ## Invariants

    - **Source tree unchanged.** New commits are written only to new
      UUIDs; no commit is ever written to a source UUID.
    - **Each reachable source UUID maps to exactly one new UUID.**
      `uuid_map` is threaded through the recursion. If the same
      source UUID were reached twice (possible if a future tree shape
      let two parents point at one child), only the first visit mints;
      subsequent lookups reuse the mapping. Minting twice would split
      one shared source doc into two independent forked copies, so a
      later edit to "the" forked child would silently diverge between
      its two parents — the single-mapping rule keeps a shared child
      shared. `Tree.Schema` directories cannot share children today,
      so this case is not currently exercised.
    - **Every new doc has a branch-point commit.** Every new UUID's
      first commit has `parent_id` pointing at a source commit. No
      new doc starts with `parent_id: nil`.
    - **Schema entries reference forked UUIDs only.** The rebuilt
      schema's `entries` never name source UUIDs.
    - **Full materialization on return.** Synchronous writes
      throughout — no background build-out window.

  ## What this module is NOT

  - **Not a merge** — see `Commonplace.Tree.Merge`. Fork creates the
    branch; Merge is the three-way reconciliation for integrating fork
    edits back.
  - **Not a cherrypick** — see `Commonplace.Tree.Cherrypick`, which
    consumes the DAG branch a fork created.
  - **Not a sync trigger** — `create_commit/4` already broadcasts on
    `Commonplace.Dataflow.PubSub`; downstream agents pick up new
    commits without fork-specific notification.
  - **Not a manifest builder** — see "No ForkManifest" above.
  """

  alias Commonplace.Tree.{Schema, DocBuilder}
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Process.Config
  alias Commonplace.Document.ContentType
  alias Yelixer.{Doc, Encoding}

  @doc """
  Forks a directory subtree at HEAD. Returns the new root UUID.

  Recurses depth-first from `source_uuid`, minting a fresh UUID
  for every reachable doc and writing one commit per new UUID with
  `parent_id` pointing at the corresponding source commit. All
  writes are synchronous; the caller can read from the new root
  immediately on return.

  The internal `uuid_map` (source UUID → new UUID) is discarded
  at the top level. Callers that need the full remap must walk the
  resulting tree and reconstruct it from `parent_id` chains — see
  "No ForkManifest" in the moduledoc.

  `opts` (default `[]`) is threaded, untouched, to every
  `CommitStoreClient.create_commit/6` call this fork issues — notably
  `:signing_context` for forks that must land as signed,
  write-gate-evaluated commits under `local_write_gate: :enforce`.
  The default `[]` reproduces prior (unsigned) behavior, so every
  existing `fork_directory/2` caller is unaffected.
  """
  def fork_directory(source_uuid, store \\ CommitStoreClient, opts \\ []) do
    {new_uuid, _uuid_map} = fork_node(source_uuid, store, %{}, opts)
    new_uuid
  end

  @doc """
  Time-travel fork (CX-65n): fork the tree as it existed at a
  specific historical commit of `source_uuid`.

  `target_commit_id` must be on the source root's commit chain. Its
  timestamp becomes the reference time; each descendant is forked
  from its last commit at or before that time, producing a
  snapshot-consistent copy across sub-documents whose commit
  timelines are otherwise independent.

  Returns `{:ok, new_uuid}` on success, or `{:error, reason}` if
  `target_commit_id` is not in the source's chain.
  """
  @spec fork_directory_at(String.t(), binary(), GenServer.server(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def fork_directory_at(source_uuid, target_commit_id, store \\ CommitStoreClient, opts \\ []) do
    with {:ok, target_commit} <- fetch_target_commit(store, source_uuid, target_commit_id) do
      reference_time = target_commit.timestamp

      {new_uuid, _uuid_map} =
        fork_node_at(source_uuid, target_commit_id, reference_time, store, %{}, opts)

      {:ok, new_uuid}
    end
  end

  defp fetch_target_commit(store, source_uuid, target_commit_id) do
    case DocBuilder.reconstruct_doc_at(store, source_uuid, target_commit_id) do
      {:ok, _doc} ->
        # reconstruct_doc_at succeeded — target_commit_id is in the chain.
        # Now fetch the commit struct for its timestamp.
        case CommitStoreClient.get_commit(store, target_commit_id) do
          {:ok, commit} -> {:ok, commit}
          _ -> {:error, :target_commit_not_found}
        end

      :none ->
        {:error, :target_commit_not_in_chain}
    end
  end

  defp fork_node_at(source_uuid, target_commit_id, reference_time, store, uuid_map, opts) do
    case DocBuilder.reconstruct_doc_at(store, source_uuid, target_commit_id) do
      {:ok, source_doc} ->
        # source_doc might not decode as a schema cleanly for leaf nodes;
        # list_entries will return [] if not a schema, which is fine.
        entries = Schema.list_entries(source_doc)

        if length(entries) > 0 do
          fork_directory_node_at(source_uuid, source_doc, entries, reference_time, store, uuid_map, target_commit_id, opts)
        else
          fork_leaf_node_at(source_uuid, source_doc, target_commit_id, store, uuid_map, opts)
        end

      :none ->
        # Fallback: no historical state reachable — mint empty.
        new_uuid = UUID.uuid4()
        {new_uuid, Map.put(uuid_map, source_uuid, new_uuid)}
    end
  end

  defp fork_directory_node_at(source_uuid, source_doc, entries, reference_time, store, uuid_map, target_commit_id, opts) do
    new_uuid = UUID.uuid4()
    uuid_map = Map.put(uuid_map, source_uuid, new_uuid)

    # Two distinct anchors are in play here. `target_commit_id` is *this*
    # node's source commit — it becomes this node's parent_id at the
    # create_commit below. Each child gets its own anchor (`child_target`),
    # the latest commit on that child's chain at-or-before the reference
    # time, since sub-docs have independent commit timelines.
    {uuid_map, _} =
      Enum.reduce(entries, {uuid_map, []}, fn entry, {map, _} ->
        child_target = commit_at_or_before(store, entry.node_id, reference_time)
        {_child_new_uuid, map} = fork_node_at(entry.node_id, child_target, reference_time, store, map, opts)
        {map, []}
      end)

    # Remap child node_ids in the new schema.
    edited_doc =
      Enum.reduce(entries, source_doc, fn entry, doc ->
        new_child_uuid = Map.fetch!(uuid_map, entry.node_id)
        doc = Schema.remove_entry(doc, entry.name)

        case entry.type do
          :dir -> Schema.add_directory(doc, entry.name, new_child_uuid)
          _ -> Schema.add_file(doc, entry.name, new_child_uuid)
        end
      end)

    update = Encoding.encode_update(edited_doc)
    # 4th arg is parent_id: the forked node's first commit chains back to
    # the source commit it branched from (see moduledoc "DAG branch structure").
    CommitStoreClient.create_commit(store, new_uuid, update, target_commit_id, %{}, opts)

    {new_uuid, uuid_map}
  end

  defp fork_leaf_node_at(source_uuid, source_doc, target_commit_id, store, uuid_map, opts) do
    new_uuid = UUID.uuid4()
    uuid_map = Map.put(uuid_map, source_uuid, new_uuid)

    update = Encoding.encode_update(source_doc)
    CommitStoreClient.create_commit(store, new_uuid, update, target_commit_id, %{}, opts)

    {new_uuid, uuid_map}
  end

  # Snapshot-consistency primitive for `fork_directory_at/3`.
  # Given a child doc's UUID and the fork's reference time (the
  # timestamp of the root's target commit), returns the commit id of
  # the latest commit on the child's chain whose timestamp is <=
  # reference_time — ensuring every descendant is reconstructed at
  # the same logical snapshot regardless of how individual commit
  # timelines interleave. The chain from `commit_log/3` is newest-first,
  # so `List.last/1` is the oldest (earliest) commit — the fallback used
  # when none precede the reference time, guarding against clock skew
  # across replicas. Returns a commit id (a binary), or nil for an
  # empty chain.
  defp commit_at_or_before(store, uuid, reference_time) do
    chain = CommitStoreClient.commit_log(store, uuid, limit: CommitStore.max_commit_log_limit())

    case Enum.find(chain, fn c -> DateTime.compare(c.timestamp, reference_time) != :gt end) do
      nil ->
        case List.last(chain) do
          nil -> nil
          last -> last.id
        end

      commit ->
        commit.id
    end
  end

  # HEAD-anchored fork worker. Returns `{new_uuid, uuid_map}` where
  # the map accumulates `source_uuid => new_uuid` for every doc the
  # recursion has visited. Threading the map through the recursion
  # ensures remapped child UUIDs are available when the parent's
  # schema is rebuilt via `add_file/3` / `add_directory/3`.
  #
  # Decision branches:
  #
  #   - source has no commits → mint a UUID, write no commit
  #     (degenerate; leaves a source-missing entry in uuid_map).
  #   - source's latest commit decodes as a schema with entries →
  #     directory case; recurse into children first.
  #   - source's latest commit fails to decode as a schema, or
  #     decodes with no entries → leaf case; copy content.
  defp fork_node(source_uuid, store, uuid_map, opts) do
    case CommitStoreClient.latest_commit(store, source_uuid) do
      {:ok, commit} ->
        schema_doc = Schema.new_schema()

        case Encoding.apply_update(schema_doc, commit.update) do
          {:ok, schema_doc} ->
            entries = Schema.list_entries(schema_doc)

            if length(entries) > 0 do
              fork_directory_node(source_uuid, entries, store, uuid_map, commit, opts)
            else
              fork_leaf_node(source_uuid, store, uuid_map, commit, opts)
            end

          _ ->
            fork_leaf_node(source_uuid, store, uuid_map, commit, opts)
        end

      :none ->
        new_uuid = UUID.uuid4()
        {new_uuid, Map.put(uuid_map, source_uuid, new_uuid)}
    end
  end

  defp fork_directory_node(source_uuid, entries, store, uuid_map, commit, opts) do
    new_uuid = UUID.uuid4()
    uuid_map = Map.put(uuid_map, source_uuid, new_uuid)

    # Fork all children first to build the uuid_map
    {uuid_map, _} =
      Enum.reduce(entries, {uuid_map, []}, fn entry, {map, _} ->
        {_child_uuid, map} = fork_node(entry.node_id, store, map, opts)
        {map, []}
      end)

    # Reconstruct source schema and remap node_ids
    case reconstruct_doc(store, source_uuid) do
      {:ok, source_doc} ->
        edited_doc =
          Enum.reduce(entries, source_doc, fn entry, doc ->
            new_child_uuid = Map.fetch!(uuid_map, entry.node_id)
            doc = Schema.remove_entry(doc, entry.name)

            case entry.type do
              :dir -> Schema.add_directory(doc, entry.name, new_child_uuid)
              _ -> Schema.add_file(doc, entry.name, new_child_uuid)
            end
          end)

        # Filter __processes.json if present
        edited_doc = maybe_filter_processes(edited_doc, entries, store, uuid_map, opts)

        # Create the schema edit commit branching off the source's chain
        update = Encoding.encode_update(edited_doc)
        CommitStoreClient.create_commit(store, new_uuid, update, commit.id, %{}, opts)

      :none ->
        # Source doc missing — create empty schema commit as branch point
        update = Encoding.encode_update(Schema.new_schema())
        CommitStoreClient.create_commit(store, new_uuid, update, commit.id, %{}, opts)
    end

    {new_uuid, uuid_map}
  end

  defp fork_leaf_node(source_uuid, store, uuid_map, commit, opts) do
    new_uuid = UUID.uuid4()
    uuid_map = Map.put(uuid_map, source_uuid, new_uuid)

    # Branch-point commit: same content under new UUID, parent = source's commit
    case reconstruct_doc(store, source_uuid) do
      {:ok, doc} ->
        update = Encoding.encode_update(doc)
        CommitStoreClient.create_commit(store, new_uuid, update, commit.id, %{}, opts)

      :none ->
        # Source doc missing — create minimal branch-point commit
        update = Encoding.encode_update(Doc.new())
        CommitStoreClient.create_commit(store, new_uuid, update, commit.id, %{}, opts)
    end

    {new_uuid, uuid_map}
  end

  defp reconstruct_doc(store, doc_uuid) do
    DocBuilder.reconstruct_doc(store, doc_uuid)
  end

  defp maybe_filter_processes(schema_doc, entries, store, uuid_map, opts) do
    proc_entry = Enum.find(entries, &(&1.name == "__processes.json"))

    if proc_entry do
      new_proc_uuid = Map.get(uuid_map, proc_entry.node_id)

      case reconstruct_doc(store, proc_entry.node_id) do
        {:ok, proc_doc} ->
          content = ContentType.get_content(proc_doc) || "{}"

          case Jason.decode(content) do
            {:ok, json} when is_map(json) ->
              filtered = Config.filter_json_for_fork(json)

              if map_size(filtered) < map_size(json) and new_proc_uuid do
                case CommitStoreClient.latest_commit(store, new_proc_uuid) do
                  {:ok, branch_commit} ->
                    new_doc = Doc.new()
                    new_doc = ContentType.create(new_doc, :text, "__processes.json")
                    filtered_json = Jason.encode!(filtered)
                    new_doc = if filtered_json != "", do: ContentType.insert_text(new_doc, 0, filtered_json), else: new_doc
                    update = Encoding.encode_update(new_doc)
                    CommitStoreClient.create_commit(store, new_proc_uuid, update, branch_commit.parent_id, %{}, opts)

                  :none ->
                    :ok
                end
              end

              schema_doc

            _ ->
              schema_doc
          end

        _ ->
          schema_doc
      end
    else
      schema_doc
    end
  end
end
