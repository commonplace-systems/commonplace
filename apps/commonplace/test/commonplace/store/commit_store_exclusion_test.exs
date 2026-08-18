defmodule Commonplace.Store.CommitStoreExclusionTest do
  @moduledoc """
  CX-2479: `<data_dir>/commits.lock` must be a real OS-level exclusion,
  not advisory prose. Two appenders on one CubDB file corrupted the live
  store; the second opener must be REFUSED, not silently admitted.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.CommitStore
  alias Commonplace.Flock

  defp tmp_dir(tag) do
    dir = Path.join(System.tmp_dir!(), "cx2479_#{tag}_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp uniq(tag), do: :"cx2479_#{tag}_#{:rand.uniform(1_000_000_000)}"

  defp stop_store(pid, name) do
    db = CommitStore.db_handle(name)
    if Process.alive?(pid), do: GenServer.stop(pid)
    if is_pid(db) and Process.alive?(db), do: CubDB.stop(db)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  test "a second CommitStore on the same data_dir is REFUSED" do
    dir = tmp_dir("dup")
    a = uniq("a")
    b = uniq("b")

    assert {:ok, pid_a} = CommitStore.start_link(data_dir: dir, name: a)

    Process.flag(:trap_exit, true)
    result = CommitStore.start_link(data_dir: dir, name: b)

    assert {:error, {:commits_store_locked, detail}} = result,
           "second opener was ADMITTED: #{inspect(result)}"

    assert detail.lock_path == Path.join(dir, "commits.lock")
    assert is_binary(detail.holder_hint)
    assert detail.holder_hint =~ to_string(System.pid())
    assert is_binary(detail.sanctioned_access)
    assert detail.sanctioned_access =~ "CommitStoreClient"

    # The refusal must not have touched the live store: no archive dir.
    assert Enum.filter(File.ls!(dir), &String.starts_with?(&1, "commits.corrupt.")) == []

    stop_store(pid_a, a)
  end

  test "an unavailable flock NIF returns a named fail-closed refusal" do
    dir = tmp_dir("flock_unavailable")
    name = uniq("flock_unavailable")

    Process.flag(:trap_exit, true)

    assert {:error, {:flock_unavailable, remedy}} =
             CommitStore.start_link(
               data_dir: dir,
               name: name,
               flock_module: Commonplace.Sync.DeliberatelyMissingFlockNif
             )

    assert remedy =~ "flock NIF load failed"
    assert remedy =~ "refusing the local CommitStore"
    refute File.exists?(Path.join(dir, "commits"))
  end

  test "the lock file lives in data_dir, NOT inside commits/" do
    dir = tmp_dir("path")
    name = uniq("path")
    {:ok, pid} = CommitStore.start_link(data_dir: dir, name: name)

    assert File.exists?(Path.join(dir, "commits.lock"))
    refute File.exists?(Path.join([dir, "commits", "commits.lock"]))

    stop_store(pid, name)
  end

  test "stopping the holder releases the lock — a fresh open of the same dir succeeds" do
    dir = tmp_dir("release")
    a = uniq("rel_a")
    b = uniq("rel_b")

    {:ok, pid_a} = CommitStore.start_link(data_dir: dir, name: a)
    CommitStore.create_commit(a, "doc-1", <<1>>, nil)
    stop_store(pid_a, a)

    assert {:ok, pid_b} = CommitStore.start_link(data_dir: dir, name: b)
    stop_store(pid_b, b)
  end

  test "MEASUREMENT: flock release after Process.exit(pid, :kill)" do
    dir = tmp_dir("kill")
    lock_path = Path.join(dir, "commits.lock")
    File.touch!(lock_path)

    holder =
      spawn(fn ->
        {:ok, _ref} = Flock.try_lock(lock_path, :exclusive)
        receive do: (:never -> :ok)
      end)

    Process.sleep(100)
    assert {:error, :would_block} = Flock.try_lock(lock_path, :exclusive)

    ref = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^ref, :process, ^holder, :killed}, 1_000

    # Measure how long until the NIF resource dtor closes the fd.
    t0 = System.monotonic_time(:millisecond)

    elapsed =
      Enum.reduce_while(1..200, :never, fn _, _ ->
        case Flock.try_lock(lock_path, :exclusive) do
          {:ok, r} ->
            Flock.unlock(r)
            {:halt, System.monotonic_time(:millisecond) - t0}

          _ ->
            Process.sleep(10)
            {:cont, :never}
        end
      end)

    IO.puts("MEASURED: flock reacquire after kill took #{inspect(elapsed)} ms")
    assert is_integer(elapsed), "lock never released after holder was killed"
    assert elapsed < 1_000
  end

  test "a killed CommitStore's lock is reacquirable immediately by a restart" do
    dir = tmp_dir("killstore")
    a = uniq("k_a")
    b = uniq("k_b")

    Process.flag(:trap_exit, true)
    {:ok, pid_a} = CommitStore.start_link(data_dir: dir, name: a)
    db = CommitStore.db_handle(a)
    ref = Process.monitor(pid_a)
    Process.exit(pid_a, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid_a, :killed}, 1_000
    # CubDB was linked to the killed store; make sure the file handle is gone.
    if is_pid(db) do
      dbref = Process.monitor(db)
      assert_receive {:DOWN, ^dbref, :process, ^db, _}, 1_000
    end

    assert {:ok, pid_b} = CommitStore.start_link(data_dir: dir, name: b)
    stop_store(pid_b, b)
  end
end
