defmodule Commonplace.Tree.MergeTest do
  use ExUnit.Case

  alias Commonplace.Tree.{Merge, Schema, Fork}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_merge_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_merge_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name}
  end

  describe "merge/3" do
    test "merges content edits from source to target", %{store: store} do
      file_uuid = create_text_doc(store, "file.txt", "hello")
      root_uuid = create_schema(store, %{"file.txt" => {:doc, file_uuid}})

      fork_root = Fork.fork_directory(root_uuid, store)
      {fork_file_uuid, _} = get_child(store, fork_root, "file.txt")

      # Edit on fork
      edit_doc(store, fork_file_uuid, " world", 5)

      {:ok, report} = Merge.merge(fork_root, root_uuid, store)

      # Target now has merged content
      {:ok, doc} = reconstruct_doc(store, file_uuid)
      content = ContentType.get_content(doc)
      assert content =~ "hello"
      assert content =~ "world"
      assert report.conflicts == []
    end

    test "merges schema additions", %{store: store} do
      file_uuid = create_text_doc(store, "existing.txt", "existing")
      root_uuid = create_schema(store, %{"existing.txt" => {:doc, file_uuid}})

      fork_root = Fork.fork_directory(root_uuid, store)

      # Add new file on fork
      new_file = create_text_doc(store, "added.txt", "new content")
      add_to_schema(store, fork_root, "added.txt", :doc, new_file)

      {:ok, report} = Merge.merge(fork_root, root_uuid, store)

      # Target schema now has added.txt
      {:ok, target_schema} = reconstruct_schema(store, root_uuid)
      assert {:ok, _} = Schema.get_entry(target_schema, "added.txt")
      assert length(report.new_docs) >= 1
    end

    test "auto-renames on name collision — no common ancestor", %{store: store} do
      root_uuid = create_schema(store, %{})

      fork_root = Fork.fork_directory(root_uuid, store)

      # Both branches add "conflict.txt" independently
      source_file = create_text_doc(store, "conflict.txt", "source version")
      add_to_schema(store, fork_root, "conflict.txt", :doc, source_file)

      target_file = create_text_doc(store, "conflict.txt", "target version")
      add_to_schema(store, root_uuid, "conflict.txt", :doc, target_file)

      {:ok, report} = Merge.merge(fork_root, root_uuid, store)

      # Should auto-rename the incoming entry to avoid collision
      assert length(report.auto_renamed) >= 1
    end

    test "empty merge is a no-op", %{store: store} do
      file_uuid = create_text_doc(store, "file.txt", "unchanged")
      root_uuid = create_schema(store, %{"file.txt" => {:doc, file_uuid}})

      fork_root = Fork.fork_directory(root_uuid, store)

      {:ok, report} = Merge.merge(fork_root, root_uuid, store)
      assert report.merged_docs == []
      assert report.new_docs == []
      assert report.conflicts == []
    end

    test "repeated merge only applies new changes", %{store: store} do
      file_uuid = create_text_doc(store, "file.txt", "v1")
      root_uuid = create_schema(store, %{"file.txt" => {:doc, file_uuid}})

      fork_root = Fork.fork_directory(root_uuid, store)
      {fork_file, _} = get_child(store, fork_root, "file.txt")

      # First edit + merge
      edit_doc(store, fork_file, " edit1", 2)
      {:ok, _} = Merge.merge(fork_root, root_uuid, store)

      {:ok, doc1} = reconstruct_doc(store, file_uuid)
      assert ContentType.get_content(doc1) =~ "edit1"

      # Second edit + merge (should only apply new changes)
      edit_doc(store, fork_file, "NEW ", 0)
      {:ok, _} = Merge.merge(fork_root, root_uuid, store)

      {:ok, doc2} = reconstruct_doc(store, file_uuid)
      content = ContentType.get_content(doc2)
      assert content =~ "NEW"
      assert content =~ "edit1"
    end

    test "concurrent edits merge via CRDT", %{store: store} do
      file_uuid = create_text_doc(store, "shared.txt", "base")
      root_uuid = create_schema(store, %{"shared.txt" => {:doc, file_uuid}})

      fork_root = Fork.fork_directory(root_uuid, store)
      {fork_file_uuid, _} = get_child(store, fork_root, "shared.txt")

      # Edit on both branches
      edit_doc(store, fork_file_uuid, " SOURCE", 4)
      edit_doc(store, file_uuid, " TARGET", 4)

      {:ok, report} = Merge.merge(fork_root, root_uuid, store)
      assert report.conflicts == []

      {:ok, doc} = reconstruct_doc(store, file_uuid)
      content = ContentType.get_content(doc)
      assert content =~ "SOURCE"
      assert content =~ "TARGET"
    end

    test "delete-vs-modify: source deletes an entry target has modified", %{store: store} do
      file_uuid = create_text_doc(store, "important.txt", "original content")
      root_uuid = create_schema(store, %{"important.txt" => {:doc, file_uuid}})

      fork_root = Fork.fork_directory(root_uuid, store)

      # Edit the file on target after forking
      edit_doc(store, file_uuid, " target edit", 16)

      # Delete the file from source's schema
      remove_from_schema(store, fork_root, "important.txt")

      {:ok, report} = Merge.merge(fork_root, root_uuid, store)

      # Should detect a conflict: source deleted it, target modified it
      assert Enum.any?(report.conflicts, fn
        {:delete_vs_modify, "important.txt", _} -> true
        _ -> false
      end)

      # The entry should still be in target schema (not deleted)
      {:ok, target_schema} = reconstruct_schema(store, root_uuid)
      assert {:ok, _} = Schema.get_entry(target_schema, "important.txt")
    end

    test "safe deletion: source deletes an unmodified entry", %{store: store} do
      file_uuid = create_text_doc(store, "removeme.txt", "expendable")
      root_uuid = create_schema(store, %{"removeme.txt" => {:doc, file_uuid}})

      fork_root = Fork.fork_directory(root_uuid, store)

      # Delete the file from source's schema — but don't edit it on target
      remove_from_schema(store, fork_root, "removeme.txt")

      {:ok, report} = Merge.merge(fork_root, root_uuid, store)

      assert report.conflicts == []

      # The entry should have been deleted from target schema
      {:ok, target_schema} = reconstruct_schema(store, root_uuid)
      assert :error = Schema.get_entry(target_schema, "removeme.txt")

      assert length(report.deleted_docs) >= 1
    end

    test "nested directory merge: edits in subdirectory are propagated", %{store: store} do
      # Build: root -> subdir -> nested_file.txt
      nested_file_uuid = create_text_doc(store, "nested.txt", "original")
      subdir_uuid = create_schema(store, %{"nested.txt" => {:doc, nested_file_uuid}})
      root_uuid = create_schema(store, %{"subdir" => {:dir, subdir_uuid}})

      fork_root = Fork.fork_directory(root_uuid, store)

      # Navigate into the fork's subdirectory and its nested file
      {fork_subdir_uuid, _} = get_child(store, fork_root, "subdir")
      {fork_nested_uuid, _} = get_child(store, fork_subdir_uuid, "nested.txt")

      # Edit the nested file on the fork
      edit_doc(store, fork_nested_uuid, " edited", 8)

      {:ok, report} = Merge.merge(fork_root, root_uuid, store)

      assert report.conflicts == []

      # The original nested_file on target should have the edit merged in
      {:ok, doc} = reconstruct_doc(store, nested_file_uuid)
      content = ContentType.get_content(doc)
      assert content =~ "original"
      assert content =~ "edited"
    end

    test "__processes.json filtering: non-forkable processes are removed after merge", %{store: store} do
      # Start with an empty target (no __processes.json on target initially)
      root_uuid = create_schema(store, %{})

      fork_root = Fork.fork_directory(root_uuid, store)

      # Add __processes.json with both forkable and non-forkable processes on the fork
      proc_json = Jason.encode!(%{
        "safe_proc" => %{"mode" => "elixir", "source" => "SomeModule"},
        "unsafe_proc" => %{"mode" => "command", "command" => "bash", "fork" => "skip"}
      })
      proc_uuid = create_text_doc(store, "__processes.json", proc_json)
      add_to_schema(store, fork_root, "__processes.json", :doc, proc_uuid)

      # Merge the fork (which has __processes.json) into the target (which doesn't)
      # merge_directory uses fork_into_target to copy the entry, then calls
      # maybe_filter_processes which strips the non-forkable process from target's copy.
      {:ok, _report} = Merge.merge(fork_root, root_uuid, store)

      # After merge, target should have __processes.json with only the safe proc
      {:ok, target_schema} = reconstruct_schema(store, root_uuid)
      {:ok, proc_entry} = Schema.get_entry(target_schema, "__processes.json")

      # The target's __processes.json is a forked copy — use snapshot reconstruction
      # because fork_into_target stores a full snapshot and maybe_filter_processes
      # may also store a snapshot commit.
      {:ok, proc_doc} = reconstruct_snapshot(store, proc_entry.node_id)
      content = ContentType.get_content(proc_doc)
      {:ok, decoded} = Jason.decode(content)

      assert Map.has_key?(decoded, "safe_proc")
      refute Map.has_key?(decoded, "unsafe_proc")
    end

    test "merge-point deletion: entry added by prior merge is removed when source deletes it", %{store: store} do
      root_uuid = create_schema(store, %{})
      fork_root = Fork.fork_directory(root_uuid, store)

      # Add a new file on the fork
      new_file = create_text_doc(store, "forked.txt", "forked content")
      add_to_schema(store, fork_root, "forked.txt", :doc, new_file)

      # First merge: propagates forked.txt to target
      {:ok, report1} = Merge.merge(fork_root, root_uuid, store)
      assert length(report1.new_docs) >= 1

      {:ok, target_schema_after_first} = reconstruct_schema(store, root_uuid)
      assert {:ok, _} = Schema.get_entry(target_schema_after_first, "forked.txt")

      # Now delete forked.txt from source
      remove_from_schema(store, fork_root, "forked.txt")

      # Second merge: since target entry was added via prior merge (not independently),
      # it should be removed from target
      {:ok, report2} = Merge.merge(fork_root, root_uuid, store)

      assert report2.conflicts == []
      assert length(report2.deleted_docs) >= 1

      {:ok, target_schema_after_second} = reconstruct_schema(store, root_uuid)
      assert :error = Schema.get_entry(target_schema_after_second, "forked.txt")
    end

    test "node_id replacement: source deletes and recreates file with same name", %{store: store} do
      # Create a file on the main branch
      original_file = create_text_doc(store, "config.txt", "original config")
      root_uuid = create_schema(store, %{"config.txt" => {:doc, original_file}})

      # Fork — target gets a copy of config.txt with the same node_id lineage
      fork_root = Fork.fork_directory(root_uuid, store)
      {fork_config_uuid, _} = get_child(store, fork_root, "config.txt")

      # On the fork (source), delete config.txt and recreate it with new content
      # This simulates "delete file, create new file with same name" which produces a new node_id
      remove_from_schema(store, fork_root, "config.txt")
      replacement_file = create_text_doc(store, "config.txt", "completely new config")
      add_to_schema(store, fork_root, "config.txt", :doc, replacement_file)

      # Verify the source now has a different node_id for config.txt
      {source_config_nid, _} = get_child(store, fork_root, "config.txt")
      assert source_config_nid == replacement_file
      assert source_config_nid != fork_config_uuid

      # Merge: should detect the node_id replacement and copy the new doc
      {:ok, report} = Merge.merge(fork_root, root_uuid, store)

      # No conflicts — target didn't modify the original file
      assert report.conflicts == []

      # The old node_id should be in deleted_docs
      {:ok, target_schema} = reconstruct_schema(store, root_uuid)
      {:ok, entry} = Schema.get_entry(target_schema, "config.txt")

      # The target's node_id should now be a fork of the replacement (not the original)
      assert entry.node_id != original_file
      # It should be reported as both a deletion and an addition
      assert length(report.deleted_docs) >= 1
      assert length(report.new_docs) >= 1

      # The new doc content should be the replacement content
      {:ok, new_doc} = reconstruct_doc(store, entry.node_id)
      content = ContentType.get_content(new_doc)
      assert content =~ "completely new config"
    end

    test "node_id replacement with target modification raises conflict", %{store: store} do
      # Create a file on the main branch
      original_file = create_text_doc(store, "shared.txt", "original content")
      root_uuid = create_schema(store, %{"shared.txt" => {:doc, original_file}})

      # Fork
      fork_root = Fork.fork_directory(root_uuid, store)

      # Target modifies the file after forking
      edit_doc(store, original_file, " target edit", 16)

      # Source deletes and recreates the file with a new node_id
      remove_from_schema(store, fork_root, "shared.txt")
      replacement_file = create_text_doc(store, "shared.txt", "replacement content")
      add_to_schema(store, fork_root, "shared.txt", :doc, replacement_file)

      # Merge: should detect conflict because target modified the file that source replaced
      {:ok, report} = Merge.merge(fork_root, root_uuid, store)

      assert Enum.any?(report.conflicts, fn
        {:delete_vs_modify, "shared.txt", _} -> true
        _ -> false
      end)

      # Original entry should still be in target schema (not replaced)
      {:ok, target_schema} = reconstruct_schema(store, root_uuid)
      {:ok, entry} = Schema.get_entry(target_schema, "shared.txt")
      assert entry.node_id == original_file
    end

    test "no common ancestor: merge is a no-op", %{store: store} do
      # Create two completely independent documents (no shared DAG ancestry)
      file_a = create_text_doc(store, "a.txt", "from A")
      root_a = create_schema(store, %{"a.txt" => {:doc, file_a}})

      file_b = create_text_doc(store, "b.txt", "from B")
      root_b = create_schema(store, %{"b.txt" => {:doc, file_b}})

      # Trying to merge two unrelated roots is silently skipped
      {:ok, report} = Merge.merge(root_a, root_b, store)

      assert report.merged_docs == []
      assert report.new_docs == []
      assert report.conflicts == []
    end
  end

  # --- Helpers ---

  defp create_text_doc(store, name, content) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = if content != "", do: ContentType.insert_text(doc, 0, content), else: doc
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
    uuid
  end

  defp create_schema(store, entries) do
    uuid = UUID.uuid4()
    doc = Schema.new_schema()

    doc =
      Enum.reduce(entries, doc, fn {name, {type, node_id}}, doc ->
        case type do
          :doc -> Schema.add_file(doc, name, node_id)
          :dir -> Schema.add_directory(doc, name, node_id)
        end
      end)

    CommitStore.create_commit(store, uuid, Yelixer.Encoding.encode_update(doc), nil)
    uuid
  end

  defp edit_doc(store, uuid, text, position) do
    {:ok, doc} = reconstruct_doc(store, uuid)
    doc = ContentType.insert_text(doc, position, text)
    update = Yelixer.Encoding.encode_update(doc)
    {:ok, latest} = CommitStore.latest_commit(store, uuid)
    CommitStore.create_commit(store, uuid, update, latest.id)
  end

  defp add_to_schema(store, schema_uuid, name, type, node_id) do
    {:ok, doc} = reconstruct_schema(store, schema_uuid)

    doc =
      case type do
        :doc -> Schema.add_file(doc, name, node_id)
        :dir -> Schema.add_directory(doc, name, node_id)
      end

    update = Yelixer.Encoding.encode_update(doc)
    {:ok, latest} = CommitStore.latest_commit(store, schema_uuid)
    CommitStore.create_commit(store, schema_uuid, update, latest.id)
  end

  defp get_child(store, schema_uuid, name) do
    {:ok, schema} = reconstruct_schema(store, schema_uuid)
    {:ok, entry} = Schema.get_entry(schema, name)
    {entry.node_id, entry.type}
  end

  defp reconstruct_doc(store, uuid) do
    commits = CommitStore.commit_log(store, uuid, limit: 10_000) |> Enum.reverse()
    doc = Yelixer.Doc.new()
    Enum.reduce(commits, {:ok, doc}, fn c, {:ok, d} -> Yelixer.Encoding.apply_update(d, c.update) end)
  end

  defp reconstruct_schema(store, uuid) do
    {:ok, commit} = CommitStore.latest_commit(store, uuid)
    schema = Schema.new_schema()
    Yelixer.Encoding.apply_update(schema, commit.update)
  end

  # Apply only the latest commit to a fresh doc — use for docs that store full snapshots
  # (e.g. __processes.json after maybe_filter_processes writes a new snapshot commit).
  defp reconstruct_snapshot(store, uuid) do
    {:ok, commit} = CommitStore.latest_commit(store, uuid)
    doc = Yelixer.Doc.new()
    Yelixer.Encoding.apply_update(doc, commit.update)
  end

  defp remove_from_schema(store, schema_uuid, name) do
    {:ok, doc} = reconstruct_schema(store, schema_uuid)
    doc = Schema.remove_entry(doc, name)
    update = Yelixer.Encoding.encode_update(doc)
    {:ok, latest} = CommitStore.latest_commit(store, schema_uuid)
    CommitStore.create_commit(store, schema_uuid, update, latest.id)
  end
end
