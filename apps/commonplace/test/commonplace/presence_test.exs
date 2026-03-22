defmodule Commonplace.PresenceTest do
  @moduledoc """
  Tests for presence files — actor business cards in the document tree.
  """
  use ExUnit.Case

  alias Commonplace.Presence
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_presence_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    # Create a root schema
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{store: store_name, root: root_uuid}
  end

  describe "honorific extensions" do
    test "parses actor types" do
      assert Presence.parse_honorific("sync.exe") == {:ok, "sync", :exe}
      assert Presence.parse_honorific("jes.usr") == {:ok, "jes", :usr}
      assert Presence.parse_honorific("bartleby.bot") == {:ok, "bartleby", :bot}
      assert Presence.parse_honorific("unknown.who") == {:ok, "unknown", :who}
    end

    test "rejects invalid extensions" do
      assert Presence.parse_honorific("file.txt") == :error
      assert Presence.parse_honorific("noext") == :error
    end

    test "builds filename from name and type" do
      assert Presence.filename("sync", :exe) == "sync.exe"
      assert Presence.filename("jes", :usr) == "jes.usr"
      assert Presence.filename("claude", :bot) == "claude.bot"
    end
  end

  describe "creating presence" do
    test "creates a presence document in the schema", %{store: store, root: root} do
      {:ok, uuid} = Presence.create("myprocess", :exe, root, store)

      # Verify schema entry exists
      root_doc = load_schema(root, store)
      {:ok, entry} = Schema.get_entry(root_doc, "myprocess.exe")
      assert entry.type == :doc
      assert entry.node_id == uuid

      # Verify presence doc content
      {:ok, commit} = CommitStore.latest_commit(store, uuid)
      doc = Yelixer.Doc.new()
      {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
      content = Commonplace.Document.ContentType.get_content(doc)
      assert content["name"] == "myprocess"
      assert content["type"] == "exe"
      assert content["status"] == "starting"
      assert is_binary(content["started_at"])
    end

    test "handles name collision with hash suffix", %{store: store, root: root} do
      {:ok, _uuid1} = Presence.create("sync", :exe, root, store)
      {:ok, _uuid2} = Presence.create("sync", :exe, root, store)

      root_doc = load_schema(root, store)
      entries = Schema.list_entries(root_doc)
      exe_entries = Enum.filter(entries, &String.ends_with?(&1.name, ".exe"))

      assert length(exe_entries) == 2
      names = Enum.map(exe_entries, & &1.name) |> Enum.sort()
      # One should be "sync.exe", the other "sync-XXX.exe"
      assert Enum.any?(names, &(&1 == "sync.exe"))
      assert Enum.any?(names, &(&1 != "sync.exe" and String.starts_with?(&1, "sync-")))
    end
  end

  describe "reading presence" do
    test "reads presence status", %{store: store, root: root} do
      {:ok, uuid} = Presence.create("agent", :bot, root, store)

      status = Presence.read(uuid, store)
      assert status["name"] == "agent"
      assert status["type"] == "bot"
      assert status["status"] == "starting"
    end

    test "updates presence status", %{store: store, root: root} do
      {:ok, uuid} = Presence.create("worker", :exe, root, store)

      Presence.update_status(uuid, "running", store)

      status = Presence.read(uuid, store)
      assert status["status"] == "running"
    end

    test "updates heartbeat", %{store: store, root: root} do
      {:ok, uuid} = Presence.create("worker", :exe, root, store)

      initial = Presence.read(uuid, store)
      Process.sleep(10)
      Presence.heartbeat(uuid, store)

      updated = Presence.read(uuid, store)
      assert updated["heartbeat"] != initial["heartbeat"]
    end
  end

  describe "discovery" do
    test "discover actors by type", %{store: store, root: root} do
      Presence.create("alpha", :exe, root, store)
      Presence.create("beta", :exe, root, store)
      Presence.create("jes", :usr, root, store)

      root_doc = load_schema(root, store)

      exes = Presence.discover(root_doc, :exe)
      assert length(exes) == 2

      usrs = Presence.discover(root_doc, :usr)
      assert length(usrs) == 1
      assert hd(usrs).name == "jes.usr"

      all = Presence.discover(root_doc, :all)
      assert length(all) == 3
    end
  end

  describe "cleanup" do
    test "removes presence from schema", %{store: store, root: root} do
      {:ok, _uuid} = Presence.create("temp", :exe, root, store)

      root_doc = load_schema(root, store)
      assert {:ok, _} = Schema.get_entry(root_doc, "temp.exe")

      Presence.remove("temp.exe", root, store)

      root_doc = load_schema(root, store)
      assert :error = Schema.get_entry(root_doc, "temp.exe")
    end
  end

  describe "presence GenServer" do
    test "starts and creates presence doc", %{store: store, root: root} do
      {:ok, pid} =
        Presence.Server.start_link(
          name: "liveprocess",
          type: :exe,
          dir_uuid: root,
          store: store,
          heartbeat_interval: 100
        )

      assert Process.alive?(pid)

      # Presence should be in the schema
      root_doc = load_schema(root, store)
      entries = Schema.list_entries(root_doc)
      exe_names = Enum.filter(entries, &String.ends_with?(&1.name, ".exe")) |> Enum.map(& &1.name)
      assert "liveprocess.exe" in exe_names

      GenServer.stop(pid)
    end

    test "heartbeats update the presence doc", %{store: store, root: root} do
      {:ok, pid} =
        Presence.Server.start_link(
          name: "heartbeater",
          type: :exe,
          dir_uuid: root,
          store: store,
          heartbeat_interval: 50
        )

      uuid = Presence.Server.uuid(pid)
      initial = Presence.read(uuid, store)

      # Wait for at least one heartbeat
      Process.sleep(100)

      updated = Presence.read(uuid, store)
      assert updated["heartbeat"] != initial["heartbeat"]

      GenServer.stop(pid)
    end

    test "clean shutdown removes presence", %{store: store, root: root} do
      {:ok, pid} =
        Presence.Server.start_link(
          name: "cleanstop",
          type: :exe,
          dir_uuid: root,
          store: store,
          heartbeat_interval: 1000
        )

      GenServer.stop(pid)
      Process.sleep(50)

      root_doc = load_schema(root, store)
      assert :error = Schema.get_entry(root_doc, "cleanstop.exe")
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
