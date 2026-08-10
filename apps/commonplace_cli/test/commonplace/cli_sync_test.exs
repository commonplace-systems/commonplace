defmodule Commonplace.CLI.SyncTest do
  @moduledoc """
  Integration tests for the CLI sync command.
  Tests the full flow: init → import → edit on disk → sync → verify CRDT.
  """
  use ExUnit.Case

  alias Commonplace.CLI
  alias Commonplace.Tree.{Schema, Walk}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Sync.{Export, Watcher}

  setup do
    workspace = Path.join(System.tmp_dir!(), "cp_sync_ws_#{:rand.uniform(1_000_000)}")
    sync_dir = Path.join(System.tmp_dir!(), "cp_sync_dir_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(workspace)
    File.mkdir_p!(sync_dir)

    on_exit(fn ->
      _ = Application.stop(:commonplace)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data", persistent: true)
      File.rm_rf!(workspace)
      File.rm_rf!(sync_dir)
      {:ok, _} = Application.ensure_all_started(:commonplace)
    end)

    # Init workspace
    CLI.ensure_started(workspace)
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(root_uuid, update, nil)
    CLI.set_root_uuid(workspace, root_uuid)

    %{workspace: workspace, sync_dir: sync_dir, root: root_uuid}
  end

  test "full flow: import → export → edit → sync → verify", %{
    workspace: _ws,
    sync_dir: dir,
    root: root
  } do
    # Step 1: Import some files
    File.write!(Path.join(dir, "readme.txt"), "Hello\n")
    File.mkdir_p!(Path.join(dir, "notes"))
    File.write!(Path.join(dir, "notes/todo.txt"), "Buy milk\n")

    Watcher.sync_recursive(root, dir)

    # Verify files are in CRDT
    loader = &CLI.load_schema/1
    {:ok, entries} = Walk.list_path(root, "", loader)
    names = Enum.map(entries, & &1.name) |> Enum.sort()
    assert names == ["notes", "readme.txt"]

    {:ok, readme_uuid} = Walk.resolve_path(root, "readme.txt", loader)
    assert read_content(readme_uuid) == "Hello\n"

    # Step 2: Edit a file on disk
    File.write!(Path.join(dir, "readme.txt"), "Hello, updated!\n")

    changes = Watcher.detect_changes(root, dir)
    modified = Enum.filter(changes, &(&1.type == :modified))
    assert length(modified) == 1
    Watcher.apply_changes(changes, root, dir)

    # Verify CRDT updated
    assert read_content(readme_uuid) == "Hello, updated!\n"

    # Step 3: Add a new file on disk
    File.write!(Path.join(dir, "new.txt"), "Brand new\n")

    changes = Watcher.detect_changes(root, dir)
    created = Enum.filter(changes, &(&1.type == :created))
    assert length(created) == 1
    Watcher.apply_changes(changes, root, dir)

    {:ok, new_uuid} = Walk.resolve_path(root, "new.txt", loader)
    assert read_content(new_uuid) == "Brand new\n"

    # Step 4: Delete a file on disk
    File.rm!(Path.join(dir, "readme.txt"))

    changes = Watcher.detect_changes(root, dir)
    deleted = Enum.filter(changes, &(&1.type == :deleted))
    assert length(deleted) == 1
    Watcher.apply_changes(changes, root, dir)

    {:ok, entries} = Walk.list_path(root, "", loader)
    names = Enum.map(entries, & &1.name) |> Enum.sort()
    assert "readme.txt" not in names
    assert "new.txt" in names

    # Step 5: Export and verify disk matches CRDT
    export_dir = Path.join(System.tmp_dir!(), "cp_sync_export_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(export_dir)
    Export.export(root, export_dir)

    assert File.read!(Path.join(export_dir, "new.txt")) == "Brand new\n"
    assert File.read!(Path.join(export_dir, "notes/todo.txt")) == "Buy milk\n"
    refute File.exists?(Path.join(export_dir, "readme.txt"))

    File.rm_rf!(export_dir)
  end

  test "sync detects no changes when disk matches CRDT", %{
    sync_dir: dir,
    root: root
  } do
    # Import a file
    File.write!(Path.join(dir, "stable.txt"), "unchanged")
    changes = Watcher.detect_changes(root, dir)
    Watcher.apply_changes(changes, root, dir)

    # No changes on second scan
    changes = Watcher.detect_changes(root, dir)
    assert changes == []
  end

  test "sync handles empty directories", %{sync_dir: dir, root: root} do
    File.mkdir_p!(Path.join(dir, "empty"))

    changes = Watcher.detect_changes(root, dir)
    assert length(changes) == 1
    Watcher.apply_changes(changes, root, dir)

    loader = &CLI.load_schema/1
    {:ok, entries} = Walk.list_path(root, "", loader)
    assert length(entries) == 1
    assert hd(entries).name == "empty"
    assert hd(entries).type == :dir
  end

  test "multiple edits then single sync", %{sync_dir: dir, root: root} do
    # Create several files at once
    File.write!(Path.join(dir, "a.txt"), "aaa")
    File.write!(Path.join(dir, "b.txt"), "bbb")
    File.write!(Path.join(dir, "c.txt"), "ccc")

    changes = Watcher.detect_changes(root, dir)
    assert length(changes) == 3
    Watcher.apply_changes(changes, root, dir)

    loader = &CLI.load_schema/1
    {:ok, entries} = Walk.list_path(root, "", loader)
    assert length(entries) == 3

    # Modify all three
    File.write!(Path.join(dir, "a.txt"), "AAA")
    File.write!(Path.join(dir, "b.txt"), "BBB")
    File.write!(Path.join(dir, "c.txt"), "CCC")

    changes = Watcher.detect_changes(root, dir)
    assert length(changes) == 3
    assert Enum.all?(changes, &(&1.type == :modified))
    Watcher.apply_changes(changes, root, dir)

    {:ok, a_uuid} = Walk.resolve_path(root, "a.txt", loader)
    assert read_content(a_uuid) == "AAA"
  end

  defp read_content(uuid) do
    {:ok, commit} = CommitStore.latest_commit(uuid)
    doc = Yelixer.Doc.new()
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
    ContentType.get_content(doc)
  end
end
