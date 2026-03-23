defmodule Commonplace.Sync.RenameTest do
  @moduledoc """
  Tests for rename detection in the filesystem watcher.
  """
  use ExUnit.Case

  alias Commonplace.Sync.Watcher
  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore

  setup do
    store_dir = Path.join(System.tmp_dir!(), "cp_rename_store_#{:rand.uniform(1_000_000)}")
    sync_dir = Path.join(System.tmp_dir!(), "cp_rename_sync_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(store_dir)
    File.mkdir_p!(sync_dir)
    store_name = :"commit_store_rename_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: store_dir, name: store_name})

    on_exit(fn ->
      File.rm_rf!(store_dir)
      File.rm_rf!(sync_dir)
    end)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{store: store_name, sync_dir: sync_dir, root_uuid: root_uuid}
  end

  describe "rename detection" do
    test "detects rename when content matches", %{store: store, sync_dir: dir, root_uuid: root} do
      file_uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "old.txt")
      doc = ContentType.insert_text(doc, 0, "hello world")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, file_uuid, update, nil)

      root_doc = load_schema(root, store)
      root_doc = Schema.add_file(root_doc, "old.txt", file_uuid)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(store, root, update, nil)

      File.write!(Path.join(dir, "new.txt"), "hello world")

      changes = Watcher.detect_changes(root, dir, store)
      rename = Enum.find(changes, &(&1.type == :renamed))
      assert rename != nil
      assert rename.name == "new.txt"
      assert rename.old_name == "old.txt"
      assert rename.node_id == file_uuid
    end

    test "preserves UUID after rename sync", %{store: store, sync_dir: dir, root_uuid: root} do
      file_uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "before.txt")
      doc = ContentType.insert_text(doc, 0, "preserved content")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, file_uuid, update, nil)

      root_doc = load_schema(root, store)
      root_doc = Schema.add_file(root_doc, "before.txt", file_uuid)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(store, root, update, nil)

      File.write!(Path.join(dir, "after.txt"), "preserved content")

      Watcher.sync_recursive(root, dir, store)

      root_doc = load_schema(root, store)
      assert :error = Schema.get_entry(root_doc, "before.txt")
      assert {:ok, entry} = Schema.get_entry(root_doc, "after.txt")
      assert entry.node_id == file_uuid
    end

    test "does not detect rename for empty files", %{store: store, sync_dir: dir, root_uuid: root} do
      file_uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "empty.txt")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, file_uuid, update, nil)

      root_doc = load_schema(root, store)
      root_doc = Schema.add_file(root_doc, "empty.txt", file_uuid)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(store, root, update, nil)

      File.write!(Path.join(dir, "also-empty.txt"), "")

      changes = Watcher.detect_changes(root, dir, store)
      refute Enum.any?(changes, &(&1.type == :renamed))
    end

    test "handles multiple simultaneous renames", %{store: store, sync_dir: dir, root_uuid: root} do
      uuid_a = UUID.uuid4()
      uuid_b = UUID.uuid4()

      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "a.txt")
      doc = ContentType.insert_text(doc, 0, "content a")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, uuid_a, update, nil)

      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "b.txt")
      doc = ContentType.insert_text(doc, 0, "content b")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, uuid_b, update, nil)

      root_doc = load_schema(root, store)
      root_doc = Schema.add_file(root_doc, "a.txt", uuid_a)
      root_doc = Schema.add_file(root_doc, "b.txt", uuid_b)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(store, root, update, nil)

      File.write!(Path.join(dir, "x.txt"), "content a")
      File.write!(Path.join(dir, "y.txt"), "content b")

      changes = Watcher.detect_changes(root, dir, store)
      renames = Enum.filter(changes, &(&1.type == :renamed))
      assert length(renames) == 2
    end

    test "rename does not affect unrelated created files", %{store: store, sync_dir: dir, root_uuid: root} do
      file_uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "old.txt")
      doc = ContentType.insert_text(doc, 0, "match me")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, file_uuid, update, nil)

      root_doc = load_schema(root, store)
      root_doc = Schema.add_file(root_doc, "old.txt", file_uuid)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(store, root, update, nil)

      File.write!(Path.join(dir, "renamed.txt"), "match me")
      File.write!(Path.join(dir, "brand-new.txt"), "different content")

      changes = Watcher.detect_changes(root, dir, store)
      renames = Enum.filter(changes, &(&1.type == :renamed))
      creates = Enum.filter(changes, &(&1.type == :created))

      assert length(renames) == 1
      assert hd(renames).name == "renamed.txt"
      assert length(creates) == 1
      assert hd(creates).name == "brand-new.txt"
    end
  end

  describe "inode-based rename detection" do
    test "detects rename via inode registry", %{store: store, sync_dir: dir, root_uuid: root} do
      alias Commonplace.Sync.InodeTracker

      {:ok, registry} = InodeTracker.Registry.start_link([])

      file_uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "tracked.txt")
      doc = ContentType.insert_text(doc, 0, "inode content")
      update = Yelixer.Encoding.encode_update(doc)
      commit = CommitStore.create_commit(store, file_uuid, update, nil)

      root_doc = load_schema(root, store)
      root_doc = Schema.add_file(root_doc, "tracked.txt", file_uuid)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(store, root, update, nil)

      # Write the file and track its inode
      original_path = Path.join(dir, "tracked.txt")
      File.write!(original_path, "inode content")
      inode_key = InodeTracker.inode_key(original_path)
      InodeTracker.Registry.track(registry, inode_key, commit.id, file_uuid, original_path)

      # Rename on disk (mv preserves inode)
      renamed_path = Path.join(dir, "moved.txt")
      File.rename!(original_path, renamed_path)

      # Detect with inode registry
      changes = Watcher.detect_changes(root, dir, store, inode_registry: registry)
      rename = Enum.find(changes, &(&1.type == :renamed))

      assert rename != nil
      assert rename.name == "moved.txt"
      assert rename.old_name == "tracked.txt"
      assert rename.node_id == file_uuid

      GenServer.stop(registry)
    end

    test "inode rename works even for empty files", %{store: store, sync_dir: dir, root_uuid: root} do
      alias Commonplace.Sync.InodeTracker

      {:ok, registry} = InodeTracker.Registry.start_link([])

      file_uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "empty.txt")
      update = Yelixer.Encoding.encode_update(doc)
      commit = CommitStore.create_commit(store, file_uuid, update, nil)

      root_doc = load_schema(root, store)
      root_doc = Schema.add_file(root_doc, "empty.txt", file_uuid)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(store, root, update, nil)

      # Write empty file and track
      original_path = Path.join(dir, "empty.txt")
      File.write!(original_path, "")
      inode_key = InodeTracker.inode_key(original_path)
      InodeTracker.Registry.track(registry, inode_key, commit.id, file_uuid, original_path)

      # Rename
      File.rename!(original_path, Path.join(dir, "still-empty.txt"))

      changes = Watcher.detect_changes(root, dir, store, inode_registry: registry)
      rename = Enum.find(changes, &(&1.type == :renamed))

      # Inode-based detection catches empty file renames (content-based would not)
      assert rename != nil
      assert rename.name == "still-empty.txt"
      assert rename.old_name == "empty.txt"

      GenServer.stop(registry)
    end
  end

  defp load_schema(uuid, store) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end
end
