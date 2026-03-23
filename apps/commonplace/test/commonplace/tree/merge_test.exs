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

    test "detects name collision — no common ancestor", %{store: store} do
      root_uuid = create_schema(store, %{})

      fork_root = Fork.fork_directory(root_uuid, store)

      # Both branches add "conflict.txt" independently
      source_file = create_text_doc(store, "conflict.txt", "source version")
      add_to_schema(store, fork_root, "conflict.txt", :doc, source_file)

      target_file = create_text_doc(store, "conflict.txt", "target version")
      add_to_schema(store, root_uuid, "conflict.txt", :doc, target_file)

      {:ok, report} = Merge.merge(fork_root, root_uuid, store)

      # Should detect name collision (no common ancestor)
      assert length(report.conflicts) >= 1
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
end
