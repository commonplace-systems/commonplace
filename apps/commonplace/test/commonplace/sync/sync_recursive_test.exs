defmodule Commonplace.Sync.SyncRecursiveTest do
  @moduledoc """
  Tests for sync_recursive — full tree sync across nested directories.
  """
  use ExUnit.Case

  alias Commonplace.Sync.{Watcher, Export}
  alias Commonplace.Tree.{Schema, Walk}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore

  setup do
    store_dir = Path.join(System.tmp_dir!(), "cp_rec_store_#{:rand.uniform(1_000_000)}")
    sync_dir = Path.join(System.tmp_dir!(), "cp_rec_sync_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(store_dir)
    File.mkdir_p!(sync_dir)

    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: store_dir, name: store_name})

    on_exit(fn ->
      File.rm_rf!(store_dir)
      File.rm_rf!(sync_dir)
    end)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{store: store_name, sync_dir: sync_dir, root: root_uuid}
  end

  defp loader(store) do
    fn uuid ->
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

  defp read_content(uuid, store) do
    {:ok, commit} = CommitStore.latest_commit(store, uuid)
    doc = Yelixer.Doc.new()
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
    ContentType.get_content(doc)
  end

  describe "sync_recursive" do
    test "syncs a deeply nested directory tree in one call", %{store: store, sync_dir: dir, root: root} do
      # Create a 3-level deep tree on disk
      File.write!(Path.join(dir, "root.txt"), "at root")
      File.mkdir_p!(Path.join(dir, "level1"))
      File.write!(Path.join(dir, "level1/mid.txt"), "at level 1")
      File.mkdir_p!(Path.join(dir, "level1/level2"))
      File.write!(Path.join(dir, "level1/level2/deep.txt"), "at level 2")
      File.mkdir_p!(Path.join(dir, "level1/level2/level3"))
      File.write!(Path.join(dir, "level1/level2/level3/leaf.txt"), "at level 3")

      Watcher.sync_recursive(root, dir, store)

      load = loader(store)
      {:ok, root_uuid} = Walk.resolve_path(root, "root.txt", load)
      assert read_content(root_uuid, store) == "at root"

      {:ok, mid_uuid} = Walk.resolve_path(root, "level1/mid.txt", load)
      assert read_content(mid_uuid, store) == "at level 1"

      {:ok, deep_uuid} = Walk.resolve_path(root, "level1/level2/deep.txt", load)
      assert read_content(deep_uuid, store) == "at level 2"

      {:ok, leaf_uuid} = Walk.resolve_path(root, "level1/level2/level3/leaf.txt", load)
      assert read_content(leaf_uuid, store) == "at level 3"
    end

    test "second sync after editing nested files detects changes", %{store: store, sync_dir: dir, root: root} do
      File.mkdir_p!(Path.join(dir, "sub"))
      File.write!(Path.join(dir, "sub/file.txt"), "original")

      Watcher.sync_recursive(root, dir, store)

      load = loader(store)
      {:ok, uuid} = Walk.resolve_path(root, "sub/file.txt", load)
      assert read_content(uuid, store) == "original"

      # Edit the nested file
      File.write!(Path.join(dir, "sub/file.txt"), "modified")

      Watcher.sync_recursive(root, dir, store)

      assert read_content(uuid, store) == "modified"
    end

    test "adding new files in nested dirs on second sync", %{store: store, sync_dir: dir, root: root} do
      File.mkdir_p!(Path.join(dir, "sub"))
      File.write!(Path.join(dir, "sub/first.txt"), "first")

      Watcher.sync_recursive(root, dir, store)

      # Add a new file in the nested dir
      File.write!(Path.join(dir, "sub/second.txt"), "second")

      Watcher.sync_recursive(root, dir, store)

      load = loader(store)
      {:ok, entries} = Walk.list_path(root, "sub", load)
      names = Enum.map(entries, & &1.name) |> Enum.sort()
      assert names == ["first.txt", "second.txt"]

      {:ok, uuid} = Walk.resolve_path(root, "sub/second.txt", load)
      assert read_content(uuid, store) == "second"
    end

    test "deleting files in nested dirs on second sync", %{store: store, sync_dir: dir, root: root} do
      File.mkdir_p!(Path.join(dir, "sub"))
      File.write!(Path.join(dir, "sub/keep.txt"), "keep")
      File.write!(Path.join(dir, "sub/remove.txt"), "remove")

      Watcher.sync_recursive(root, dir, store)

      load = loader(store)
      {:ok, entries} = Walk.list_path(root, "sub", load)
      assert length(entries) == 2

      # Delete one file
      File.rm!(Path.join(dir, "sub/remove.txt"))

      Watcher.sync_recursive(root, dir, store)

      {:ok, entries} = Walk.list_path(root, "sub", load)
      names = Enum.map(entries, & &1.name)
      assert names == ["keep.txt"]
    end

    test "adding a new nested directory with files on second sync", %{store: store, sync_dir: dir, root: root} do
      File.write!(Path.join(dir, "existing.txt"), "here")

      Watcher.sync_recursive(root, dir, store)

      # Add new directory with files
      File.mkdir_p!(Path.join(dir, "newdir"))
      File.write!(Path.join(dir, "newdir/a.txt"), "aaa")
      File.write!(Path.join(dir, "newdir/b.txt"), "bbb")

      Watcher.sync_recursive(root, dir, store)

      load = loader(store)
      {:ok, entries} = Walk.list_path(root, "newdir", load)
      names = Enum.map(entries, & &1.name) |> Enum.sort()
      assert names == ["a.txt", "b.txt"]

      {:ok, uuid} = Walk.resolve_path(root, "newdir/a.txt", load)
      assert read_content(uuid, store) == "aaa"
    end

    test "no changes on idempotent second sync", %{store: store, sync_dir: dir, root: root} do
      File.mkdir_p!(Path.join(dir, "sub"))
      File.write!(Path.join(dir, "top.txt"), "top")
      File.write!(Path.join(dir, "sub/nested.txt"), "nested")

      Watcher.sync_recursive(root, dir, store)

      # Second sync should be a no-op
      changes_root = Watcher.detect_changes(root, dir, store)
      assert changes_root == []

      {:ok, sub_entry} = Schema.get_entry(loader(store).(root), "sub")
      changes_sub = Watcher.detect_changes(sub_entry.node_id, Path.join(dir, "sub"), store)
      assert changes_sub == []
    end

    test "sync then export roundtrip for nested tree", %{store: store, sync_dir: dir, root: root} do
      File.mkdir_p!(Path.join(dir, "a/b"))
      File.write!(Path.join(dir, "a/b/deep.txt"), "deep content")
      File.write!(Path.join(dir, "top.txt"), "top content")

      Watcher.sync_recursive(root, dir, store)

      # Export to a different directory
      export_dir = Path.join(System.tmp_dir!(), "cp_rec_export_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(export_dir)
      Export.export(root, export_dir, store)

      assert File.read!(Path.join(export_dir, "top.txt")) == "top content"
      assert File.read!(Path.join(export_dir, "a/b/deep.txt")) == "deep content"

      File.rm_rf!(export_dir)
    end
  end
end
