defmodule Commonplace.Sync.FileLockTest do
  @moduledoc """
  Tests for file locking — shared/exclusive coordination.
  """
  use ExUnit.Case

  alias Commonplace.Sync.FileLock

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_lock_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "lockable.txt")
    File.write!(path, "content")
    lock_name = :"lock_#{:rand.uniform(1_000_000)}"
    start_supervised!({FileLock, name: lock_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: path, dir: dir, lock: lock_name}
  end

  describe "with_shared_lock/2" do
    test "executes function and returns result", %{path: path, lock: lock} do
      result = FileLock.with_shared_lock(path, fn -> "read result" end, server: lock)
      assert result == {:ok, "read result"}
    end

    test "allows concurrent shared locks", %{path: path, lock: lock} do
      test_pid = self()

      task1 =
        Task.async(fn ->
          FileLock.with_shared_lock(path, fn ->
            send(test_pid, {:task1, :locked})
            receive do
              :continue -> :ok
            after
              1000 -> :timeout
            end
            "task1"
          end, server: lock)
        end)

      task2 =
        Task.async(fn ->
          FileLock.with_shared_lock(path, fn ->
            send(test_pid, {:task2, :locked})
            receive do
              :continue -> :ok
            after
              1000 -> :timeout
            end
            "task2"
          end, server: lock)
        end)

      assert_receive {:task1, :locked}, 1000
      assert_receive {:task2, :locked}, 1000

      send(task1.pid, :continue)
      send(task2.pid, :continue)

      assert {:ok, "task1"} = Task.await(task1)
      assert {:ok, "task2"} = Task.await(task2)
    end

    test "releases lock after function returns", %{path: path, lock: lock} do
      {:ok, _} = FileLock.with_shared_lock(path, fn -> "done" end, server: lock)
      {:ok, _} = FileLock.with_exclusive_lock(path, fn -> "exclusive" end, server: lock)
    end

    test "releases lock on exception", %{path: path, lock: lock} do
      catch_error(
        FileLock.with_shared_lock(path, fn -> raise "boom" end, server: lock)
      )

      {:ok, _} = FileLock.with_exclusive_lock(path, fn -> "ok" end, server: lock)
    end
  end

  describe "with_exclusive_lock/2" do
    test "executes function and returns result", %{path: path, lock: lock} do
      result = FileLock.with_exclusive_lock(path, fn -> "write result" end, server: lock)
      assert result == {:ok, "write result"}
    end

    test "blocks other exclusive locks", %{path: path, lock: lock} do
      test_pid = self()

      task1 =
        Task.async(fn ->
          FileLock.with_exclusive_lock(path, fn ->
            send(test_pid, {:task1, :locked})
            Process.sleep(200)
            "task1"
          end, server: lock)
        end)

      assert_receive {:task1, :locked}, 1000

      start = System.monotonic_time(:millisecond)

      task2 =
        Task.async(fn ->
          FileLock.with_exclusive_lock(path, fn ->
            elapsed = System.monotonic_time(:millisecond) - start
            elapsed
          end, server: lock)
        end)

      {:ok, "task1"} = Task.await(task1)
      {:ok, elapsed} = Task.await(task2, 5000)

      assert elapsed >= 100
    end

    test "exclusive blocks shared locks", %{path: path, lock: lock} do
      test_pid = self()

      task1 =
        Task.async(fn ->
          FileLock.with_exclusive_lock(path, fn ->
            send(test_pid, {:exclusive, :locked})
            Process.sleep(200)
            "exclusive"
          end, server: lock)
        end)

      assert_receive {:exclusive, :locked}, 1000

      start = System.monotonic_time(:millisecond)

      task2 =
        Task.async(fn ->
          FileLock.with_shared_lock(path, fn ->
            elapsed = System.monotonic_time(:millisecond) - start
            elapsed
          end, server: lock)
        end)

      {:ok, "exclusive"} = Task.await(task1)
      {:ok, elapsed} = Task.await(task2, 5000)

      assert elapsed >= 100
    end

    test "releases lock after function returns", %{path: path, lock: lock} do
      {:ok, _} = FileLock.with_exclusive_lock(path, fn -> "done" end, server: lock)
      {:ok, _} = FileLock.with_shared_lock(path, fn -> "shared" end, server: lock)
    end
  end

  describe "stability check" do
    test "stable file passes immediately", %{path: path} do
      assert FileLock.wait_stable(path, polls: 3, interval: 10) == :ok
    end

    test "detects file being written to", %{dir: dir} do
      changing = Path.join(dir, "changing.txt")
      File.write!(changing, "v1")

      writer =
        Task.async(fn ->
          Enum.each(1..5, fn i ->
            Process.sleep(30)
            File.write!(changing, "v#{i}")
          end)
        end)

      start = System.monotonic_time(:millisecond)
      FileLock.wait_stable(changing, polls: 3, interval: 50, timeout: 2000)
      elapsed = System.monotonic_time(:millisecond) - start

      assert elapsed >= 50

      Task.await(writer)
    end
  end
end
