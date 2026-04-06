defmodule Commonplace.Green.BursarTest do
  use ExUnit.Case, async: false

  alias Commonplace.Store.CommitStore
  alias Commonplace.Green.Bursar
  alias Commonplace.Tree.Schema
  alias Commonplace.Tree.DocBuilder
  alias Commonplace.Dataflow.RedLog

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bursar_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"bursar_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    # Create root schema
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{store: store_name, root: root_uuid, dir: dir}
  end

  defp start_bursar(ctx, name \\ nil, opts \\ []) do
    name = name || :"bursar_#{:rand.uniform(1_000_000)}"
    {:ok, pid} = Bursar.start_link(
      [root_uuid: ctx.root,
       store: ctx.store,
       name: name] ++ opts
    )
    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)
    {pid, name}
  end

  describe "acquire/release basics" do
    test "acquire available token succeeds", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, info} = Bursar.acquire(name, "readme.txt", "alice")
      assert info.holder == "alice"
      assert %DateTime{} = info.acquired_at
    end

    test "acquire held token is denied", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice")
      assert {:denied, %{holder: "alice"}} = Bursar.acquire(name, "readme.txt", "bob")
    end

    test "acquire is idempotent for same holder", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, info1} = Bursar.acquire(name, "readme.txt", "alice")
      assert {:ok, info2} = Bursar.acquire(name, "readme.txt", "alice")
      assert info1.acquired_at == info2.acquired_at
    end

    test "release held token succeeds", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice")
      assert :ok = Bursar.release(name, "readme.txt", "alice")
    end

    test "release by non-holder fails", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice")
      assert {:error, {:not_holder, "alice"}} = Bursar.release(name, "readme.txt", "bob")
    end

    test "release unheld token fails", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:error, :not_held} = Bursar.release(name, "readme.txt", "alice")
    end

    test "token available after release", ctx do
      {_pid, name} = start_bursar(ctx)

      Bursar.acquire(name, "readme.txt", "alice")
      Bursar.release(name, "readme.txt", "alice")
      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "bob")
    end
  end

  describe "query" do
    test "query available token", ctx do
      {_pid, name} = start_bursar(ctx)

      assert :available = Bursar.query(name, "readme.txt")
    end

    test "query held token", ctx do
      {_pid, name} = start_bursar(ctx)

      Bursar.acquire(name, "readme.txt", "alice")
      assert {:held, %{holder: "alice"}} = Bursar.query(name, "readme.txt")
    end
  end

  describe "list_tokens" do
    test "lists all held tokens", ctx do
      {_pid, name} = start_bursar(ctx)

      Bursar.acquire(name, "a.txt", "alice")
      Bursar.acquire(name, "b.txt", "bob")

      tokens = Bursar.list_tokens(name)
      assert map_size(tokens) == 2
      assert tokens["a.txt"].holder == "alice"
      assert tokens["b.txt"].holder == "bob"
    end
  end

  describe "force_release" do
    test "force-releases a held token", ctx do
      {_pid, name} = start_bursar(ctx)

      Bursar.acquire(name, "readme.txt", "alice")
      assert :ok = Bursar.force_release(name, "readme.txt")
      assert :available = Bursar.query(name, "readme.txt")
    end

    test "force_release on unheld token fails", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:error, :not_held} = Bursar.force_release(name, "readme.txt")
    end
  end

  describe "persistence across restarts" do
    test "tokens survive restart", ctx do
      {pid, _name} = start_bursar(ctx, :persist_test)

      Bursar.acquire(:persist_test, "readme.txt", "alice")
      Bursar.acquire(:persist_test, "docs/guide.md", "bob")
      GenServer.stop(pid)

      # Start a new bursar with the same root — should reload tokens
      {:ok, _pid2} = Bursar.start_link(
        root_uuid: ctx.root,
        store: ctx.store,
        name: :persist_test2
      )

      tokens = Bursar.list_tokens(:persist_test2)
      assert tokens["readme.txt"].holder == "alice"
      assert tokens["docs/guide.md"].holder == "bob"

      GenServer.stop(:persist_test2)
    end
  end

  describe "multiple independent tokens" do
    test "different paths are independent", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, _} = Bursar.acquire(name, "a.txt", "alice")
      assert {:ok, _} = Bursar.acquire(name, "b.txt", "bob")
      assert {:denied, _} = Bursar.acquire(name, "a.txt", "bob")
      assert {:ok, _} = Bursar.acquire(name, "c.txt", "bob")
    end
  end

  describe "TTL expiry" do
    test "acquire with TTL stores ttl_ms", ctx do
      {_pid, name} = start_bursar(ctx, nil, sweep_interval: 60_000)

      assert {:ok, info} = Bursar.acquire(name, "readme.txt", "alice", ttl: 5000)
      assert info.ttl_ms == 5000
    end

    test "acquire without TTL has nil ttl_ms", ctx do
      {_pid, name} = start_bursar(ctx, nil, sweep_interval: 60_000)

      assert {:ok, info} = Bursar.acquire(name, "readme.txt", "alice")
      assert info.ttl_ms == nil
    end

    test "expired token is released by sweep", ctx do
      {pid, name} = start_bursar(ctx, nil, sweep_interval: 60_000)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice", ttl: 100)
      Process.sleep(200)
      send(pid, :sweep_ttl)
      # Give the GenServer time to process the sweep message
      Process.sleep(50)

      assert :available = Bursar.query(name, "readme.txt")
    end

    test "non-expired token survives sweep", ctx do
      {pid, name} = start_bursar(ctx, nil, sweep_interval: 60_000)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice", ttl: 10_000)
      send(pid, :sweep_ttl)
      # Give the GenServer time to process the sweep message
      Process.sleep(50)

      assert {:held, %{holder: "alice"}} = Bursar.query(name, "readme.txt")
    end

    test "expired token logs an event", ctx do
      {pid, name} = start_bursar(ctx, nil, sweep_interval: 60_000)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice", ttl: 100)
      Process.sleep(200)
      send(pid, :sweep_ttl)
      # Give the GenServer time to process the sweep message
      Process.sleep(50)

      # Read the red log by finding the __bursar.log UUID from the root schema
      {:ok, schema} = DocBuilder.reconstruct_snapshot(ctx.store, ctx.root)
      {:ok, log_entry} = Schema.get_entry(schema, "__bursar.log")
      log = RedLog.load(log_entry.node_id, ctx.store)
      events = RedLog.read(log)

      expired_events = Enum.filter(events, fn e -> e["event"] == "expired" end)
      assert length(expired_events) >= 1

      expired_event = List.last(expired_events)
      assert expired_event["path"] == "readme.txt"
      assert expired_event["holder"] == "alice"
      assert expired_event["ttl_ms"] == 100
    end
  end
end
