defmodule Commonplace.Tree.Merge do
  @moduledoc """
  Merges changes from a source branch into a target branch using DAG ancestry.

  Finds common ancestors in the shared commit DAG, computes CRDT diffs for
  content docs, and structurally diffs schemas with recursive child pairing.
  No ForkManifest — provenance is in the DAG itself.
  """

  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{Schema, Fork, DocBuilder}
  alias Commonplace.Document.ContentType
  alias Commonplace.Process.Config
  alias Yelixer.{Doc, Encoding, BlockStore}

  defmodule MergeReport do
    @moduledoc "Result of a merge operation."
    defstruct merged_docs: [], new_docs: [], deleted_docs: [], conflicts: [], errors: [],
              auto_renamed: []
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
                    # No shared DAG ancestry between source and target node_ids.
                    # Check if this is a node_id replacement: source deleted the old
                    # entry and recreated it with a new node_id under the same name.
                    # If the ancestor had this name with the same node_id as target,
                    # source replaced it — treat as delete old + add new (CX-5gr).
                    ancestor_nid = if ancestor_entry, do: ancestor_entry["node_id"]

                    if ancestor_nid != nil and ancestor_nid == target_nid do
                      # Source replaced the entry. Check if target modified the old doc
                      # since the ancestor — if so, it's a delete-vs-modify conflict.
                      if modified_since_ancestor?(store, target_nid, ancestor_nid, ancestor) do
                        conflict = {:delete_vs_modify, name, target_nid}
                        {schema, %{rep | conflicts: [conflict | rep.conflicts]}}
                      else
                        # Safe replacement: remove old entry, fork new source doc into target
                        source_type = source_entry["type"]
                        new_uuid = fork_into_target(source_nid, source_type, store)

                        schema = Schema.remove_entry(schema, name)

                        schema =
                          case source_type do
                            "dir" -> Schema.add_directory(schema, name, new_uuid)
                            _ -> Schema.add_file(schema, name, new_uuid)
                          end

                        rep = %{
                          rep
                          | deleted_docs: [target_nid | rep.deleted_docs],
                            new_docs: [{source_nid, new_uuid} | rep.new_docs]
                        }

                        {schema, rep}
                      end
                    else
                      # True collision: both branches independently added an entry with the
                      # same name. Auto-rename the incoming (source) entry to avoid collision.
                      type = source_entry["type"]
                      renamed = unique_rename(name, schema)
                      new_uuid = fork_into_target(source_nid, type, store)

                      schema =
                        case type do
                          "dir" -> Schema.add_directory(schema, renamed, new_uuid)
                          _ -> Schema.add_file(schema, renamed, new_uuid)
                        end

                      rename_entry = {:auto_renamed, name, renamed, source_nid, new_uuid}

                      rep = %{
                        rep
                        | auto_renamed: [rename_entry | rep.auto_renamed],
                          new_docs: [{source_nid, new_uuid} | rep.new_docs]
                      }

                      {schema, rep}
                    end
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
                  # Verify lineage: target entry must share DAG ancestry with merge-point entry.
                  # If target independently created a same-named doc, don't delete it.
                  target_nid = target_entry["node_id"]
                  mp_nid = mp_entry["node_id"]

                  has_lineage =
                    case CommitStore.find_common_ancestor(store, target_nid, mp_nid) do
                      {:ok, _} -> true
                      :none -> false
                    end

                  cond do
                    not has_lineage ->
                      # No shared history — target created this independently, keep it
                      {schema, rep}
                    modified_since_merge_point?(store, target_nid, mp_nid) ->
                      conflict = {:delete_vs_modify, name, target_nid}
                      {schema, %{rep | conflicts: [conflict | rep.conflicts]}}
                    true ->
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

  # Generate a unique renamed name for a collision: "name.merge-conflict",
  # then "name.merge-conflict-2", "name.merge-conflict-3", etc.
  defp unique_rename(name, schema) do
    candidate = name <> ".merge-conflict"
    existing = Schema.entries(schema)

    if not Map.has_key?(existing, candidate) do
      candidate
    else
      find_unique_rename(name, existing, 2)
    end
  end

  defp find_unique_rename(name, existing, n) do
    candidate = name <> ".merge-conflict-#{n}"

    if not Map.has_key?(existing, candidate) do
      candidate
    else
      find_unique_rename(name, existing, n + 1)
    end
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

  # Check if a target doc was independently modified (by the user, not just by merges).
  # Uses the latest_merge_head tracker: if target's current head matches the last
  # merge-created commit, only merges happened — no user edits.
  defp modified_since_ancestor?(store, target_nid, ancestor_nid, root_ancestor) do
    if target_nid == ancestor_nid do
      target_modified_by_user?(store, target_nid, root_ancestor)
    else
      case CommitStore.find_common_ancestor(store, target_nid, ancestor_nid) do
        {:ok, ancestor} ->
          {:ok, latest} = CommitStore.latest_commit(store, target_nid)
          if latest.id == ancestor.id do
            false
          else
            # Chain has diverged — but was it a merge or user edit?
            target_modified_by_user?(store, target_nid, root_ancestor)
          end

        :none ->
          true
      end
    end
  end

  # Check if a target doc was independently modified since a merge point.
  # Used when source deletes an entry that was merged in a prior round.
  defp modified_since_merge_point?(store, target_nid, _mp_nid) do
    target_modified_by_user?(store, target_nid, nil)
  end

  # Core check: was this target doc modified by the user (not just by merges/forks)?
  # root_ancestor is the fork-point commit (used as timestamp baseline for first-merge case).
  defp target_modified_by_user?(store, target_uuid, root_ancestor) do
    {:ok, latest} = CommitStore.latest_commit(store, target_uuid)

    case CommitStore.get_latest_merge_head(store, target_uuid) do
      nil ->
        # No merges ever happened to this doc. Use the root ancestor timestamp
        # to check for post-fork edits. If the target's latest commit is newer
        # than the fork point, it was edited after the fork.
        if root_ancestor do
          DateTime.compare(latest.timestamp, root_ancestor.timestamp) == :gt
        else
          # No root ancestor available (merge-point path) — default to not modified.
          # Branch-point docs have 1 commit; if this doc has user edits after fork_into_target
          # created it, the merge head would have been set. Without it, assume no user edits.
          false
        end

      merge_head_id ->
        # Merge has happened. If target's latest is the merge commit → no user edits.
        latest.id != merge_head_id
    end
  end

  defp is_schema?(store, uuid) do
    # Use snapshot reconstruction to avoid multi-commit CRDT inconsistency
    case reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> Schema.version(doc) != nil
      _ -> false
    end
  end

  defp reconstruct_doc(store, uuid), do: DocBuilder.reconstruct_doc(store, uuid)

  defp reconstruct_snapshot(store, uuid), do: DocBuilder.reconstruct_snapshot(store, uuid)

  defp reconstruct_doc_at(store, uuid, target_commit_id),
    do: DocBuilder.reconstruct_doc_at(store, uuid, target_commit_id)

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
