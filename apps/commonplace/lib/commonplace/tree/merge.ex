defmodule Commonplace.Tree.Merge do
  @moduledoc """
  Merges changes from a source branch into a target branch using DAG ancestry.

  Finds common ancestors in the shared commit DAG, computes CRDT diffs for
  content docs, and structurally diffs schemas with recursive child pairing.
  No ForkManifest — provenance is in the DAG itself.
  """

  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{Schema, Fork}
  alias Commonplace.Document.ContentType
  alias Commonplace.Process.Config
  alias Yelixer.{Doc, Encoding, BlockStore}

  defmodule MergeReport do
    @moduledoc "Result of a merge operation."
    defstruct merged_docs: [], new_docs: [], deleted_docs: [], conflicts: [], errors: []
  end

  @doc """
  Merge changes from source branch into target branch.
  Returns {:ok, merge_report} or {:error, reason}.
  """
  def merge(source_uuid, target_uuid, store) do
    report = %MergeReport{}
    merge_tree(source_uuid, target_uuid, store, report)
  end

  # Recursively merge a tree node (directory or leaf)
  defp merge_tree(source_uuid, target_uuid, store, report) do
    case CommitStore.find_common_ancestor(store, source_uuid, target_uuid) do
      {:ok, ancestor} ->
        if is_schema?(store, source_uuid) do
          merge_directory(source_uuid, target_uuid, ancestor, store, report)
        else
          merge_leaf(source_uuid, target_uuid, ancestor, store, report)
        end

      :none ->
        # No common ancestor in DAG — chain may be broken (parent_id = nil edits).
        # Fall back to merge-point strategy for leaf docs if a prior merge was recorded.
        case CommitStore.get_merge_point(store, target_uuid, source_uuid) do
          nil ->
            {:ok, %{report | errors: [{:no_common_ancestor, source_uuid, target_uuid} | report.errors]}}

          merge_point_id ->
            if not is_schema?(store, source_uuid) do
              # Use merge point as baseline for leaf merge
              merge_leaf_from_merge_point(source_uuid, target_uuid, merge_point_id, store, report)
            else
              {:ok, %{report | errors: [{:no_common_ancestor, source_uuid, target_uuid} | report.errors]}}
            end
        end
    end
  end

  defp merge_leaf(source_uuid, target_uuid, ancestor, store, report) do
    # Use a stored merge point as the diff baseline if one exists (incremental merging),
    # otherwise fall back to the common ancestor.
    baseline_commit_id =
      case CommitStore.get_merge_point(store, target_uuid, source_uuid) do
        nil -> ancestor.id
        stored_id -> stored_id
      end

    case reconstruct_doc_at(store, source_uuid, baseline_commit_id) do
      {:ok, baseline_doc} ->
        baseline_sv = BlockStore.state_vector(baseline_doc.store)

        {:ok, source_doc} = reconstruct_doc(store, source_uuid)
        diff = Encoding.encode_diff(source_doc, baseline_sv)

        {:ok, source_latest} = CommitStore.latest_commit(store, source_uuid)

        if byte_size(diff) <= 2 do
          # No new changes since last merge — update the merge point to current source head
          CommitStore.set_merge_point(store, target_uuid, source_uuid, source_latest.id)
          {:ok, report}
        else
          {:ok, target_doc} = reconstruct_doc(store, target_uuid)
          {:ok, merged_doc} = Encoding.apply_update(target_doc, diff)

          merged_update = Encoding.encode_update(merged_doc)
          {:ok, latest} = CommitStore.latest_commit(store, target_uuid)
          merge_commit = CommitStore.create_commit(store, target_uuid, merged_update, latest.id)

          # Record merge metadata for incremental merging and delete-vs-modify detection
          CommitStore.set_merge_point(store, target_uuid, source_uuid, source_latest.id)
          CommitStore.set_last_merge_commit(store, target_uuid, source_uuid, merge_commit.id)

          {:ok, %{report | merged_docs: [{source_uuid, target_uuid} | report.merged_docs]}}
        end

      :none ->
        # Baseline commit not found in source chain — fall back to common ancestor
        case reconstruct_doc_at(store, source_uuid, ancestor.id) do
          {:ok, ancestor_doc} ->
            ancestor_sv = BlockStore.state_vector(ancestor_doc.store)

            {:ok, source_doc} = reconstruct_doc(store, source_uuid)
            diff = Encoding.encode_diff(source_doc, ancestor_sv)

            {:ok, source_latest} = CommitStore.latest_commit(store, source_uuid)

            if byte_size(diff) <= 2 do
              {:ok, report}
            else
              {:ok, target_doc} = reconstruct_doc(store, target_uuid)
              {:ok, merged_doc} = Encoding.apply_update(target_doc, diff)

              merged_update = Encoding.encode_update(merged_doc)
              {:ok, latest} = CommitStore.latest_commit(store, target_uuid)
              merge_commit = CommitStore.create_commit(store, target_uuid, merged_update, latest.id)

              CommitStore.set_merge_point(store, target_uuid, source_uuid, source_latest.id)
              CommitStore.set_last_merge_commit(store, target_uuid, source_uuid, merge_commit.id)

              {:ok, %{report | merged_docs: [{source_uuid, target_uuid} | report.merged_docs]}}
            end

          :none ->
            # Common ancestor commit not found in source chain — fall back to no-op
            {:ok, report}
        end
    end
  end

  # Merge a leaf doc using a stored merge point as baseline (for detached chains).
  defp merge_leaf_from_merge_point(source_uuid, target_uuid, merge_point_id, store, report) do
    case reconstruct_doc_at(store, source_uuid, merge_point_id) do
      {:ok, baseline_doc} ->
        baseline_sv = BlockStore.state_vector(baseline_doc.store)

        {:ok, source_doc} = reconstruct_doc(store, source_uuid)
        diff = Encoding.encode_diff(source_doc, baseline_sv)

        {:ok, source_latest} = CommitStore.latest_commit(store, source_uuid)

        if byte_size(diff) <= 2 do
          CommitStore.set_merge_point(store, target_uuid, source_uuid, source_latest.id)
          {:ok, report}
        else
          {:ok, target_doc} = reconstruct_doc(store, target_uuid)
          {:ok, merged_doc} = Encoding.apply_update(target_doc, diff)

          merged_update = Encoding.encode_update(merged_doc)
          {:ok, latest} = CommitStore.latest_commit(store, target_uuid)
          merge_commit = CommitStore.create_commit(store, target_uuid, merged_update, latest.id)

          CommitStore.set_merge_point(store, target_uuid, source_uuid, source_latest.id)
          CommitStore.set_last_merge_commit(store, target_uuid, source_uuid, merge_commit.id)

          {:ok, %{report | merged_docs: [{source_uuid, target_uuid} | report.merged_docs]}}
        end

      :none ->
        {:ok, %{report | errors: [{:no_common_ancestor, source_uuid, target_uuid} | report.errors]}}
    end
  end

  defp merge_directory(source_uuid, target_uuid, ancestor, store, report) do
    case reconstruct_doc_at(store, source_uuid, ancestor.id) do
      {:ok, ancestor_schema} ->
        # Use snapshot reconstruction for schema docs — fork always stores full snapshots,
        # so the latest commit is the complete current state. Full chain replay gives
        # inconsistent CRDT results when applying full snapshots on top of each other.
        {:ok, source_schema} = reconstruct_snapshot(store, source_uuid)
        {:ok, target_schema} = reconstruct_snapshot(store, target_uuid)

        ancestor_entries = Schema.entries(ancestor_schema)
        source_entries = Schema.entries(source_schema)
        target_entries = Schema.entries(target_schema)

        # Get merge-point entries if a prior merge has been recorded (for P1-2: detecting
        # source deletions that occurred after a prior merge round)
        merge_point_entries = get_merge_point_entries(store, target_uuid, source_uuid)

        all_names =
          MapSet.union(
            MapSet.new(Map.keys(source_entries)),
            MapSet.new(Map.keys(target_entries))
          )

        {updated_target_schema, report} =
          Enum.reduce(all_names, {target_schema, report}, fn name, {schema, rep} ->
            source_entry = Map.get(source_entries, name)
            target_entry = Map.get(target_entries, name)
            ancestor_entry = Map.get(ancestor_entries, name)

            cond do
              source_entry != nil and target_entry != nil ->
                source_nid = source_entry["node_id"]
                target_nid = target_entry["node_id"]

                case CommitStore.find_common_ancestor(store, source_nid, target_nid) do
                  {:ok, _} ->
                    {:ok, rep} = merge_tree(source_nid, target_nid, store, rep)
                    {schema, rep}

                  :none ->
                    conflict = {:name_collision, name, source_nid, target_nid}
                    {schema, %{rep | conflicts: [conflict | rep.conflicts]}}
                end

              source_entry != nil and target_entry == nil and ancestor_entry == nil ->
                # Added on source, not present on target at common ancestor → add to target
                source_nid = source_entry["node_id"]
                type = source_entry["type"]

                new_uuid = fork_into_target(source_nid, type, store)

                schema =
                  case type do
                    "dir" -> Schema.add_directory(schema, name, new_uuid)
                    _ -> Schema.add_file(schema, name, new_uuid)
                  end

                {schema, %{rep | new_docs: [{source_nid, new_uuid} | rep.new_docs]}}

              source_entry == nil and target_entry != nil and ancestor_entry == nil ->
                # Only in target, not in source, not in ancestor.
                # Check merge-point schema: if it was present there, source deleted it after a prior merge.
                mp_entry = if merge_point_entries, do: Map.get(merge_point_entries, name)

                if mp_entry != nil do
                  # Was in merge-point schema, now gone from source → source deleted after prior merge.
                  # But check: did target independently modify this entry since the merge?
                  target_nid = target_entry["node_id"]
                  mp_nid = mp_entry["node_id"]

                  if modified_since_merge_point?(store, target_nid, mp_nid) do
                    conflict = {:delete_vs_modify, name, target_nid}
                    {schema, %{rep | conflicts: [conflict | rep.conflicts]}}
                  else
                    schema = Schema.remove_entry(schema, name)
                    {schema, %{rep | deleted_docs: [target_nid | rep.deleted_docs]}}
                  end
                else
                  # Truly a target-only addition, keep
                  {schema, rep}
                end

              source_entry == nil and target_entry != nil and ancestor_entry != nil ->
                # Removed on source, still present on target
                target_nid = target_entry["node_id"]
                ancestor_nid = ancestor_entry["node_id"]

                if not modified_since_ancestor?(store, target_nid, ancestor_nid, ancestor) do
                  schema = Schema.remove_entry(schema, name)
                  {schema, %{rep | deleted_docs: [target_nid | rep.deleted_docs]}}
                else
                  conflict = {:delete_vs_modify, name, target_nid}
                  {schema, %{rep | conflicts: [conflict | rep.conflicts]}}
                end

              source_entry != nil and target_entry == nil and ancestor_entry != nil ->
                # Was in ancestor, removed from target, still in source → target removed it, keep removed
                {schema, rep}

              true ->
                {schema, rep}
            end
          end)

        schema_update = Encoding.encode_update(updated_target_schema)
        {:ok, target_latest} = CommitStore.latest_commit(store, target_uuid)
        CommitStore.create_commit(store, target_uuid, schema_update, target_latest.id)

        # Record source's current head as the merge point for the next merge round
        {:ok, source_latest} = CommitStore.latest_commit(store, source_uuid)
        CommitStore.set_merge_point(store, target_uuid, source_uuid, source_latest.id)

        maybe_filter_processes(store, target_uuid)

        {:ok, report}

      :none ->
        # Common ancestor commit not found in source chain — skip directory merge
        {:ok, report}
    end
  end

  defp fork_into_target(source_uuid, _type, store) do
    Fork.fork_directory(source_uuid, store)
  end

  # Returns the schema entries map at the stored merge point for (target, source), or nil
  # if no merge point has been recorded yet.
  defp get_merge_point_entries(store, target_uuid, source_uuid) do
    case CommitStore.get_merge_point(store, target_uuid, source_uuid) do
      nil ->
        nil

      commit_id ->
        case reconstruct_doc_at(store, source_uuid, commit_id) do
          {:ok, doc} -> Schema.entries(doc)
          :none -> nil
        end
    end
  end

  defp modified_since_ancestor?(store, target_nid, ancestor_nid, _root_ancestor) do
    if target_nid == ancestor_nid do
      # Target kept the original UUID after fork. Check if user made independent edits.
      # We walk the commit chain and compare its length to what it had at the ancestor time.
      # Fork does NOT create commits on target_nid (only on new UUIDs).
      # Merges DO create commits on target_nid.
      # Use last_merge_commit (keyed by target+source) to check if the latest commit
      # is from a merge or from a user edit.
      {:ok, latest} = CommitStore.latest_commit(store, target_nid)
      log = CommitStore.commit_log(store, target_nid)

      cond do
        # Single commit = original creation, never modified
        length(log) <= 1 -> false
        # Check if latest commit came from a merge (search all merge commit markers)
        # Since we can't enumerate all source UUIDs, check if the latest commit's id
        # matches any recorded merge commit. Use a conservative heuristic:
        # if the doc had only 1 commit at creation and now has more,
        # check if the most recent commits were from merges.
        true ->
          # Conservative: flag as potentially modified if chain has grown.
          # The merge_leaf records last_merge_commit per (target, source) pair.
          # Since we don't know the source here, we can't look it up.
          # Default to "modified" which is safe (may cause false conflicts but no data loss).
          true
      end
    else
      # Different UUIDs — use DAG ancestry
      case CommitStore.find_common_ancestor(store, target_nid, ancestor_nid) do
        {:ok, ancestor} ->
          {:ok, latest} = CommitStore.latest_commit(store, target_nid)
          latest.id != ancestor.id

        :none ->
          true
      end
    end
  end

  # Check if a target doc was independently modified since a merge point.
  # Used when source deletes an entry that was merged in a prior round.
  # mp_nid is from the merge-point SOURCE schema. target_nid was created by
  # fork_into_target(mp_nid, ...) during the prior merge, so they share DAG ancestry.
  defp modified_since_merge_point?(store, target_nid, mp_nid) do
    case CommitStore.find_common_ancestor(store, target_nid, mp_nid) do
      {:ok, ancestor} ->
        {:ok, latest} = CommitStore.latest_commit(store, target_nid)
        latest.id != ancestor.id

      :none ->
        # No shared history — conservative: assume modified
        true
    end
  end

  defp is_schema?(store, uuid) do
    # Use snapshot reconstruction to avoid multi-commit CRDT inconsistency
    case reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> Schema.version(doc) != nil
      _ -> false
    end
  end

  # Reconstruct a doc by replaying its full commit chain (oldest → newest).
  # Use for content docs where edits are stored incrementally.
  defp reconstruct_doc(store, uuid) do
    commits = CommitStore.commit_log(store, uuid, limit: 10_000) |> Enum.reverse()

    case commits do
      [] ->
        :none

      _ ->
        doc = Doc.new()
        Enum.reduce(commits, {:ok, doc}, fn c, {:ok, d} -> Encoding.apply_update(d, c.update) end)
    end
  end

  # Reconstruct a doc by applying only the latest commit to a fresh doc.
  # Use for schema docs where fork always stores full snapshots.
  # This avoids CRDT inconsistency from applying full snapshots on top of each other.
  defp reconstruct_snapshot(store, uuid) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Doc.new()
        Encoding.apply_update(doc, commit.update)

      :none ->
        :none
    end
  end

  defp reconstruct_doc_at(store, uuid, target_commit_id) do
    commits = CommitStore.commit_log(store, uuid, limit: 10_000) |> Enum.reverse()

    result =
      Enum.reduce_while(commits, {:not_found, []}, fn commit, {_status, acc} ->
        if commit.id == target_commit_id do
          {:halt, {:found, Enum.reverse([commit | acc])}}
        else
          {:cont, {:not_found, [commit | acc]}}
        end
      end)

    case result do
      {:found, to_apply} ->
        doc = Doc.new()
        Enum.reduce(to_apply, {:ok, doc}, fn c, {:ok, d} -> Encoding.apply_update(d, c.update) end)

      {:not_found, _} ->
        :none
    end
  end

  defp maybe_filter_processes(store, schema_uuid) do
    {:ok, schema} = reconstruct_snapshot(store, schema_uuid)

    case Schema.get_entry(schema, "__processes.json") do
      {:ok, entry} ->
        case reconstruct_doc(store, entry.node_id) do
          {:ok, proc_doc} ->
            content = ContentType.get_content(proc_doc) || "{}"

            case Jason.decode(content) do
              {:ok, proc_json} ->
                filtered = Config.filter_json_for_fork(proc_json)

                if filtered != proc_json do
                  new_doc = Doc.new()
                  new_doc = ContentType.create(new_doc, :text, "__processes.json")
                  new_doc = ContentType.insert_text(new_doc, 0, Jason.encode!(filtered))
                  update = Encoding.encode_update(new_doc)
                  {:ok, latest} = CommitStore.latest_commit(store, entry.node_id)
                  CommitStore.create_commit(store, entry.node_id, update, latest.id)
                end

              _ -> :ok
            end

          _ -> :ok
        end

      :error -> :ok
    end
  end
end
