defmodule Commonplace.Presence.IdentityTest do
  @moduledoc """
  Tests for cold identity — permanent actor records in __identities/.
  """
  use ExUnit.Case

  alias Commonplace.Presence.Identity
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_identity_#{:rand.uniform(1_000_000)}")
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

  describe "ensure_identities_dir" do
    test "creates __identities__ entry in root schema", %{store: store, root: root} do
      {:ok, dir_uuid} = Identity.ensure_identities_dir(root, store)

      root_doc = load_schema(root, store)
      {:ok, entry} = Schema.get_entry(root_doc, "__identities__")
      assert entry.type == :dir
      assert entry.node_id == dir_uuid
    end

    test "returns existing dir if already created", %{store: store, root: root} do
      {:ok, uuid1} = Identity.ensure_identities_dir(root, store)
      {:ok, uuid2} = Identity.ensure_identities_dir(root, store)
      assert uuid1 == uuid2
    end
  end

  describe "register" do
    test "creates a new cold identity", %{store: store, root: root} do
      {:ok, identity_uuid} = Identity.register("sync", :exe, root, store)

      identity = Identity.read(identity_uuid, store)
      assert identity["name"] == "sync"
      assert identity["type"] == "exe"
      assert is_binary(identity["first_seen"])
      assert is_binary(identity["last_seen"])
    end

    test "identity appears in __identities__ schema", %{store: store, root: root} do
      {:ok, _uuid} = Identity.register("sync", :exe, root, store)

      {:ok, id_dir_uuid} = Identity.ensure_identities_dir(root, store)
      id_doc = load_schema(id_dir_uuid, store)
      {:ok, entry} = Schema.get_entry(id_doc, "sync.exe")
      assert entry.type == :doc
    end

    test "returns existing identity on re-register", %{store: store, root: root} do
      {:ok, uuid1} = Identity.register("sync", :exe, root, store)
      Process.sleep(10)
      {:ok, uuid2} = Identity.register("sync", :exe, root, store)

      assert uuid1 == uuid2

      # last_seen should be updated
      identity = Identity.read(uuid2, store)
      assert identity["name"] == "sync"
    end

    test "updates last_seen on re-register", %{store: store, root: root} do
      {:ok, uuid} = Identity.register("sync", :exe, root, store)
      first = Identity.read(uuid, store)

      Process.sleep(10)
      {:ok, ^uuid} = Identity.register("sync", :exe, root, store)
      second = Identity.read(uuid, store)

      assert second["first_seen"] == first["first_seen"]
      assert second["last_seen"] != first["last_seen"]
    end
  end

  describe "lookup" do
    test "finds a registered identity", %{store: store, root: root} do
      {:ok, uuid} = Identity.register("agent", :bot, root, store)

      assert {:ok, ^uuid} = Identity.lookup("agent", :bot, root, store)
    end

    test "returns :error for unregistered identity", %{store: store, root: root} do
      assert :error = Identity.lookup("ghost", :exe, root, store)
    end
  end

  describe "list" do
    test "lists all cold identities", %{store: store, root: root} do
      Identity.register("alpha", :exe, root, store)
      Identity.register("beta", :bot, root, store)
      Identity.register("jes", :usr, root, store)

      identities = Identity.list(root, store)
      assert length(identities) == 3
      names = Enum.map(identities, & &1.name) |> Enum.sort()
      assert names == ["alpha.exe", "beta.bot", "jes.usr"]
    end

    test "returns empty list when no identities", %{store: store, root: root} do
      assert Identity.list(root, store) == []
    end
  end

  describe "GenServer integration" do
    test "Presence.Server registers cold identity on start", %{store: store, root: root} do
      {:ok, pid} =
        Commonplace.Presence.Server.start_link(
          name: "coldtest",
          type: :exe,
          dir_uuid: root,
          store: store,
          heartbeat_interval: 10_000
        )

      # Cold identity should exist
      assert {:ok, _uuid} = Identity.lookup("coldtest", :exe, root, store)

      GenServer.stop(pid)
    end

    test "cold identity persists after clean shutdown", %{store: store, root: root} do
      {:ok, pid} =
        Commonplace.Presence.Server.start_link(
          name: "survivor",
          type: :exe,
          dir_uuid: root,
          store: store,
          heartbeat_interval: 10_000
        )

      GenServer.stop(pid)
      Process.sleep(50)

      # Hot presence is gone
      root_doc = load_schema(root, store)
      assert :error = Schema.get_entry(root_doc, "survivor.exe")

      # Cold identity persists
      assert {:ok, _uuid} = Identity.lookup("survivor", :exe, root, store)
    end

    test "cold identity last_seen updated on shutdown", %{store: store, root: root} do
      {:ok, pid} =
        Commonplace.Presence.Server.start_link(
          name: "timestamped",
          type: :exe,
          dir_uuid: root,
          store: store,
          heartbeat_interval: 10_000
        )

      identity_uuid = Commonplace.Presence.Server.identity_uuid(pid)
      before_stop = Identity.read(identity_uuid, store)

      Process.sleep(10)
      GenServer.stop(pid)
      Process.sleep(50)

      after_stop = Identity.read(identity_uuid, store)
      assert after_stop["last_seen"] != before_stop["last_seen"]
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
