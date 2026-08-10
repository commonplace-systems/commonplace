defmodule Commonplace.MCP.Tools.ListPeersTest do
  @moduledoc """
  CX-6sf2.5 (B3): `list_peers` MCP tool — the substrate-native roster of
  visible actors (presence docs), replacing clod-squad's SQLite peer
  registry.

  Follows the isolated-store setup pattern from `loom_test.exs`: per-test
  scratch data_dir + CommitStore restart, root schema doc bootstrapped
  with a fresh UUID written to `<dir>/root` (what `Workspace.root_uuid/0`
  reads). Presence docs are seeded directly on the root schema via
  `Commonplace.Presence.create/4` — the same root-level, non-recursive
  scope `Commonplace.CLI.Who` and `Commonplace.Presence.Reaper` already
  use for hot-presence discovery.
  """
  use ExUnit.Case, async: false

  alias Commonplace.MCP.Tools
  alias Commonplace.MCP.Tools.ListPeers
  alias Commonplace.Presence
  alias Commonplace.Presence.Reaper
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_list_peers_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} = Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"})

      Commonplace.Tree.DocCache.clear()
      File.rm_rf!(dir)
    end)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, update, nil)

    Commonplace.Test.WorkspaceFixture.complete_workspace!(dir,
      store: Commonplace.Store.CommitStore
    )

    File.write!(Path.join(dir, "root"), root_uuid)

    %{root: root_uuid}
  end

  # Directly overwrite a presence doc's heartbeat with an arbitrary
  # ISO8601 timestamp (past or future) so tests can exercise staleness
  # without sleeping. Mirrors `Presence.heartbeat/2` but with a caller-
  # supplied timestamp instead of `DateTime.utc_now/0`.
  defp set_heartbeat(uuid, iso8601, store) do
    {:ok, commit} = CommitStoreClient.latest_commit(store, uuid)
    doc = Yelixer.Doc.new(client_id: :erlang.phash2(uuid, 0xFFFF_FFFF))
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
    doc = ContentType.set_key(doc, "heartbeat", iso8601)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(store, uuid, update)
  end

  describe "list_peers" do
    test "returns seeded actors with correct name/type", %{root: root} do
      {:ok, _bot_uuid} = Presence.create("clyde", :bot, root, CommitStoreClient)
      {:ok, _usr_uuid} = Presence.create("jes", :usr, root, CommitStoreClient)

      assert {:ok, result} = ListPeers.run(%{}, %{})
      peers = structured_payload(result)["peers"]

      assert length(peers) == 2
      by_name = Map.new(peers, &{&1["name"], &1})

      assert by_name["clyde"]["type"] == "bot"
      assert by_name["jes"]["type"] == "usr"
    end

    test "fresh heartbeat is online, stale heartbeat is offline", %{root: root} do
      {:ok, fresh_uuid} = Presence.create("fresh-bot", :bot, root, CommitStoreClient)
      {:ok, stale_uuid} = Presence.create("stale-bot", :bot, root, CommitStoreClient)

      Presence.heartbeat(fresh_uuid, CommitStoreClient)

      old =
        DateTime.utc_now() |> DateTime.add(-3 * Reaper.default_stale_threshold(), :millisecond)

      set_heartbeat(stale_uuid, DateTime.to_iso8601(old), CommitStoreClient)

      assert {:ok, result} = ListPeers.run(%{}, %{})
      peers = structured_payload(result)["peers"]
      by_name = Map.new(peers, &{&1["name"], &1})

      assert by_name["fresh-bot"]["online"] == true
      assert by_name["stale-bot"]["online"] == false
    end

    test "type filter returns only bots", %{root: root} do
      {:ok, _} = Presence.create("clyde", :bot, root, CommitStoreClient)
      {:ok, _} = Presence.create("jes", :usr, root, CommitStoreClient)

      assert {:ok, result} = ListPeers.run(%{"type" => "bot"}, %{})
      peers = structured_payload(result)["peers"]

      assert length(peers) == 1
      assert hd(peers)["name"] == "clyde"
      assert hd(peers)["type"] == "bot"
    end

    test "no presence docs returns an empty roster", %{root: _root} do
      assert {:ok, result} = ListPeers.run(%{}, %{})
      assert structured_payload(result)["peers"] == []
    end
  end

  describe "tool registry" do
    test "list_peers appears in Tools.list" do
      names = Tools.list() |> Enum.map(& &1["name"])
      assert "list_peers" in names
    end
  end

  defp structured_payload(result) do
    result["content"]
    |> Enum.at(1)
    |> Map.get("text")
    |> Jason.decode!()
  end
end
