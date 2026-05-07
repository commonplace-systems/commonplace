defmodule Commonplace.Tree.Fork do
  @moduledoc """
  Deep-copy a directory subtree with fresh UUIDs, linked back to the
  source via the commit DAG.

  A *fork* in Commonplace is not a fork in the git sense. There is
  no diff, no rebase, no upstream. A fork is a **deep copy** of a
  tree of `Commonplace.Tree.Schema` docs (and their leaves) under
  brand-new UUIDs, where each new doc's first commit's `parent_id`
  points back to the source doc's most recent commit. The new tree
  is fully independent — edits to the fork don't affect the source,
  and vice versa — but every new UUID has a single ancestor edge in
  the global commit DAG that names exactly which source doc it was
  branched from.

  ## What "DAG branch" means here

      source_root  ── commitS₁ ── commitS₂ (HEAD)
                                       │
                                       ▼
                                  parent_id
                                       │
      forked_root  ── commitF₁ (HEAD of new doc)
                       │
                       └─ same schema content, child node_ids
                          remapped to forked children's UUIDs

  `commitF₁` is the first commit of `forked_root`. Its `parent_id`
  points at `commitS₂` (or whichever commit of `source_root` we
  forked from). `forked_root` has its own commit chain from there
  onward; the source's chain continues independently. Cherrypick
  and three-way merge use the shared commit ancestor to resolve
  later operations.

  Every doc reachable from the forked root gets the same treatment:
  fresh UUID, single-commit chain, parent_id pointing back at the
  source-side commit it was branched from.

  ## No ForkManifest — provenance lives in the DAG

  Earlier design notes around fork (the MUD-on-commonplace and
  beads-on-commonplace specs at the design-doc level) speak of a
  *ForkManifest* — an explicit table mapping every source UUID to
  every forked UUID, returned to callers and used downstream for
  DocRef remapping (e.g. `beads-on-commonplace.md` §13). That
  artifact does not exist in this implementation. Provenance is
  carried entirely by the commit DAG: any forked doc's source UUID
  is recoverable by walking back through its first commit's
  `parent_id` and looking up which doc that commit belongs to.

  Consequences for callers:

    - **DocRef remap is not free.** Code that holds a `DocRef`
      pointing into the source subtree does *not* automatically
      get a remapped DocRef pointing into the fork. The caller has
      to know it just forked and reissue the reference.
    - **uuid_map stays internal.** This module builds a
      `source_uuid => new_uuid` map during the recursive fork walk
      and uses it to remap the schema's child entries; the map is
      not returned. If a future caller needs an equivalent of the
      manifest, the recursion would need to thread it out.

  The "no manifest" choice keeps Fork's surface area small and
  makes provenance audits a `commit_log` walk rather than a
  side-table lookup. The cost is shifted to callers that need
  bulk DocRef remapping.

  ## Algorithm: depth-first deep copy with parent_id link

  `fork_directory/2` is the entry point. The recursion is:

      fork_node(source_uuid, store, uuid_map):
        commit = latest_commit(source_uuid)
        if doc is a schema (has entries):
          new_uuid = mint
          uuid_map[source_uuid] = new_uuid
          for each entry:
            recurse on entry.node_id (depth-first; child first)
          rebuild schema with remapped child node_ids
          create_commit(new_uuid, update, parent_id: commit.id)
        else (leaf):
          new_uuid = mint
          uuid_map[source_uuid] = new_uuid
          create_commit(new_uuid, source_doc_update, parent_id: commit.id)
        return {new_uuid, uuid_map}

  Children are forked **before** the parent's schema commit is
  written, so the parent's remapped `entries` references can refer
  to UUIDs that already exist in the store.

  Within a single fork operation, every `create_commit` call is
  synchronous; by the time `fork_directory/2` returns, every new
  UUID is materialized in the store. There is no asynchronous
  build-out window.

  ## Time-travel fork (CX-65n)

  `fork_directory_at/3` is the same shape as `fork_directory/2`,
  but every node's reconstruction is anchored to a *target commit
  timestamp* rather than each node's HEAD:

    - The caller names a `target_commit_id` of the source root.
      That commit's `timestamp` becomes the **reference time**.
    - For each descendant doc visited during recursion,
      `commit_at_or_before/3` picks the latest commit on that
      doc's chain whose `timestamp <= reference_time`. The doc is
      reconstructed up to that commit, then forked.
    - The result: a snapshot-consistent fork representing what the
      source tree looked like at the reference time, even when
      sub-documents have completely independent commit timelines.

  The fallback (no commit precedes the reference time) takes the
  child's earliest commit. This shouldn't happen in well-ordered
  trees but defends against clock skew across replicas.

  ## Interactions with `Commonplace.Tree.Schema`

  Forking calls `Schema.remove_entry/2` and then
  `Schema.add_file/3` / `Schema.add_directory/3` to remap each
  child's `node_id` in the rebuilt schema doc. Two consequences
  worth pinning:

    - **Sync flag resets to `true`.** `Schema.add_file/3` and
      `Schema.add_directory/3` write entries with `sync: true`
      via `encode_entry/3`'s default. Source entries that were
      `:nosync` (deactivated branches per
      `Tree.Schema`'s "sync flag" section) come back active in
      the fork. This matches the typical use case ("fork to try
      a what-if; you want all of it to sync") but is a real
      semantic. If a caller wants to preserve `:nosync`, they
      need to call `Schema.deactivate/2` post-fork on the
      affected entries.
    - **Honorific extensions are *not* re-checked.**
      `Schema.forbid_honorific!/1` is the user-input guard;
      forking is a trusted internal copy of existing names, so
      it bypasses the check (same as `Commonplace.Presence.create/3`
      bypasses for the canonical write path). A `.usr` entry in
      the source tree comes back as a `.usr` entry in the fork.

  ## `__processes.json` filtering

  Source directories that contain a `__processes.json` doc get a
  defensive filter pass via
  `Commonplace.Process.Config.filter_json_for_fork/1`. The
  rationale: not every process registered in the source workspace
  should auto-launch in the fork (e.g. processes that own a port,
  or that are tagged as non-fork-safe). When the filter shrinks
  the json, the forked `__processes.json` doc is rewritten to
  contain only the fork-safe processes; otherwise the original
  content is preserved.

  This is the only place Fork knows about a specific filename.
  Every other doc is treated as opaque content.

  ## Dependencies, briefly

    - `Commonplace.Tree.Schema` — directory-doc primitive (just
      polished in cycle 1); the entries map is what gets remapped.
    - `Commonplace.Tree.DocBuilder` — `reconstruct_doc/2` and
      `reconstruct_doc_at/3` to read source state at HEAD or at a
      target commit.
    - `Commonplace.Store.CommitStoreClient` —
      `create_commit/4`, `latest_commit/2`, `commit_log/3`,
      `get_commit/2`. Every store interaction routes through this
      client so the fork works the same against a local CubDB and
      a remote serve node.
    - `Commonplace.Process.Config` — only for
      `filter_json_for_fork/1`; the one place fork knows about
      `__processes.json` semantics.
    - `Yelixer.Doc` and `Yelixer.Encoding` — for empty-doc
      construction in fallback paths and for encoding the rebuilt
      schema as a wire update.

  ## Invariants

    - **Source tree unchanged.** Fork only writes new commits to
      the new UUIDs; no commit is ever written to a source UUID.
    - **Every reachable source UUID maps to exactly one new
      UUID.** The `uuid_map` is a function in the recursion; if
      the same source UUID is reached twice (cross-references in
      a future shape), only the first call mints; subsequent
      lookups reuse the mapping. (Today's fork doesn't deduplicate
      mid-walk; the call shape just happens not to revisit.
      `Commonplace.Tree.Schema` directories can't share children
      by the schema model, so this isn't currently exercised.)
    - **Branch-point commit on every new doc.** Every new UUID's
      first commit has `parent_id` pointing at the source's
      commit. No new doc starts with `parent_id: nil`.
    - **Schema entries reference forked UUIDs only.** The rebuilt
      schema's `entries` never reference source UUIDs; every
      child id has been remapped.
    - **By return time, the new tree is fully materialized.**
      Synchronous writes throughout — no background build-out.

  ## What this module is NOT

  - **Not a merge** — see `Commonplace.Tree.Merge`. Fork creates
    the branch; Merge is the three-way reconciliation that runs
    later if the user wants to integrate fork edits back.
  - **Not a cherrypick** — see `Commonplace.Tree.Cherrypick`,
    which consumes the DAG branch a fork created.
  - **Not a sync trigger** — `create_commit/4` already broadcasts
    on its sync channels (`Commonplace.Dataflow.PubSub`); agents
    elsewhere pick up the new commits without any fork-specific
    notification.
  - **Not a manifest builder** — see "No ForkManifest" above.
  """

  alias Commonplace.Tree.{Schema, DocBuilder}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Process.Config
  alias Commonplace.Document.ContentType
  alias Yelixer.{Doc, Encoding}

  @doc """
  Forks a directory subtree at HEAD. Returns the new root UUID.

  Recurses depth-first from `source_uuid`, minting a fresh UUID
  for every reachable doc and writing one commit per new UUID
  with `parent_id` pointing at the corresponding source commit.
  By the time this function returns, every new doc is fully
  materialized in the store; the caller can read from the new
  root immediately.

  The internal `uuid_map` (source UUID → new UUID) is built up
  during recursion and discarded at the top level. Callers that
  need a manifest of the remap have to walk the resulting tree
  and reconstruct it from `parent_id`s — see "No ForkManifest"
  in the moduledoc.
  """
  def fork_directory(source_uuid, store \\ CommitStoreClient) do
    {new_uuid, _uuid_map} = fork_node(source_uuid, store, %{})
    new_uuid
  end

  @doc """
  Time-travel fork (CX-65n): reconstruct the tree at a specific
  historical commit of `source_uuid` and deep-copy with new UUIDs.

  `target_commit_id` identifies the root commit to fork from. That
  commit's timestamp defines the reference time; each descendant
  document is forked using its last commit with `timestamp <=
  reference_time`, giving a snapshot-consistent view across
  independently-chained sub-documents.

  Returns `{:ok, new_uuid}` or `{:error, reason}` when the target
  commit is not in the source's chain.
  """
  @spec fork_directory_at(String.t(), binary(), GenServer.server()) ::
          {:ok, String.t()} | {:error, term()}
  def fork_directory_at(source_uuid, target_commit_id, store \\ CommitStoreClient) do
    with {:ok, target_commit} <- fetch_target_commit(store, source_uuid, target_commit_id) do
      reference_time = target_commit.timestamp

      {new_uuid, _uuid_map} =
        fork_node_at(source_uuid, target_commit_id, reference_time, store, %{})

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

  defp fork_node_at(source_uuid, target_commit_id, reference_time, store, uuid_map) do
    case DocBuilder.reconstruct_doc_at(store, source_uuid, target_commit_id) do
      {:ok, source_doc} ->
        # source_doc might not decode as a schema cleanly for leaf nodes;
        # list_entries will return [] if not a schema, which is fine.
        entries = Schema.list_entries(source_doc)

        if length(entries) > 0 do
          fork_directory_node_at(source_uuid, source_doc, entries, reference_time, store, uuid_map, target_commit_id)
        else
          fork_leaf_node_at(source_uuid, source_doc, target_commit_id, store, uuid_map)
        end

      :none ->
        # Fallback: no historical state reachable — mint empty.
        new_uuid = UUID.uuid4()
        {new_uuid, Map.put(uuid_map, source_uuid, new_uuid)}
    end
  end

  defp fork_directory_node_at(source_uuid, source_doc, entries, reference_time, store, uuid_map, target_commit_id) do
    new_uuid = UUID.uuid4()
    uuid_map = Map.put(uuid_map, source_uuid, new_uuid)

    {uuid_map, _} =
      Enum.reduce(entries, {uuid_map, []}, fn entry, {map, _} ->
        child_target = commit_at_or_before(store, entry.node_id, reference_time)
        {_child_new_uuid, map} = fork_node_at(entry.node_id, child_target, reference_time, store, map)
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
    CommitStoreClient.create_commit(store, new_uuid, update, target_commit_id)

    {new_uuid, uuid_map}
  end

  defp fork_leaf_node_at(source_uuid, source_doc, target_commit_id, store, uuid_map) do
    new_uuid = UUID.uuid4()
    uuid_map = Map.put(uuid_map, source_uuid, new_uuid)

    update = Encoding.encode_update(source_doc)
    CommitStoreClient.create_commit(store, new_uuid, update, target_commit_id)

    {new_uuid, uuid_map}
  end

  # The snapshot-consistency primitive for `fork_directory_at/3`.
  # Given a child doc's UUID and the fork's reference time (the
  # timestamp of the root's target commit), returns the commit id of
  # the latest commit on the child's chain at-or-before that time —
  # so every descendant is reconstructed at the same logical
  # snapshot regardless of how its commits interleave with the
  # root's. Falls back to the child's earliest commit when no
  # commit precedes the reference time, defending against clock
  # skew across replicas.
  defp commit_at_or_before(store, uuid, reference_time) do
    chain = CommitStoreClient.commit_log(store, uuid, limit: 10_000)

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

  # The HEAD-anchored fork worker. Returns `{new_uuid, uuid_map}`
  # where the map carries `source_uuid => new_uuid` for every doc
  # the recursion has visited so far. The map flows through the
  # recursion so that when a parent's schema is rebuilt with
  # `add_file/3` / `add_directory/3`, the new child UUIDs are
  # already known.
  #
  # Decision tree:
  #
  #   - source has no commits → mint a fresh UUID with no commit
  #     (degenerate case, leaves a missing-source mapping in
  #     uuid_map for the caller to handle).
  #   - source's latest commit decodes as a schema with at least
  #     one entry → directory case; recurse into children.
  #   - source's latest commit fails to decode as a schema OR
  #     decodes empty → leaf case; copy content under new UUID.
  defp fork_node(source_uuid, store, uuid_map) do
    case CommitStoreClient.latest_commit(store, source_uuid) do
      {:ok, commit} ->
        schema_doc = Schema.new_schema()

        case Encoding.apply_update(schema_doc, commit.update) do
          {:ok, schema_doc} ->
            entries = Schema.list_entries(schema_doc)

            if length(entries) > 0 do
              fork_directory_node(source_uuid, entries, store, uuid_map, commit)
            else
              fork_leaf_node(source_uuid, store, uuid_map, commit)
            end

          _ ->
            fork_leaf_node(source_uuid, store, uuid_map, commit)
        end

      :none ->
        new_uuid = UUID.uuid4()
        {new_uuid, Map.put(uuid_map, source_uuid, new_uuid)}
    end
  end

  defp fork_directory_node(source_uuid, entries, store, uuid_map, commit) do
    new_uuid = UUID.uuid4()
    uuid_map = Map.put(uuid_map, source_uuid, new_uuid)

    # Fork all children first to build the uuid_map
    {uuid_map, _} =
      Enum.reduce(entries, {uuid_map, []}, fn entry, {map, _} ->
        {_child_uuid, map} = fork_node(entry.node_id, store, map)
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
        edited_doc = maybe_filter_processes(edited_doc, entries, store, uuid_map)

        # Create the schema edit commit branching off the source's chain
        update = Encoding.encode_update(edited_doc)
        CommitStoreClient.create_commit(store, new_uuid, update, commit.id)

      :none ->
        # Source doc missing — create empty schema commit as branch point
        update = Encoding.encode_update(Schema.new_schema())
        CommitStoreClient.create_commit(store, new_uuid, update, commit.id)
    end

    {new_uuid, uuid_map}
  end

  defp fork_leaf_node(source_uuid, store, uuid_map, commit) do
    new_uuid = UUID.uuid4()
    uuid_map = Map.put(uuid_map, source_uuid, new_uuid)

    # Branch-point commit: same content under new UUID, parent = source's commit
    case reconstruct_doc(store, source_uuid) do
      {:ok, doc} ->
        update = Encoding.encode_update(doc)
        CommitStoreClient.create_commit(store, new_uuid, update, commit.id)

      :none ->
        # Source doc missing — create minimal branch-point commit
        update = Encoding.encode_update(Doc.new())
        CommitStoreClient.create_commit(store, new_uuid, update, commit.id)
    end

    {new_uuid, uuid_map}
  end

  defp reconstruct_doc(store, doc_uuid) do
    DocBuilder.reconstruct_doc(store, doc_uuid)
  end

  defp maybe_filter_processes(schema_doc, entries, store, uuid_map) do
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
                    CommitStoreClient.create_commit(store, new_proc_uuid, update, branch_commit.parent_id)

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
