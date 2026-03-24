defmodule Commonplace.Sync.AgentTest do
  @moduledoc """
  Tests for the bidirectional sync agent.

  The sync agent watches both disk and CRDT for changes:
  - Outbound: disk changes → detect → lock → read → diff → commit
  - Inbound: CRDT update (PubSub) → ancestry check → lock → atomic write
  """
  use ExUnit.Case

  alias Commonplace.Sync.{Agent, Export}
  alias Commonplace.Tree.{Schema, Walk}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Dataflow.PubSub, as: CPPubSub

  setup do
    store_dir = Path.join(System.tmp_dir!(), "cp_agent_store_#{:rand.uniform(1_000_000)}")
    sync_dir = Path.join(System.tmp_dir!(), "cp_agent_sync_#{:rand.uniform(1_000_000)}")
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

    %{
      store: store_name,
      sync_dir: sync_dir,
      root: root_uuid
    }
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

  describe "outbound sync (disk → CRDT)" do
    test "new file on disk is synced to CRDT", %{store: store, sync_dir: dir, root: root} do
      File.write!(Path.join(dir, "new.txt"), "new content")

      {:ok, pid} = Agent.start_link(
        root_uuid: root,
        sync_dir: dir,
        store: store
      )

      Agent.sync_once(pid)

      load = loader(store)
      {:ok, uuid} = Walk.resolve_path(root, "new.txt", load)
      assert read_content(uuid, store) == "new content"
    end

    test "modified file on disk is synced to CRDT", %{store: store, sync_dir: dir, root: root} do
      # Setup: create file and sync it
      File.write!(Path.join(dir, "file.txt"), "original")

      {:ok, pid} = Agent.start_link(
        root_uuid: root,
        sync_dir: dir,
        store: store
      )

      Agent.sync_once(pid)

      load = loader(store)
      {:ok, uuid} = Walk.resolve_path(root, "file.txt", load)
      assert read_content(uuid, store) == "original"

      # Modify and sync again
      File.write!(Path.join(dir, "file.txt"), "updated")
      Agent.sync_once(pid)

      assert read_content(uuid, store) == "updated"
    end

    test "deleted file on disk is removed from schema", %{store: store, sync_dir: dir, root: root} do
      File.write!(Path.join(dir, "temp.txt"), "temporary")

      {:ok, pid} = Agent.start_link(
        root_uuid: root,
        sync_dir: dir,
        store: store
      )

      Agent.sync_once(pid)

      load = loader(store)
      {:ok, _} = Walk.resolve_path(root, "temp.txt", load)

      File.rm!(Path.join(dir, "temp.txt"))
      Agent.sync_once(pid)

      assert {:error, {:not_found, "temp.txt"}} = Walk.resolve_path(root, "temp.txt", load)
    end
  end

  describe "inbound sync (CRDT → disk)" do
    test "CRDT document change is written to disk", %{store: store, sync_dir: dir, root: root} do
      # Create a document in CRDT directly
      file_uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "from_crdt.txt")
      doc = ContentType.insert_text(doc, 0, "from CRDT\n")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, file_uuid, update, nil)

      # Add to schema
      root_doc = loader(store).(root)
      root_doc = Schema.add_file(root_doc, "from_crdt.txt", file_uuid)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(store, root, update, nil)

      {:ok, pid} = Agent.start_link(
        root_uuid: root,
        sync_dir: dir,
        store: store
      )

      # Export phase of sync should write to disk
      Agent.sync_once(pid)

      assert File.read!(Path.join(dir, "from_crdt.txt")) == "from CRDT\n"
    end
  end

  describe "bidirectional" do
    test "edits on disk and CRDT both appear after sync", %{store: store, sync_dir: dir, root: root} do
      # Start with two files
      File.write!(Path.join(dir, "disk_file.txt"), "from disk")

      {:ok, pid} = Agent.start_link(
        root_uuid: root,
        sync_dir: dir,
        store: store
      )

      Agent.sync_once(pid)

      # Now add a CRDT-side document
      crdt_uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "crdt_file.txt")
      doc = ContentType.insert_text(doc, 0, "from crdt")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, crdt_uuid, update, nil)

      root_doc = loader(store).(root)
      root_doc = Schema.add_file(root_doc, "crdt_file.txt", crdt_uuid)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(store, root, update, nil)

      # Also edit disk_file.txt on disk
      File.write!(Path.join(dir, "disk_file.txt"), "from disk (edited)")

      Agent.sync_once(pid)

      # Both changes should be reflected
      load = loader(store)
      {:ok, disk_uuid} = Walk.resolve_path(root, "disk_file.txt", load)
      assert read_content(disk_uuid, store) == "from disk (edited)"
      assert File.read!(Path.join(dir, "crdt_file.txt")) == "from crdt"
    end

    test "sync is idempotent", %{store: store, sync_dir: dir, root: root} do
      File.write!(Path.join(dir, "stable.txt"), "stable")

      {:ok, pid} = Agent.start_link(
        root_uuid: root,
        sync_dir: dir,
        store: store
      )

      Agent.sync_once(pid)
      Agent.sync_once(pid)
      Agent.sync_once(pid)

      load = loader(store)
      {:ok, uuid} = Walk.resolve_path(root, "stable.txt", load)
      assert read_content(uuid, store) == "stable"
      assert File.read!(Path.join(dir, "stable.txt")) == "stable"
    end
  end
end
