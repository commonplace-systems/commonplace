defmodule Commonplace.Chat.ComputeRehydratorTest do
  @moduledoc """
  CX-tdkq.3 (architecture-review R3): computed views must survive a BEAM
  restart without a human remembering them. ViewComputes are otherwise
  started lazily on LiveView mount only, so a reboot leaves every room's
  `_view.xml` frozen until someone happens to open it.

  `ComputeRehydrator.rehydrate/2` is the boot-time scan: enumerate the
  `/chat` rooms declared in the substrate and `ensure_started` each one's
  compute. The supervised GenServer wrapper (driven on boot, workspace-
  gated like the presence Reaper) is what makes it automatic.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Chat.{ComputeRehydrator, ChatViewComputeSupervisor, Rooms}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  # Restart the production-named CommitStore against a scratch dir — the
  # rehydrator and ChatViewComputeSupervisor both operate on the singleton
  # (ViewCompute writes via CommandRouter → production CommitStore), so a
  # custom-named store wouldn't exercise the real path. Mirrors
  # ChatViewComputeSupervisorTest's setup.
  setup do
    dir = Path.join(System.tmp_dir!(), "cp_compute_rehydrator_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, CommitStore)
    _ = Supervisor.delete_child(sup, CommitStore)
    {:ok, _pid} = Supervisor.start_child(sup, {CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()
    ChatViewComputeSupervisor.reset()

    # Seed an empty workspace root.
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(CommitStore, root_uuid, update, nil)

    on_exit(fn ->
      ChatViewComputeSupervisor.reset()
      _ = Supervisor.terminate_child(sup, CommitStore)
      _ = Supervisor.delete_child(sup, CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")
      {:ok, _pid} = Supervisor.start_child(sup, {CommitStore, data_dir: "tmp/test_data"})
      Commonplace.Tree.DocCache.clear()
      File.rm_rf!(dir)
    end)

    %{root: root_uuid}
  end

  test "starts a ViewCompute for every chat room that declares a compute", %{root: root} do
    {:ok, _} = Rooms.create(root, "alpha")
    {:ok, _} = Rooms.create(root, "beta")

    # Nothing running before rehydration.
    assert :ets.lookup(:chat_view_compute_room_index, "alpha") == []
    assert :ets.lookup(:chat_view_compute_room_index, "beta") == []

    assert {:ok, 2} = ComputeRehydrator.rehydrate(root)

    assert [{"alpha", alpha_pid}] = :ets.lookup(:chat_view_compute_room_index, "alpha")
    assert [{"beta", beta_pid}] = :ets.lookup(:chat_view_compute_room_index, "beta")
    assert Process.alive?(alpha_pid)
    assert Process.alive?(beta_pid)
  end

  test "is idempotent — re-running does not start duplicates", %{root: root} do
    {:ok, _} = Rooms.create(root, "gamma")

    assert {:ok, 1} = ComputeRehydrator.rehydrate(root)
    [{"gamma", pid1}] = :ets.lookup(:chat_view_compute_room_index, "gamma")

    assert {:ok, 1} = ComputeRehydrator.rehydrate(root)
    [{"gamma", pid2}] = :ets.lookup(:chat_view_compute_room_index, "gamma")

    assert pid1 == pid2
  end

  test "skips the __template directory and tolerates an empty /chat", %{root: root} do
    # No rooms created — only the template the bootstrap mints. Rehydration
    # must not try to start a compute for __template.
    {:ok, _} = Rooms.create(root, "delta")
    {:ok, count} = ComputeRehydrator.rehydrate(root)
    assert count == 1
    assert :ets.lookup(:chat_view_compute_room_index, "__template") == []
  end

  test "returns {:ok, 0} when the workspace has no /chat directory yet" do
    bare_root = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(CommitStore, bare_root, update, nil)

    assert {:ok, 0} = ComputeRehydrator.rehydrate(bare_root)
  end

  test "the supervised GenServer rehydrates on boot", %{root: root} do
    {:ok, _} = Rooms.create(root, "epsilon")

    {:ok, pid} = ComputeRehydrator.start_link(root_uuid: root)

    # The scan runs in handle_continue after init; give it a beat.
    wait_until(fn -> :ets.lookup(:chat_view_compute_room_index, "epsilon") != [] end)
    assert [{"epsilon", compute_pid}] = :ets.lookup(:chat_view_compute_room_index, "epsilon")
    assert Process.alive?(compute_pid)

    GenServer.stop(pid)
  end

  defp wait_until(fun, attempts \\ 50) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.(), do: {:halt, true}, else: (Process.sleep(20) && {:cont, false})
    end)
    |> case do
      true -> :ok
      false -> flunk("condition never became true within #{attempts * 20}ms")
    end
  end
end
