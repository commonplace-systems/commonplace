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
    case CommitStore.commit_log(store, doc_uuid) do
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
    case CommitStore.commit_log(store, doc_uuid) do
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
            man = ForkManifest.add_entry(man, new_uuid, source_node_id, source_commit.id)
            man = merge_sub_manifest(man, sub_manifest)
            {doc, man, %{rep | new_docs: [{source_node_id, new_uuid} | rep.new_docs]}}

          "doc" ->
            new_uuid = UUID.uuid4()
            {:ok, source_doc} = reconstruct_doc(store, source_node_id)
            update = Encoding.encode_update(source_doc)
            CommitStore.create_commit(store, new_uuid, update, nil)
            doc = Schema.add_file(doc, name, new_uuid)
            {:ok, source_commit} = CommitStore.latest_commit(store, source_node_id)
            man = ForkManifest.add_entry(man, new_uuid, source_node_id, source_commit.id)
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
  Advance fork_point_commit for each source UUID to its current latest commit.
  Called last for crash safety — manifest update is the merge "commit point".
  """
  def update_manifest_fork_points(store, manifest, source_uuids) do
    Enum.reduce(source_uuids, manifest, fn source_uuid, man ->
      case CommitStore.latest_commit(store, source_uuid) do
        {:ok, commit} ->
          case Map.get(man.document_map, source_uuid) do
            nil -> man
            entry ->
              updated_entry = %{entry | fork_point_commit: commit.id}
              %{man | document_map: Map.put(man.document_map, source_uuid, updated_entry)}
          end

        :none ->
          man
      end
    end)
  end

  # Check if a Yjs update is empty (no items, no deletes).
  # An empty V1 update encodes as: 0 (clients) + 0 (delete set clients) = 2 bytes.
  defp empty_update?(update) do
    byte_size(update) <= 2
  end
end
