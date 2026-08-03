defmodule Commonplace.Sync.WatcherTest do
  @moduledoc """
  Tests for the filesystem watcher — detects file changes on disk
  and syncs them into CRDT documents.
  """
  use ExUnit.Case

  alias Commonplace.Sync.Watcher
  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore

  setup do
    store_dir = Path.join(System.tmp_dir!(), "cp_watch_store_#{:rand.uniform(1_000_000)}")
    watch_dir = Path.join(System.tmp_dir!(), "cp_watch_dir_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(store_dir)
    File.mkdir_p!(watch_dir)

    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: store_dir, name: store_name})

    on_exit(fn ->
      File.rm_rf!(store_dir)
      File.rm_rf!(watch_dir)
    end)

    # Create initial root schema
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{store: store_name, watch_dir: watch_dir, root_uuid: root_uuid}
  end

  describe "detect_changes/4" do
    test "detects a new file", %{store: store, watch_dir: dir, root_uuid: root} do
      File.write!(Path.join(dir, "new.txt"), "hello")

      changes = Watcher.detect_changes(root, dir, store)

      assert length(changes) == 1
      [change] = changes
      assert change.type == :created
      assert change.name == "new.txt"
      assert change.path == Path.join(dir, "new.txt")
    end

    test "detects a modified file", %{store: store, watch_dir: dir, root_uuid: root} do
      # Create file and sync it first
      File.write!(Path.join(dir, "existing.txt"), "original")
      file_uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "existing.txt")
      doc = ContentType.insert_text(doc, 0, "original")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, file_uuid, update, nil)

      root_doc = load_schema(root, store)
      root_doc = Schema.add_file(root_doc, "existing.txt", file_uuid)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(store, root, update, nil)

      # Now modify the file
      File.write!(Path.join(dir, "existing.txt"), "modified")

      changes = Watcher.detect_changes(root, dir, store)

      modified = Enum.filter(changes, &(&1.type == :modified))
      assert length(modified) == 1
      assert hd(modified).name == "existing.txt"
    end

    test "detects a deleted file", %{store: store, watch_dir: dir, root_uuid: root} do
      # Register a file in the schema but don't create it on disk
      file_uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "gone.txt")
      doc = ContentType.insert_text(doc, 0, "was here")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, file_uuid, update, nil)

      root_doc = load_schema(root, store)
      root_doc = Schema.add_file(root_doc, "gone.txt", file_uuid)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(store, root, update, nil)

      changes = Watcher.detect_changes(root, dir, store)

      deleted = Enum.filter(changes, &(&1.type == :deleted))
      assert length(deleted) == 1
      assert hd(deleted).name == "gone.txt"
    end

    test "detects a new subdirectory", %{store: store, watch_dir: dir, root_uuid: root} do
      File.mkdir_p!(Path.join(dir, "newdir"))

      changes = Watcher.detect_changes(root, dir, store)

      assert length(changes) == 1
      [change] = changes
      assert change.type == :created
      assert change.name == "newdir"
      assert change.is_dir == true
    end

    test "no changes when disk matches schema", %{store: store, watch_dir: dir, root_uuid: root} do
      # Create a file on disk and in schema
      File.write!(Path.join(dir, "synced.txt"), "content")
      file_uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "synced.txt")
      doc = ContentType.insert_text(doc, 0, "content")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, file_uuid, update, nil)

      root_doc = load_schema(root, store)
      root_doc = Schema.add_file(root_doc, "synced.txt", file_uuid)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(store, root, update, nil)

      changes = Watcher.detect_changes(root, dir, store)

      # No changes when content matches
      assert changes == []
    end

    # CX-3ine: Sync.Agent must NOT auto-create schema entries for
    # honorific-extension files (.bot/.exe/.usr/.who) sitting on disk.
    # Those files are owned by the running actor process. The previous
    # behavior re-resurrected reaped presence entries each tick,
    # producing a 1Hz commit storm that pegged serve at ~94% CPU
    # (manifested during workspace MCP smoke testing 2026-04-25).
    test "ignores honorific presence files on disk (CX-3ine)",
         %{store: store, watch_dir: dir, root_uuid: root} do
      # Create one regular file and four honorific files.
      File.write!(Path.join(dir, "regular.txt"), "user data")
      File.write!(Path.join(dir, "claude-code.bot"), "")
      File.write!(Path.join(dir, "executable.exe"), "")
      File.write!(Path.join(dir, "alice.usr"), "")
      File.write!(Path.join(dir, "agent.who"), "")

      changes = Watcher.detect_changes(root, dir, store)

      # Only regular.txt should appear as a change. Honorific files are
      # filtered out — Watcher behaves as if they aren't on disk at all.
      assert length(changes) == 1
      [change] = changes
      assert change.type == :created
      assert change.name == "regular.txt"
    end
  end

  describe "apply_changes/4" do
    test "syncs a new file into CRDT", %{store: store, watch_dir: dir, root_uuid: root} do
      File.write!(Path.join(dir, "new.txt"), "new content")

      changes = Watcher.detect_changes(root, dir, store)
      Watcher.apply_changes(changes, root, dir, store)

      # Verify schema was updated
      root_doc = load_schema(root, store)
      {:ok, entry} = Schema.get_entry(root_doc, "new.txt")
      assert entry.type == :doc

      # Verify document content
      {:ok, commit} = CommitStore.latest_commit(store, entry.node_id)
      doc = Yelixer.Doc.new()
      {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
      assert ContentType.get_content(doc) == "new content"
    end

    test "syncs a modified file", %{store: store, watch_dir: dir, root_uuid: root} do
      # Setup: synced file with "original"
      File.write!(Path.join(dir, "file.txt"), "original")
      file_uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "file.txt")
      doc = ContentType.insert_text(doc, 0, "original")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, file_uuid, update, nil)

      root_doc = load_schema(root, store)
      root_doc = Schema.add_file(root_doc, "file.txt", file_uuid)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(store, root, update, nil)

      # Modify on disk
      File.write!(Path.join(dir, "file.txt"), "modified content")

      changes = Watcher.detect_changes(root, dir, store)
      Watcher.apply_changes(changes, root, dir, store)

      # Verify updated content
      {:ok, commit} = CommitStore.latest_commit(store, file_uuid)
      doc = Yelixer.Doc.new()
      {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
      assert ContentType.get_content(doc) == "modified content"
    end
  end

  describe "stable client_id (CX-pyi)" do
    test "100 file modifications keep state vector at one client and preserve latest content",
         %{store: store, watch_dir: dir, root_uuid: root} do
      File.write!(Path.join(dir, "churn.txt"), "v0")
      changes = Watcher.detect_changes(root, dir, store)
      Watcher.apply_changes(changes, root, dir, store)

      root_doc = load_schema(root, store)
      {:ok, entry} = Schema.get_entry(root_doc, "churn.txt")
      file_uuid = entry.node_id

      for n <- 1..100 do
        File.write!(Path.join(dir, "churn.txt"), "v#{n}")
        changes = Watcher.detect_changes(root, dir, store)
        Watcher.apply_changes(changes, root, dir, store)
      end

      {:ok, doc} = Commonplace.Tree.DocBuilder.reconstruct_doc(store, file_uuid)
      sv = Yelixer.BlockStore.state_vector(doc.store)

      assert map_size(sv.clocks) == 1,
             "after 100 modifies the state vector should have a single stable client_id, got #{map_size(sv.clocks)}: #{inspect(Map.keys(sv.clocks))}"

      expected_client_id = :erlang.phash2(file_uuid, 0xFFFF_FFFF)

      assert Map.has_key?(sv.clocks, expected_client_id),
             "state vector missing phash2-derived client_id #{expected_client_id}"

      # Latest content survives load+mutate diff application.
      assert ContentType.get_content(doc) == "v100"
    end
  end

  describe "crash containment (CX-42no)" do
    test "permission-denied file is skipped; other files still sync",
         %{store: store, watch_dir: dir, root_uuid: root} do
      File.write!(Path.join(dir, "ok.txt"), "fine")
      bad_path = Path.join(dir, "bad.txt")
      File.write!(bad_path, "secret")
      File.chmod!(bad_path, 0o000)
      on_exit(fn -> File.chmod(bad_path, 0o644) end)

      if root_bypasses_perms?(bad_path) do
        # Running as root (or on a filesystem that ignores the mode bits) —
        # chmod 0o000 doesn't actually deny reads here, so this scenario
        # can't be exercised in this environment. Nothing to assert.
        :ok
      else
        changes = Watcher.detect_changes(root, dir, store)
        assert Enum.any?(changes, &(&1.name == "ok.txt"))

        # Must not raise even though bad.txt can't be read.
        Watcher.apply_changes(changes, root, dir, store)

        root_doc = load_schema(root, store)
        assert {:ok, _entry} = Schema.get_entry(root_doc, "ok.txt")
        assert :error = Schema.get_entry(root_doc, "bad.txt")
      end
    end

    test "symlinked directory cycle does not hang or crash recursion",
         %{store: store, watch_dir: dir, root_uuid: root} do
      loop_dir = Path.join(dir, "loop")
      File.mkdir_p!(loop_dir)
      File.write!(Path.join(loop_dir, "inside.txt"), "hi")
      # dir/loop/self -> dir/loop : a directory symlink cycle
      File.ln_s!(loop_dir, Path.join(loop_dir, "self"))

      task = Task.async(fn -> Watcher.sync_recursive(root, dir, store) end)
      result = Task.yield(task, 5_000) || Task.shutdown(task)

      assert match?({:ok, _}, result),
             "sync_recursive hung or crashed on a symlink cycle: #{inspect(result)}"

      # The non-cyclic content still made it in.
      root_doc = load_schema(root, store)
      {:ok, loop_entry} = Schema.get_entry(root_doc, "loop")
      loop_schema = load_schema(loop_entry.node_id, store)
      assert {:ok, _} = Schema.get_entry(loop_schema, "inside.txt")
    end
  end

  defp root_bypasses_perms?(path) do
    case File.read(path) do
      {:ok, _} -> true
      {:error, _} -> false
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
