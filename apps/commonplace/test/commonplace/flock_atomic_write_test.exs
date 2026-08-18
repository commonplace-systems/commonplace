defmodule Commonplace.FlockAtomicWriteTest do
  use ExUnit.Case

  alias Commonplace.Flock
  alias Commonplace.Sync.Export

  setup do
    dir = Path.join(System.tmp_dir!(), "flock_aw_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "atomic_write acquires exclusive lock during write", %{dir: dir} do
    path = Path.join(dir, "test.txt")
    File.write!(path, "initial")
    parent = self()

    spawn(fn ->
      Flock.with_shared_lock(path, 5_000, fn ->
        send(parent, :shared_acquired)
        Process.sleep(500)
      end)

      send(parent, :shared_released)
    end)

    assert_receive :shared_acquired, 1_000

    start = System.monotonic_time(:millisecond)
    Export.atomic_write(path, "updated")
    elapsed = System.monotonic_time(:millisecond) - start

    assert elapsed >= 300
    assert File.read!(path) == "updated"
  end
end
