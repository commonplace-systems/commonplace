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

    # exclude_names must be symmetric: a name in the exclude list is
    # invisible to the diff in BOTH directions. Previously it was applied
    # only to the disk listing, so a substrate-minted schema entry with no
    # on-disk counterpart perpetually surfaced as :deleted and blocked
    # sync-flush completeness (measured on the "bd" entry).
    test "excluded schema-only entry produces no :deleted change",
         %{store: store, watch_dir: dir, root_uuid: root} do
      add_schema_file(store, root, "minted", "substrate data")

      changes = Watcher.detect_changes(root, dir, store, exclude_names: ["minted"])

      assert changes == []
    end

    # CONTROL: the same setup without the exclude still reports :deleted.
    test "non-excluded schema-only entry still produces a :deleted change",
         %{store: store, watch_dir: dir, root_uuid: root} do
      add_schema_file(store, root, "minted", "substrate data")

      changes = Watcher.detect_changes(root, dir, store)

      assert [%{type: :deleted, name: "minted"}] = changes
    end

    test "excluded name present on disk AND in schema produces no :modified change",
         %{store: store, watch_dir: dir, root_uuid: root} do
      add_schema_file(store, root, "minted", "crdt content")
      File.write!(Path.join(dir, "minted"), "different disk content")

      changes = Watcher.detect_changes(root, dir, store, exclude_names: ["minted"])

      assert changes == []
    end
  end

  describe "sync_recursive/4 exclusions" do
    test "does not recurse into an excluded schema dir entry",
         %{store: store, watch_dir: dir, root_uuid: root} do
      # A schema dir entry named "bd" whose child schema holds a file that
      # does not exist on disk. If sync_recursive descended into it, that
      # child would be deleted from the child schema.
      sub_uuid = UUID.uuid4()
      sub_doc = Schema.new_schema()
      sub_doc = Schema.add_file(sub_doc, "inner.txt", UUID.uuid4())
      CommitStore.create_commit(store, sub_uuid, Yelixer.Encoding.encode_update(sub_doc), nil)

      root_doc = load_schema(root, store)
      root_doc = Schema.add_directory(root_doc, "bd", sub_uuid)
      CommitStore.create_commit(store, root, Yelixer.Encoding.encode_update(root_doc), nil)

      # The directory exists on disk (so recursion would be attempted).
      File.mkdir_p!(Path.join(dir, "bd"))

      Watcher.sync_recursive(root, dir, store, exclude_names: ["bd"])

      # Root schema still has "bd", and the child schema is untouched.
      assert {:ok, _} = Schema.get_entry(load_schema(root, store), "bd")
      assert {:ok, _} = Schema.get_entry(load_schema(sub_uuid, store), "inner.txt")
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

  describe "binary artifact references and the S1 floor" do
    test "an invalid-UTF8 binary among text files lands by measured classification",
         %{store: store, watch_dir: dir, root_uuid: root} do
      text_path = Path.join(dir, "landed.txt")
      binary_path = Path.join(dir, "excluded.bin")
      File.write!(text_path, "land me")
      File.write!(binary_path, <<0xFF, 0xFE, 0x00>>)

      report = Watcher.sync_recursive(root, dir, store)

      assert report.encountered == Enum.sort([text_path, binary_path])
      assert report.landed == Enum.sort([text_path, binary_path])
      assert report.refused == []
      assert report.skipped == []

      root_doc = load_schema(root, store)
      assert {:ok, _entry} = Schema.get_entry(root_doc, "landed.txt")
      assert {:ok, binary_entry} = Schema.get_entry(root_doc, "excluded.bin")

      {:ok, binary_doc} =
        Commonplace.Tree.DocBuilder.reconstruct_doc(store, binary_entry.node_id, mint: false)

      assert ContentType.get_type(binary_doc) == :binary
      assert ContentType.get_content(binary_doc).classified_by == :invalid_utf8
    end

    test "modifying a text file to binary replaces text with an artifact envelope",
         %{store: store, watch_dir: dir, root_uuid: root} do
      path = Path.join(dir, "kept.txt")
      File.write!(path, "original")
      Watcher.sync_recursive(root, dir, store)

      root_doc = load_schema(root, store)
      {:ok, entry} = Schema.get_entry(root_doc, "kept.txt")
      {:ok, before_commit} = CommitStore.latest_commit(store, entry.node_id)

      File.write!(path, <<0x80, 0x81>>)
      report = Watcher.sync_recursive(root, dir, store)

      assert report.encountered == [path]
      assert report.landed == [path]
      assert report.refused == []
      assert report.skipped == []

      assert {:ok, after_commit} = CommitStore.latest_commit(store, entry.node_id)
      refute after_commit.id == before_commit.id

      doc = Yelixer.Doc.new()
      assert {:ok, doc} = Yelixer.Encoding.apply_update(doc, after_commit.update)
      assert ContentType.get_type(doc) == :binary
      assert ContentType.get_content(doc).classified_by == :invalid_utf8
    end

    test "an all-text pass reports every arrived file as landed",
         %{store: store, watch_dir: dir, root_uuid: root} do
      first = Path.join(dir, "first.txt")
      second = Path.join(dir, "second.txt")
      File.write!(first, "first")
      File.write!(second, "second")

      report = Watcher.sync_recursive(root, dir, store)

      assert report.encountered == Enum.sort([first, second])
      assert report.landed == Enum.sort([first, second])
      assert report.refused == []
      assert report.skipped == []
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

  # Register a text doc under `name` in the schema at `root` (no disk file).
  defp add_schema_file(store, root, name, content) do
    file_uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = ContentType.insert_text(doc, 0, content)
    CommitStore.create_commit(store, file_uuid, Yelixer.Encoding.encode_update(doc), nil)

    root_doc = load_schema(root, store)
    root_doc = Schema.add_file(root_doc, name, file_uuid)
    CommitStore.create_commit(store, root, Yelixer.Encoding.encode_update(root_doc), nil)
    file_uuid
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
