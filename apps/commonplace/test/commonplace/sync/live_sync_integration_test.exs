defmodule Commonplace.Sync.LiveSyncIntegrationTest do
  @moduledoc """
  Integration tests proving edits flow between two directories
  through the shared CRDT store via live sync loops.

  CX-agxw: assertions poll via `eventually/2` with a 5s timeout
  instead of fixed Process.sleep. The sync cycle's latency varies
  with system load (CI runners, concurrent tests, JIT warm-up), and
  fixed sleeps flaked under ~1/10 full-suite runs when the cycle ran
  slower than the sleep window. Eventually-pattern converges as soon
  as the sync is observably complete and fails fast with the actual
  state on timeout.
  """
  use ExUnit.Case

  alias Commonplace.Sync.SyncLoop
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore

  @default_timeout_ms 5_000
  @poll_interval_ms 25

  defp eventually(fun, timeout_ms \\ @default_timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    try do
      fun.()
    rescue
      e in [ExUnit.AssertionError, File.Error, MatchError] ->
        if System.monotonic_time(:millisecond) >= deadline do
          reraise e, __STACKTRACE__
        else
          Process.sleep(@poll_interval_ms)
          do_eventually(fun, deadline)
        end
    end
  end

  setup do
    data_dir = Path.join(System.tmp_dir!(), "cp_livesync_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(data_dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: data_dir, name: store_name})

    dir_a = Path.join(System.tmp_dir!(), "cp_peer_a_#{:rand.uniform(1_000_000)}")
    dir_b = Path.join(System.tmp_dir!(), "cp_peer_b_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir_a)
    File.mkdir_p!(dir_b)

    on_exit(fn ->
      File.rm_rf!(data_dir)
      File.rm_rf!(dir_a)
      File.rm_rf!(dir_b)
    end)

    # Shared root schema
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{store: store_name, root: root_uuid, dir_a: dir_a, dir_b: dir_b}
  end

  describe "peer-to-peer sync via shared CRDT" do
    test "file created on peer A appears on peer B",
         %{store: store, root: root, dir_a: dir_a, dir_b: dir_b} do
      {:ok, loop_a} = SyncLoop.start_link(
        dir: dir_a, root_uuid: root, store: store, interval: 50
      )
      {:ok, loop_b} = SyncLoop.start_link(
        dir: dir_b, root_uuid: root, store: store, interval: 50
      )

      File.write!(Path.join(dir_a, "from_a.txt"), "hello from A")

      eventually(fn ->
        assert File.read!(Path.join(dir_b, "from_a.txt")) == "hello from A"
      end)

      GenServer.stop(loop_a)
      GenServer.stop(loop_b)
    end

    test "file created on peer B appears on peer A",
         %{store: store, root: root, dir_a: dir_a, dir_b: dir_b} do
      {:ok, loop_a} = SyncLoop.start_link(
        dir: dir_a, root_uuid: root, store: store, interval: 50
      )
      {:ok, loop_b} = SyncLoop.start_link(
        dir: dir_b, root_uuid: root, store: store, interval: 50
      )

      File.write!(Path.join(dir_b, "from_b.txt"), "hello from B")

      eventually(fn ->
        assert File.read!(Path.join(dir_a, "from_b.txt")) == "hello from B"
      end)

      GenServer.stop(loop_a)
      GenServer.stop(loop_b)
    end

    test "both peers create files and both receive each other's",
         %{store: store, root: root, dir_a: dir_a, dir_b: dir_b} do
      {:ok, loop_a} = SyncLoop.start_link(
        dir: dir_a, root_uuid: root, store: store, interval: 50
      )
      {:ok, loop_b} = SyncLoop.start_link(
        dir: dir_b, root_uuid: root, store: store, interval: 50
      )

      File.write!(Path.join(dir_a, "a_file.txt"), "from A")
      File.write!(Path.join(dir_b, "b_file.txt"), "from B")

      eventually(fn ->
        assert File.read!(Path.join(dir_a, "a_file.txt")) == "from A"
        assert File.read!(Path.join(dir_a, "b_file.txt")) == "from B"
        assert File.read!(Path.join(dir_b, "a_file.txt")) == "from A"
        assert File.read!(Path.join(dir_b, "b_file.txt")) == "from B"
      end)

      GenServer.stop(loop_a)
      GenServer.stop(loop_b)
    end

    test "file modification on one peer propagates to the other",
         %{store: store, root: root, dir_a: dir_a, dir_b: dir_b} do
      {:ok, loop_a} = SyncLoop.start_link(
        dir: dir_a, root_uuid: root, store: store, interval: 50
      )

      File.write!(Path.join(dir_a, "shared.txt"), "version 1")

      {:ok, loop_b} = SyncLoop.start_link(
        dir: dir_b, root_uuid: root, store: store, interval: 50
      )

      eventually(fn ->
        assert File.read!(Path.join(dir_b, "shared.txt")) == "version 1"
      end)

      File.write!(Path.join(dir_a, "shared.txt"), "version 2")

      eventually(fn ->
        assert File.read!(Path.join(dir_b, "shared.txt")) == "version 2"
      end)

      GenServer.stop(loop_a)
      GenServer.stop(loop_b)
    end
  end
end
