defmodule Commonplace.Green.BursarClientTest do
  use ExUnit.Case, async: false

  alias Commonplace.Green.{Bursar, BursarClient}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bursar_client_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"bursar_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    root_uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    name = :"bursar_#{:rand.uniform(1_000_000)}"

    {:ok, pid} =
      Bursar.start_link(
        root_uuid: root_uuid,
        store: store_name,
        name: name,
        sweep_interval: 60_000
      )

    on_exit(fn ->
      if Process.alive?(pid),
        do:
          (try do
             GenServer.stop(pid)
           catch
             (:exit, _ -> :ok)
           end)
    end)

    %{bursar: name}
  end

  describe "local dispatch (no remote node set)" do
    test "acquire/query/release round-trip", %{bursar: b} do
      assert {:ok, %{holder: "alice"}} = BursarClient.acquire(b, "a.txt", "alice")
      assert {:held, %{holder: "alice"}} = BursarClient.query(b, "a.txt")
      assert {:denied, %{holder: "alice"}} = BursarClient.acquire(b, "a.txt", "bob")
      assert :ok = BursarClient.release(b, "a.txt", "alice")
      assert :available = BursarClient.query(b, "a.txt")
    end

    test "acquire threads ttl through", %{bursar: b} do
      assert {:ok, %{ttl_ms: 5000}} = BursarClient.acquire(b, "a.txt", "alice", ttl: 5000)
    end

    test "transfer and renew delegate", %{bursar: b} do
      assert {:ok, _} = BursarClient.acquire(b, "a.txt", "alice", ttl: 5000)
      assert {:ok, %{holder: "bob"}} = BursarClient.transfer(b, "a.txt", "alice", "bob")
      assert {:ok, %{ttl_ms: 9000}} = BursarClient.renew(b, "a.txt", "bob", ttl: 9000)
    end

    test "list_tokens and force_release delegate", %{bursar: b} do
      assert {:ok, _} = BursarClient.acquire(b, "a.txt", "alice")
      assert %{"a.txt" => %{holder: "alice"}} = BursarClient.list_tokens(b)
      assert :ok = BursarClient.force_release(b, "a.txt")
      assert :available = BursarClient.query(b, "a.txt")
    end
  end

  describe "fail-closed when no bursar is reachable" do
    # Q6 / B3: a node with no local Bursar and no remote serve must get a
    # clean denial, not a crash — TickBot degrades to idle, World.move
    # fails closed. This is exactly the bare-mix-run temp-node case.
    test "acquire returns {:error, :bursar_unavailable}" do
      assert {:error, :bursar_unavailable} =
               BursarClient.acquire(:no_such_bursar, "a.txt", "alice")
    end

    test "release/renew/query return {:error, :bursar_unavailable}" do
      assert {:error, :bursar_unavailable} =
               BursarClient.release(:no_such_bursar, "a.txt", "alice")

      assert {:error, :bursar_unavailable} =
               BursarClient.renew(:no_such_bursar, "a.txt", "alice")

      assert {:error, :bursar_unavailable} = BursarClient.query(:no_such_bursar, "a.txt")
    end
  end
end
