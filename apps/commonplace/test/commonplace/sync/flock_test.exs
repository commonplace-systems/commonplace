defmodule Commonplace.Sync.FlockTest do
  @moduledoc """
  Tests for OS-level advisory file locks via flock(2) NIF.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Sync.Flock

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_flock_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "lockable.txt")
    File.write!(path, "content")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: path, dir: dir}
  end

  describe "with_exclusive_lock/3" do
    test "acquires lock, runs function, returns result", %{path: path} do
      result = Flock.with_exclusive_lock(path, fn -> :exclusive_result end)
      assert result == :exclusive_result
    end
  end

  describe "with_shared_lock/3" do
    test "acquires shared lock, returns result", %{path: path} do
      result = Flock.with_shared_lock(path, fn -> :shared_result end)
      assert result == :shared_result
    end
  end

  describe "concurrent shared locks" do
    test "multiple shared locks held concurrently", %{path: path} do
      test_pid = self()

      task1 =
        Task.async(fn ->
          Flock.with_shared_lock(path, fn ->
            send(test_pid, {:task1, :locked})

            receive do
              :continue -> :ok
            after
              2000 -> :timeout
            end

            :task1_done
          end)
        end)

      task2 =
        Task.async(fn ->
          Flock.with_shared_lock(path, fn ->
            send(test_pid, {:task2, :locked})

            receive do
              :continue -> :ok
            after
              2000 -> :timeout
            end

            :task2_done
          end)
        end)

      # Both tasks should acquire shared locks concurrently
      assert_receive {:task1, :locked}, 2000
      assert_receive {:task2, :locked}, 2000

      send(task1.pid, :continue)
      send(task2.pid, :continue)

      assert :task1_done = Task.await(task1, 5000)
      assert :task2_done = Task.await(task2, 5000)
    end
  end

  describe "exclusive blocks shared" do
    test "exclusive lock blocks shared lock acquisition", %{path: path} do
      test_pid = self()

      # Acquire exclusive lock and hold it for 500ms
      _holder =
        Task.async(fn ->
          Flock.with_exclusive_lock(path, fn ->
            send(test_pid, :exclusive_acquired)
            Process.sleep(500)
            :held
          end)
        end)

      assert_receive :exclusive_acquired, 2000

      start = System.monotonic_time(:millisecond)

      # Shared lock should block until exclusive is released
      result =
        Flock.with_shared_lock(path, fn ->
          elapsed = System.monotonic_time(:millisecond) - start
          {:shared_done, elapsed}
        end)

      {:shared_done, elapsed} = result
      # Should have waited at least ~400ms (exclusive held for 500ms)
      assert elapsed >= 300, "Expected shared lock to wait, but only waited #{elapsed}ms"
    end
  end

  describe "timeout" do
    test "timeout proceeds without lock", %{path: path} do
      test_pid = self()

      # Hold exclusive lock for a long time
      holder =
        Task.async(fn ->
          Flock.with_exclusive_lock(path, fn ->
            send(test_pid, :holder_locked)

            receive do
              :release -> :ok
            after
              5000 -> :timeout
            end
          end)
        end)

      assert_receive :holder_locked, 2000

      # Try to acquire with a short timeout — should proceed without lock
      result = Flock.with_exclusive_lock(path, 200, fn -> :ran_anyway end)
      assert result == :ran_anyway

      send(holder.pid, :release)
      Task.await(holder, 5000)
    end
  end

  describe "error handling" do
    test "nonexistent file — runs function without lock", %{dir: dir} do
      missing = Path.join(dir, "does_not_exist.txt")
      result = Flock.with_exclusive_lock(missing, fn -> :no_file_result end)
      assert result == :no_file_result
    end

    test "permission denied — runs function without lock", %{dir: dir} do
      restricted = Path.join(dir, "restricted.txt")
      File.write!(restricted, "secret")
      File.chmod!(restricted, 0o000)

      result = Flock.with_exclusive_lock(restricted, fn -> :no_perm_result end)
      assert result == :no_perm_result
    after
      # Restore permissions so cleanup works
      dir = Path.join(System.tmp_dir!(), "cp_flock_test_*")

      for d <- Path.wildcard(dir) do
        for f <- Path.wildcard(Path.join(d, "restricted.txt")) do
          File.chmod(f, 0o644)
        end
      end
    end
  end

  describe "try_lock/2 and unlock/1" do
    test "low-level lock/unlock cycle", %{path: path} do
      assert {:ok, ref} = Flock.try_lock(path, :exclusive)
      assert :ok = Flock.unlock(ref)
    end

    test "try_lock returns :would_block when already exclusively locked", %{path: path} do
      {:ok, ref} = Flock.try_lock(path, :exclusive)

      # Second exclusive lock should fail with :would_block
      assert {:error, :would_block} = Flock.try_lock(path, :exclusive)

      Flock.unlock(ref)
    end

    test "try_lock returns :enoent for missing file", %{dir: dir} do
      missing = Path.join(dir, "nonexistent.txt")
      assert {:error, :enoent} = Flock.try_lock(missing, :exclusive)
    end
  end

  describe "resource cleanup" do
    test "process dies holding lock, lock is released", %{path: path} do
      test_pid = self()

      # Spawn a process that acquires a lock then dies
      spawn(fn ->
        {:ok, _ref} = Flock.try_lock(path, :exclusive)
        send(test_pid, :locked)
        # Die without unlocking — GC should close the fd, releasing the flock
      end)

      assert_receive :locked, 2000

      # Give GC time to reclaim the resource and close the fd
      :erlang.garbage_collect()
      Process.sleep(100)

      # Now we should be able to acquire the lock
      assert {:ok, ref} = Flock.try_lock(path, :exclusive)
      Flock.unlock(ref)
    end
  end
end
