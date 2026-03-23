defmodule Commonplace.Tree.Merge do
  @moduledoc """
  Merges changes from a source branch into a target branch.

  Uses ForkManifest provenance to compute CRDT diffs for content docs
  and structural diffs for schema docs. See docs/plans/2026-03-23-branch-merge-design.md.
  """

  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{ForkManifest, Schema, Fork}
  alias Commonplace.Document.ContentType
  alias Commonplace.Process.Config
  alias Yelixer.{Doc, Encoding, BlockStore}

  defmodule MergeReport do
    @moduledoc "Result of a merge operation."
    defstruct merged_docs: [],
              new_docs: [],
              deleted_docs: [],
              conflicts: [],
              errors: []

    @type conflict ::
            {:delete_vs_modify, String.t(), String.t()}
            | {:name_collision, String.t(), String.t(), String.t()}

    @type t :: %__MODULE__{
            merged_docs: [{String.t(), String.t()}],
            new_docs: [{String.t(), String.t()}],
            deleted_docs: [String.t()],
            conflicts: [conflict()],
            errors: [term()]
          }
  end

  defmodule SchemaDiff do
    @moduledoc false
    defstruct added: %{}, removed: %{}, renamed: []
  end

  @doc """
  Reconstruct a Yelixer Doc by replaying all commits for the given UUID.
  commit_log/2 returns newest-first; we reverse to apply oldest-first.
  Returns {:ok, doc} or :none if no commits exist.
  """
  def reconstruct_doc(store, doc_uuid) do
    case CommitStore.commit_log(store, doc_uuid, limit: 10_000) do
      [] ->
        :none

      commits ->
        doc = Doc.new()
        oldest_first = Enum.reverse(commits)

        Enum.reduce_while(oldest_first, {:ok, doc}, fn commit, {:ok, acc} ->
          case Encoding.apply_update(acc, commit.update) do
            {:ok, updated} -> {:cont, {:ok, updated}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  @doc """
  Reconstruct a Doc up to (and including) a specific commit.
  commit_log/2 returns newest-first; we reverse to get oldest-first,
  then apply commits until we reach target_commit_id.
  """
  def reconstruct_doc_at(store, doc_uuid, target_commit_id) do
    case CommitStore.commit_log(store, doc_uuid, limit: 10_000) do
      [] ->
        :none

      commits ->
        oldest_first = Enum.reverse(commits)

        commits_to_apply =
          Enum.reduce_while(oldest_first, [], fn commit, acc ->
            if commit.id == target_commit_id do
              {:halt, Enum.reverse([commit | acc])}
            else
              {:cont, [commit | acc]}
            end
          end)

        if commits_to_apply == [] do
          :none
        else
          doc = Doc.new()

          Enum.reduce_while(commits_to_apply, {:ok, doc}, fn commit, {:ok, acc} ->
            case Encoding.apply_update(acc, commit.update) do
              {:ok, updated} -> {:cont, {:ok, updated}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
        end
    end
  end

  @doc """
  Merge a single content doc from source into target using CRDT diff.

  The fork_point_commit_id belongs to the TARGET doc's commit chain —
  it's the target's state when the fork was created.

  Returns {:ok, commit}, :noop, or {:error, reason}.
  """
  def merge_content_doc(store, source_uuid, target_uuid, fork_point_commit_id) do
    # 1. Reconstruct fork-point state from the TARGET doc
    #    (fork_point_commit is on the target's chain, not source's)
    with {:ok, fork_point_doc} <- reconstruct_doc_at(store, target_uuid, fork_point_commit_id),
         {:ok, source_doc} <- reconstruct_doc(store, source_uuid) do
      fork_point_sv = BlockStore.state_vector(fork_point_doc.store)

      # 2. Compute diff: what changed on source since fork-point
      diff = Encoding.encode_diff(source_doc, fork_point_sv)

      # 3. Check if diff has any actual content
      if empty_update?(diff) do
        :noop
      else
        # 4. Apply diff to target
        {:ok, target_doc} = reconstruct_doc(store, target_uuid)
        {:ok, merged_doc} = Encoding.apply_update(target_doc, diff)

        # 5. Commit merged state
        merged_update = Encoding.encode_update(merged_doc)
        {:ok, latest} = CommitStore.latest_commit(store, target_uuid)
        commit = CommitStore.create_commit(store, target_uuid, merged_update, latest.id)
        {:ok, commit}
      end
    end
  end

  @doc """
  Merge changes from source branch into target branch.

  Returns {:ok, updated_manifest, merge_report} or {:error, reason}.
  """
  def merge(source_uuid, target_uuid, %ForkManifest{} = manifest, store) do
    report = %MergeReport{}

    # Step 1: Merge content for leaf documents only.
    # Skip root schema AND all directory schema docs — those are handled
    # via structural diff, not raw CRDT merge (node_ids are branch-specific).
    dir_uuids = collect_directory_uuids(store, source_uuid)

    content_entries =
      Enum.reject(manifest.document_map, fn {source_doc_uuid, _entry} ->
        source_doc_uuid == source_uuid or MapSet.member?(dir_uuids, source_doc_uuid)
      end)

    report =
      Enum.reduce(content_entries, report, fn {source_doc_uuid, entry}, rep ->
        target_doc_uuid = entry.original_uuid
        fork_point = entry.fork_point_commit

        case merge_content_doc(store, source_doc_uuid, target_doc_uuid, fork_point) do
          {:ok, _commit} ->
            %{rep | merged_docs: [{source_doc_uuid, target_doc_uuid} | rep.merged_docs]}

          :noop ->
            rep

          {:error, reason} ->
            %{rep | errors: [{:content_merge_failed, source_doc_uuid, reason} | rep.errors]}
        end
      end)

    # Step 2: Schema diff + application (only if root is in manifest)
    case Map.get(manifest.document_map, source_uuid) do
      %{fork_point_commit: root_fork_point} ->
        # Load the schema states we need
        {:ok, cur_source_schema} = reconstruct_doc(store, source_uuid)
        {:ok, cur_target_schema} = reconstruct_doc(store, target_uuid)

        # For the schema diff, we need the source's initial state (at fork time).
        # The source's oldest commit IS the fork-point state (with forked node_ids).
        source_commits = CommitStore.commit_log(store, source_uuid)
        source_first_commit = List.last(source_commits)
        {:ok, source_fork_point_schema} = reconstruct_doc_at(store, source_uuid, source_first_commit.id)

        # For collision detection, we need the target's state at fork time
        {:ok, target_fork_point_schema} = reconstruct_doc_at(store, target_uuid, root_fork_point)

        source_fp_entries = Schema.entries(source_fork_point_schema)
        cur_source_entries = Schema.entries(cur_source_schema)
        cur_target_entries = Schema.entries(cur_target_schema)

        # Fork-point target entries for collision detection
        fp_target_entries = Schema.entries(target_fork_point_schema)

        # Step 3: Diff source schemas (fork-point vs current source = what changed on source)
        diff = diff_schemas(source_fp_entries, cur_source_entries)

        # Step 4: Apply schema changes to target
        {updated_target_schema, manifest, report} =
          apply_schema_changes(
            store, cur_target_schema, diff, manifest, cur_target_entries, report,
            fork_point_target_entries: fp_target_entries
          )

        # Step 5: Filter __processes.json if it was added/merged
        updated_target_schema = maybe_filter_processes(store, updated_target_schema)

        # Commit updated target schema
        {:ok, target_latest} = CommitStore.latest_commit(store, target_uuid)
        schema_update = Encoding.encode_update(updated_target_schema)
        CommitStore.create_commit(store, target_uuid, schema_update, target_latest.id)

        # Step 6: Update manifest fork points (last — crash safety)
        all_source_uuids = Map.keys(manifest.document_map)
        manifest = update_manifest_fork_points(store, manifest, all_source_uuids)

        {:ok, manifest, report}

      nil ->
        # Source root not in manifest — content-only merge
        manifest = update_manifest_fork_points(store, manifest, Map.keys(manifest.document_map))
        {:ok, manifest, report}
    end
  end

  @doc """
  Diff two schema entry maps (fork-point vs current source).
  Both args are `%{name => %{"type" => ..., "node_id" => ...}}` from Schema.entries/1.
  Returns %SchemaDiff{added, removed, renamed}.

  Renames detected by node_id: same node_id under different name = rename (not add+remove).
  """
  def diff_schemas(fork_point_entries, current_entries) do
    fp_names = Map.keys(fork_point_entries) |> MapSet.new()
    cur_names = Map.keys(current_entries) |> MapSet.new()

    # Build node_id -> name indexes for rename detection
    fp_by_node = Map.new(fork_point_entries, fn {name, e} -> {e["node_id"], name} end)
    cur_by_node = Map.new(current_entries, fn {name, e} -> {e["node_id"], name} end)

    # Renames: same node_id, different name
    renames =
      for {node_id, fp_name} <- fp_by_node,
          cur_name = Map.get(cur_by_node, node_id),
          cur_name != nil,
          cur_name != fp_name do
        {fp_name, cur_name, node_id}
      end

    renamed_fp_names = MapSet.new(renames, fn {old, _, _} -> old end)
    renamed_cur_names = MapSet.new(renames, fn {_, new, _} -> new end)

    # Added: in current but not in fork-point, excluding renames
    added_names = MapSet.difference(cur_names, fp_names) |> MapSet.difference(renamed_cur_names)
    added = Map.take(current_entries, MapSet.to_list(added_names))

    # Removed: in fork-point but not in current, excluding renames
    removed_names = MapSet.difference(fp_names, cur_names) |> MapSet.difference(renamed_fp_names)
    removed = Map.take(fork_point_entries, MapSet.to_list(removed_names))

    %SchemaDiff{added: added, removed: removed, renamed: renames}
  end

  @doc """
  Apply schema diff to the target schema doc.

  Options:
  - fork_point_target_entries: target schema at fork-point (for collision detection)

  Returns {updated_doc, updated_manifest, updated_report}.
  """
  def apply_schema_changes(store, target_doc, %SchemaDiff{} = diff, manifest, target_entries, report, opts \\ []) do
    fp_target_entries = Keyword.get(opts, :fork_point_target_entries, target_entries)

    {target_doc, manifest, report} =
      apply_additions(store, target_doc, diff.added, manifest, target_entries, fp_target_entries, report)

    {target_doc, report} =
      apply_removals(store, target_doc, diff.removed, manifest, report)

    {target_doc, report} =
      apply_renames(target_doc, diff.renamed, manifest, target_entries, report)

    {target_doc, manifest, report}
  end

  defp apply_additions(store, target_doc, added, manifest, target_entries, fp_target_entries, report) do
    target_adds_since_fork =
      Map.keys(target_entries)
      |> Enum.reject(fn name -> Map.has_key?(fp_target_entries, name) end)
      |> MapSet.new()

    Enum.reduce(added, {target_doc, manifest, report}, fn {name, entry_map}, {doc, man, rep} ->
      source_node_id = entry_map["node_id"]
      type = entry_map["type"]

      if MapSet.member?(target_adds_since_fork, name) do
        {:ok, existing} = Schema.get_entry(doc, name)
        conflict = {:name_collision, name, source_node_id, existing.node_id}
        {doc, man, %{rep | conflicts: [conflict | rep.conflicts]}}
      else
        case type do
          "dir" ->
            {new_uuid, sub_manifest} = Fork.fork_directory(source_node_id, store)
            doc = Schema.add_directory(doc, name, new_uuid)
            {:ok, source_commit} = CommitStore.latest_commit(store, source_node_id)
            # Key by source UUID so future merges can look up source→target
            man = ForkManifest.add_entry(man, source_node_id, new_uuid, source_commit.id)
            man = merge_sub_manifest(man, sub_manifest)
            {doc, man, %{rep | new_docs: [{source_node_id, new_uuid} | rep.new_docs]}}

          "doc" ->
            new_uuid = UUID.uuid4()
            {:ok, source_doc} = reconstruct_doc(store, source_node_id)
            update = Encoding.encode_update(source_doc)
            CommitStore.create_commit(store, new_uuid, update, nil)
            doc = Schema.add_file(doc, name, new_uuid)
            {:ok, source_commit} = CommitStore.latest_commit(store, source_node_id)
            # Key by source UUID so future merges can look up source→target
            man = ForkManifest.add_entry(man, source_node_id, new_uuid, source_commit.id)
            {doc, man, %{rep | new_docs: [{source_node_id, new_uuid} | rep.new_docs]}}
        end
      end
    end)
  end

  defp apply_removals(store, target_doc, removed, manifest, report) do
    Enum.reduce(removed, {target_doc, report}, fn {name, entry_map}, {doc, rep} ->
      source_node_id = entry_map["node_id"]

      case Map.get(manifest.document_map, source_node_id) do
        %{original_uuid: target_uuid, fork_point_commit: fork_point_commit} ->
          if target_modified_since?(store, target_uuid, fork_point_commit) do
            conflict = {:delete_vs_modify, name, target_uuid}
            {doc, %{rep | conflicts: [conflict | rep.conflicts]}}
          else
            doc = Schema.remove_entry(doc, name)
            {doc, %{rep | deleted_docs: [target_uuid | rep.deleted_docs]}}
          end

        nil ->
          {doc, rep}
      end
    end)
  end

  defp apply_renames(target_doc, renames, manifest, target_entries, report) do
    Enum.reduce(renames, {target_doc, report}, fn {old_name, new_name, source_node_id}, {doc, rep} ->
      # Check for rename collision: target independently has an entry at new_name
      if Map.has_key?(target_entries, new_name) and old_name != new_name do
        {:ok, existing} = Schema.get_entry(doc, new_name)
        conflict = {:name_collision, new_name, source_node_id, existing.node_id}
        {doc, %{rep | conflicts: [conflict | rep.conflicts]}}
      else
        case Map.get(manifest.document_map, source_node_id) do
          %{original_uuid: target_uuid} ->
            type = get_entry_type(target_entries, old_name)
            doc = Schema.remove_entry(doc, old_name)

            doc =
              case type do
                :dir -> Schema.add_directory(doc, new_name, target_uuid)
                _ -> Schema.add_file(doc, new_name, target_uuid)
              end

            {doc, rep}

          nil ->
            case Map.get(target_entries, old_name) do
              %{"node_id" => node_id, "type" => type_str} ->
                doc = Schema.remove_entry(doc, old_name)

                doc =
                  case type_str do
                    "dir" -> Schema.add_directory(doc, new_name, node_id)
                    _ -> Schema.add_file(doc, new_name, node_id)
                  end

                {doc, rep}

              nil ->
                {doc, rep}
            end
        end
      end
    end)
  end

  defp get_entry_type(entries, name) do
    case Map.get(entries, name) do
      %{"type" => "dir"} -> :dir
      _ -> :doc
    end
  end

  defp merge_sub_manifest(parent, sub_manifest) do
    merged_map = Map.merge(parent.document_map, sub_manifest.document_map)
    %{parent | document_map: merged_map}
  end

  defp target_modified_since?(store, target_uuid, fork_point_commit_id) do
    case CommitStore.latest_commit(store, target_uuid) do
      {:ok, latest} -> latest.id != fork_point_commit_id
      :none -> false
    end
  end

  @doc """
  Filter __processes.json entries using Config.fork_behavior/1.
  Delegates to Config.filter_json_for_fork/1 — same rules as fork.
  """
  def filter_processes_for_merge(proc_json) do
    Config.filter_json_for_fork(proc_json)
  end

  @doc """
  Advance fork_point_commit to the TARGET doc's current latest commit.
  merge_content_doc/4 reconstructs fork-point from the target chain,
  so fork_point_commit must be a commit on that chain.
  Called last for crash safety — manifest update is the merge "commit point".
  """
  def update_manifest_fork_points(store, manifest, source_uuids) do
    Enum.reduce(source_uuids, manifest, fn source_uuid, man ->
      case Map.get(man.document_map, source_uuid) do
        nil ->
          man

        entry ->
          # Use the TARGET doc's latest commit (entry.original_uuid is the target)
          case CommitStore.latest_commit(store, entry.original_uuid) do
            {:ok, commit} ->
              updated_entry = %{entry | fork_point_commit: commit.id}
              %{man | document_map: Map.put(man.document_map, source_uuid, updated_entry)}

            :none ->
              man
          end
      end
    end)
  end

  # If the schema has a __processes.json entry, filter its content
  defp maybe_filter_processes(store, schema_doc) do
    case Schema.get_entry(schema_doc, "__processes.json") do
      {:ok, entry} ->
        case reconstruct_doc(store, entry.node_id) do
          {:ok, proc_doc} ->
            content = ContentType.get_content(proc_doc) || "{}"

            case Jason.decode(content) do
              {:ok, proc_json} ->
                filtered = filter_processes_for_merge(proc_json)

                if filtered != proc_json do
                  new_doc = Doc.new()
                  new_doc = ContentType.create(new_doc, :text, "__processes.json")
                  new_doc = ContentType.insert_text(new_doc, 0, Jason.encode!(filtered))
                  update = Encoding.encode_update(new_doc)
                  {:ok, latest} = CommitStore.latest_commit(store, entry.node_id)
                  CommitStore.create_commit(store, entry.node_id, update, latest.id)
                end

                schema_doc

              _ ->
                schema_doc
            end

          _ ->
            schema_doc
        end

      :error ->
        schema_doc
    end
  end

  # Collect all directory UUIDs from a schema doc (recursively).
  # These should be excluded from content merge since they need structural diff.
  defp collect_directory_uuids(store, schema_uuid) do
    case reconstruct_doc(store, schema_uuid) do
      {:ok, schema_doc} ->
        entries = Schema.entries(schema_doc)

        entries
        |> Enum.filter(fn {_name, e} -> e["type"] == "dir" end)
        |> Enum.reduce(MapSet.new(), fn {_name, e}, acc ->
          dir_uuid = e["node_id"]
          acc = MapSet.put(acc, dir_uuid)
          # Recurse into subdirectories
          MapSet.union(acc, collect_directory_uuids(store, dir_uuid))
        end)

      _ ->
        MapSet.new()
    end
  end

  # Check if a Yjs update is empty (no items, no deletes).
  # An empty V1 update encodes as: 0 (clients) + 0 (delete set clients) = 2 bytes.
  defp empty_update?(update) do
    byte_size(update) <= 2
  end
end
