defmodule Commonplace.Workspace.LockTest do
  @moduledoc """
  CX-qida: workspace single-owner enforcement. Two `Commonplace.Workspace.Lock`
  GenServers pointed at the same `data_dir` model two `commonplace serve`
  processes (or a serve + Phoenix-as-serve Mode B boot) racing to open one
  workspace. The second must fail fast with a clear reason; the first's
  death (graceful or crash) must free the lock for a new owner without any
  manual cleanup.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Workspace.Lock

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_workspace_lock_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "acquires the lock and creates the lock file", %{dir: dir} do
    assert {:ok, pid} = Lock.start_link(data_dir: dir)
    assert File.exists?(Lock.lock_path(dir))
    GenServer.stop(pid)
  end

  test "second locker on the same data_dir fails fast with a clear reason", %{dir: dir} do
    assert {:ok, holder} = Lock.start_link(data_dir: dir)

    # A real second flock(2) attempt: try_lock/2 is OS-level and keyed to
    # the open file description, not the calling process, so a second
    # acquire from within the same test process reproduces the actual
    # two-serve-processes race faithfully (verified directly against
    # Commonplace.Flock in flock_test.exs's "would_block" case) —
    # no need for a separate System.cmd/port-based flock probe.
    Process.flag(:trap_exit, true)

    assert {:error, {:workspace_already_locked, reason, path}} =
             GenServer.start(Lock, data_dir: dir)

    assert reason == :would_block
    assert path == Lock.lock_path(dir)

    GenServer.stop(holder)
  end

  test "holder's graceful stop frees the lock for a new acquire", %{dir: dir} do
    assert {:ok, holder} = Lock.start_link(data_dir: dir)
    assert {:error, {:workspace_already_locked, _, _}} = GenServer.start(Lock, data_dir: dir)

    GenServer.stop(holder)

    assert {:ok, new_holder} = Lock.start_link(data_dir: dir)
    GenServer.stop(new_holder)
  end

  test "holder's crash (no terminate/2) frees the lock for a new acquire", %{dir: dir} do
    # Unlinked on purpose: we're modeling an independent OS process (a
    # second `commonplace serve`) dying, not a supervised child crashing
    # under the test process — a link here would propagate the :killed
    # exit signal to the test itself.
    assert {:ok, holder} = GenServer.start(Lock, data_dir: dir)
    assert {:error, {:workspace_already_locked, _, _}} = GenServer.start(Lock, data_dir: dir)

    ref = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^ref, :process, ^holder, :killed}, 2000

    # The fd lives in a NIF resource tied to the dead process's heap, not
    # to our terminate/2 callback (which never ran under :kill) — this is
    # exactly the crash-safety property the lock relies on: the OS closes
    # the fd (and releases the flock) once the resource is unreachable,
    # with no stale-lock cleanup step. Poll briefly for the BEAM's
    # resource GC to catch up; no manual lock-file cleanup performed.
    new_holder = wait_for_reacquire(dir)
    GenServer.stop(new_holder)
  end

  defp wait_for_reacquire(dir, attempts \\ 50)

  defp wait_for_reacquire(_dir, 0), do: flunk("lock was never released after holder crash")

  defp wait_for_reacquire(dir, attempts) do
    :erlang.garbage_collect()

    case GenServer.start(Lock, data_dir: dir) do
      {:ok, pid} ->
        pid

      {:error, {:workspace_already_locked, _, _}} ->
        Process.sleep(50)
        wait_for_reacquire(dir, attempts - 1)
    end
  end
end
