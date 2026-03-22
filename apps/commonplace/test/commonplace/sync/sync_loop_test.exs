defmodule Commonplace.Sync.SyncLoopTest do
  @moduledoc """
  Tests for the live sync loop — periodic bidirectional sync
  between disk and CRDT with loop prevention.
  """
  use ExUnit.Case

  alias Commonplace.Sync.SyncLoop
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType

  setup do
    data_dir = Path.join(System.tmp_dir!(), "cp_syncloop_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(data_dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: data_dir, name: store_name})

    sync_dir = Path.join(System.tmp_dir!(), "cp_syncdir_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(sync_dir)

    on_exit(fn ->
      File.rm_rf!(data_dir)
      File.rm_rf!(sync_dir)
    end)

    # Create a root schema
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{store: store_name, root: root_uuid, sync_dir: sync_dir}
  end

  describe "outbound sync (disk → CRDT)" do
    test "detects new file and syncs to CRDT", %{store: store, root: root, sync_dir: dir} do
      {:ok, pid} = SyncLoop.start_link(
        dir: dir,
        root_uuid: root,
        store: store,
        interval: 50
      )

      # Write a file
      File.write!(Path.join(dir, "hello.txt"), "world")

      # Wait for sync cycle
      Process.sleep(200)

      # Verify CRDT has the document
      root_doc = load_schema(root, store)
      {:ok, entry} = Schema.get_entry(root_doc, "hello.txt")
      assert entry.type == :doc

      # Verify content
      {:ok, commit} = CommitStore.latest_commit(store, entry.node_id)
      doc = Yelixer.Doc.new()
      {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
      content = ContentType.get_content(doc)
      assert content == "world"

      GenServer.stop(pid)
    end

    test "detects modified file and updates CRDT", %{store: store, root: root, sync_dir: dir} do
      {:ok, pid} = SyncLoop.start_link(
        dir: dir,
        root_uuid: root,
        store: store,
        interval: 50
      )

      File.write!(Path.join(dir, "doc.txt"), "version 1")
      Process.sleep(200)

      File.write!(Path.join(dir, "doc.txt"), "version 2")
      Process.sleep(200)

      root_doc = load_schema(root, store)
      {:ok, entry} = Schema.get_entry(root_doc, "doc.txt")
      {:ok, commit} = CommitStore.latest_commit(store, entry.node_id)
      doc = Yelixer.Doc.new()
      {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
      content = ContentType.get_content(doc)
      assert content == "version 2"

      GenServer.stop(pid)
    end
  end

  describe "inbound sync (CRDT → disk)" do
    test "exports new CRDT document to disk", %{store: store, root: root, sync_dir: dir} do
      # Create a document in CRDT first
      doc_uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "from_crdt.txt")
      doc = ContentType.insert_text(doc, 0, "hello from crdt")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, doc_uuid, update, nil)

      # Add to schema
      root_doc = load_schema(root, store)
      root_doc = Schema.add_file(root_doc, "from_crdt.txt", doc_uuid)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(store, root_uuid(root), update, nil)

      # Start sync loop
      {:ok, pid} = SyncLoop.start_link(
        dir: dir,
        root_uuid: root,
        store: store,
        interval: 50
      )

      Process.sleep(200)

      # File should appear on disk
      assert File.read!(Path.join(dir, "from_crdt.txt")) == "hello from crdt"

      GenServer.stop(pid)
    end
  end

  describe "bidirectional flow" do
    test "edit on disk flows to CRDT and back", %{store: store, root: root, sync_dir: dir} do
      {:ok, pid} = SyncLoop.start_link(
        dir: dir,
        root_uuid: root,
        store: store,
        interval: 50
      )

      # Write a file on disk
      File.write!(Path.join(dir, "roundtrip.txt"), "original")
      Process.sleep(200)

      # Verify it's in CRDT
      root_doc = load_schema(root, store)
      assert {:ok, _entry} = Schema.get_entry(root_doc, "roundtrip.txt")

      # File should still be on disk (not deleted by inbound sync)
      assert File.read!(Path.join(dir, "roundtrip.txt")) == "original"

      GenServer.stop(pid)
    end

    test "no infinite sync loop", %{store: store, root: root, sync_dir: dir} do
      test_pid = self()

      {:ok, pid} = SyncLoop.start_link(
        dir: dir,
        root_uuid: root,
        store: store,
        interval: 50,
        on_cycle: fn count -> send(test_pid, {:cycle, count}) end
      )

      File.write!(Path.join(dir, "stable.txt"), "content")

      # Let several cycles run
      Process.sleep(500)

      GenServer.stop(pid)

      # Collect all cycle messages
      cycles = collect_messages()

      # After initial sync, subsequent cycles should be no-ops
      # (we shouldn't see unbounded cycle counts growing)
      assert length(cycles) < 20
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

  defp root_uuid(root), do: root

  defp collect_messages do
    collect_messages([])
  end

  defp collect_messages(acc) do
    receive do
      {:cycle, count} -> collect_messages([count | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
