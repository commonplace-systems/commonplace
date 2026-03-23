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

        # Use {:found, list} | {:not_found, list} to distinguish target hit vs miss
        result =
          Enum.reduce_while(oldest_first, {:not_found, []}, fn commit, {_status, acc} ->
            if commit.id == target_commit_id do
              {:halt, {:found, Enum.reverse([commit | acc])}}
            else
              {:cont, {:not_found, [commit | acc]}}
            end
          end)

        case result do
          {:found, commits_to_apply} ->
            doc = Doc.new()

            Enum.reduce_while(commits_to_apply, {:ok, doc}, fn commit, {:ok, acc} ->
              case Encoding.apply_update(acc, commit.update) do
                {:ok, updated} -> {:cont, {:ok, updated}}
                {:error, reason} -> {:halt, {:error, reason}}
              end
            end)

          {:not_found, _} ->
            :none
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

    # Capture pre-merge target commit state for conflict detection (P1-C fix:
    # content merge in step 1 creates new target commits; conflict detection
    # must compare against state BEFORE those merges to avoid false positives)
    pre_merge_target_commits =
      Map.new(manifest.document_map, fn {_source_uuid, entry} ->
        case CommitStore.latest_commit(store, entry.original_uuid) do
          {:ok, commit} -> {entry.original_uuid, commit.id}
          :none -> {entry.original_uuid, nil}
        end
      end)

    # Step 1: Merge content for leaf documents only.
    # Skip root schema AND all directory schema docs — those are handled
    # via structural diff, not raw CRDT merge (node_ids are branch-specific).
    # Walk BOTH current and fork-point source trees to catch deleted dirs too.
    dir_uuids = collect_all_directory_uuids(store, source_uuid, manifest)

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

          :none ->
            %{rep | errors: [{:content_merge_failed, source_doc_uuid, :fork_point_not_found} | rep.errors]}

          {:error, reason} ->
            %{rep | errors: [{:content_merge_failed, source_doc_uuid, reason} | rep.errors]}
        end
      end)

    # Step 2: Schema diff + application (only if root is in manifest)
    case Map.get(manifest.document_map, source_uuid) do
      %{fork_point_commit: root_fork_point} ->
        {:ok, cur_source_schema} = reconstruct_doc(store, source_uuid)
        {:ok, cur_target_schema} = reconstruct_doc(store, target_uuid)

        # Schema diff baseline: try root_fork_point on the source chain.
        # After the first merge, this is a SOURCE commit (set by update_manifest_fork_points).
        # On the very first merge, fork_point_commit is on the TARGET chain (set by Fork),
        # so it won't be found on the source — fall back to source's first commit.
        source_baseline_schema =
          case reconstruct_doc_at(store, source_uuid, root_fork_point) do
            {:ok, doc} ->
              doc

            :none ->
              # First merge: fork_point is on target chain, use source's first commit
              source_commits = CommitStore.commit_log(store, source_uuid, limit: 10_000)
              source_first = List.last(source_commits)
              {:ok, doc} = reconstruct_doc_at(store, source_uuid, source_first.id)
              doc
          end

        # For collision detection, we need the target's state at fork time.
        # Use the original fork-point from the manifest (on target chain),
        # not pre-merge state which would match current and disable collision detection.
        target_fork_point_schema =
          case reconstruct_doc_at(store, target_uuid, root_fork_point) do
            {:ok, doc} -> doc
            :none ->
              # First merge: root_fork_point is on target chain but may be the initial commit
              {:ok, doc} = reconstruct_doc(store, target_uuid)
              doc
          end

        source_fp_entries = Schema.entries(source_baseline_schema)
        cur_source_entries = Schema.entries(cur_source_schema)
        cur_target_entries = Schema.entries(cur_target_schema)
        fp_target_entries = Schema.entries(target_fork_point_schema)

        # Step 3: Diff source schemas (baseline vs current = what changed since last merge)
        diff = diff_schemas(source_fp_entries, cur_source_entries)

        # Step 4: Apply schema changes to target, passing pre-merge state for conflict detection
        {updated_target_schema, manifest, report} =
          apply_schema_changes(
            store, cur_target_schema, diff, manifest, cur_target_entries, report,
            fork_point_target_entries: fp_target_entries,
            pre_merge_target_commits: pre_merge_target_commits
          )

        # Step 5: Always filter __processes.json if present.
        # Content merge in step 1 can introduce unsafe entries even without
        # schema-level changes to __processes.json.
        updated_target_schema = maybe_filter_processes(store, updated_target_schema)

        # Commit updated target schema
        {:ok, target_latest} = CommitStore.latest_commit(store, target_uuid)
        schema_update = Encoding.encode_update(updated_target_schema)
        CommitStore.create_commit(store, target_uuid, schema_update, target_latest.id)

        # Step 6: Update manifest fork points (last — crash safety)
        # Root entry: store SOURCE's latest commit (for incremental schema diff)
        # Leaf entries: store TARGET's latest commit (for merge_content_doc)
        manifest = update_manifest_fork_points(store, manifest, Map.keys(manifest.document_map), source_uuid)

        {:ok, manifest, report}

      nil ->
        manifest = update_manifest_fork_points(store, manifest, Map.keys(manifest.document_map), nil)
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
    pre_merge_commits = Keyword.get(opts, :pre_merge_target_commits, %{})

    {target_doc, manifest, report} =
      apply_additions(store, target_doc, diff.added, manifest, target_entries, fp_target_entries, report)

    {target_doc, report} =
      apply_removals(store, target_doc, diff.removed, manifest, pre_merge_commits, report)

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

  defp apply_removals(store, target_doc, removed, manifest, pre_merge_commits, report) do
    Enum.reduce(removed, {target_doc, report}, fn {name, entry_map}, {doc, rep} ->
      source_node_id = entry_map["node_id"]

      case Map.get(manifest.document_map, source_node_id) do
        %{original_uuid: target_uuid, fork_point_commit: fork_point_commit} ->
          # Use pre-merge target state to detect conflict (not current state,
          # which may have been updated by content merge in step 1)
          pre_merge_commit = Map.get(pre_merge_commits, target_uuid)

          if target_modified_since_pre_merge?(pre_merge_commit, fork_point_commit) do
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

  # Merge sub-manifest entries into parent, inverting the key direction.
  # Fork.fork_directory returns manifest keyed as new_uuid → {original_uuid, ...}
  # (new = target copy, original = source). But merge needs source → target
  # keying. Invert: original_uuid becomes the key, new_uuid becomes original_uuid.
  defp merge_sub_manifest(parent, sub_manifest) do
    inverted =
      Map.new(sub_manifest.document_map, fn {new_uuid, entry} ->
        {entry.original_uuid, %{entry | original_uuid: new_uuid}}
      end)

    %{parent | document_map: Map.merge(parent.document_map, inverted)}
  end

  # Check if target was modified since fork using pre-merge commit state.
  # This avoids false positives from content merges in step 1.
  defp target_modified_since_pre_merge?(pre_merge_commit_id, fork_point_commit_id) do
    pre_merge_commit_id != nil and pre_merge_commit_id != fork_point_commit_id
  end

  @doc """
  Filter __processes.json entries using Config.fork_behavior/1.
  Delegates to Config.filter_json_for_fork/1 — same rules as fork.
  """
  def filter_processes_for_merge(proc_json) do
    Config.filter_json_for_fork(proc_json)
  end

  @doc """
  Advance fork_point_commit for each manifest entry.

  - Root schema entry (source_uuid == root_source_uuid): store SOURCE's latest
    commit, used as baseline for incremental schema diffing.
  - Leaf doc entries: store TARGET's latest commit, used by merge_content_doc/4
    to reconstruct fork-point from the target chain.

  Called last for crash safety — manifest update is the merge "commit point".
  """
  def update_manifest_fork_points(store, manifest, source_uuids, root_source_uuid) do
    Enum.reduce(source_uuids, manifest, fn source_uuid, man ->
      case Map.get(man.document_map, source_uuid) do
        nil ->
          man

        entry ->
          # Root: use source commit (for schema diff baseline)
          # Leaf: use target commit (for merge_content_doc reconstruction)
          lookup_uuid =
            if source_uuid == root_source_uuid, do: source_uuid, else: entry.original_uuid

          case CommitStore.latest_commit(store, lookup_uuid) do
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

  # Collect directory UUIDs from BOTH current and fork-point source trees.
  # Deleted directories still have manifest entries and must be excluded from content merge.
  defp collect_all_directory_uuids(store, source_uuid, manifest) do
    current_dirs = collect_directory_uuids(store, source_uuid)

    # Also check fork-point source if available
    fork_point_dirs =
      case Map.get(manifest.document_map, source_uuid) do
        %{fork_point_commit: fp_commit} ->
          case reconstruct_doc_at(store, source_uuid, fp_commit) do
            {:ok, fp_schema} ->
              entries = Schema.entries(fp_schema)

              entries
              |> Enum.filter(fn {_name, e} -> e["type"] == "dir" end)
              |> Enum.reduce(MapSet.new(), fn {_name, e}, acc ->
                MapSet.put(acc, e["node_id"])
              end)

            :none ->
              MapSet.new()
          end

        nil ->
          MapSet.new()
      end

    MapSet.union(current_dirs, fork_point_dirs)
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
