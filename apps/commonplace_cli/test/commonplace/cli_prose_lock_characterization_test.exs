defmodule Commonplace.CLI.ProseLockCharacterizationTest do
  @moduledoc """
  CX-x8jk RED-FIRST CAPTURE — records what `Commonplace.CLI.acquire_db_lock/1`
  does TODAY, over the SAME `<data_dir>/commits.lock` file that CX-2479's
  flock(2) now owns.

  These tests PASS against the defect: that is the point. They are the
  characterization of a second, independent exclusion scheme over one
  resource. Both this file and `acquire_db_lock/1` are deleted in the
  commit that removes the defect.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Sync.Flock

  defp tmp_dir(tag) do
    dir = Path.join(System.tmp_dir!(), "cx_x8jk_#{tag}_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # Hold a real flock(2) on <dir>/commits.lock from another process, with
  # the CX-2479 diagnostic hint content ("<pid> <node>") in the file.
  defp hold_flock(dir, hint) do
    path = Path.join(dir, "commits.lock")
    File.touch!(path)
    File.write!(path, hint)
    me = self()

    holder =
      spawn(fn ->
        {:ok, _ref} = Flock.try_lock(path, :exclusive)
        send(me, :locked)
        receive do: (:never -> :ok)
      end)

    assert_receive :locked, 1_000
    on_exit(fn -> Process.exit(holder, :kill) end)
    {holder, path}
  end

  test "TODAY: the prose lock hands out the lock while a live flock holder has it" do
    dir = tmp_dir("takeover")
    # A hint naming a pid that is NOT alive — exactly the shape a serve
    # leaves behind if its OS pid is not the one the reader can signal.
    {_holder, path} = hold_flock(dir, "4194304 commonplace_dev@commonplace\n")

    # The flock is genuinely held: an independent opener is refused.
    assert {:error, :would_block} = Flock.try_lock(path, :exclusive)

    result = Commonplace.CLI.acquire_db_lock(dir)

    assert {:ok, ^path} = result,
           "expected the prose lock to grant access despite the flock; got #{inspect(result)}"

    # ...and it CLOBBERED the flock holder's diagnostic hint.
    assert File.read!(path) == System.pid()
    refute File.read!(path) =~ "commonplace_dev@commonplace"

    # The real exclusion is untouched — proof the two schemes are unrelated.
    assert {:error, :would_block} = Flock.try_lock(path, :exclusive)
  end

  test "TODAY: the prose lock is decided by a pid string, not by the kernel" do
    dir = tmp_dir("pidstring")
    path = Path.join(dir, "commits.lock")

    # (a) A pid we can signal, no flock anywhere: the store is genuinely
    # free, but the pid string alone refuses the legitimate offline open.
    {sleeper, 0} = System.cmd("sh", ["-c", "sleep 60 >/dev/null 2>&1 & echo $!"])
    sleeper = String.trim(sleeper)
    on_exit(fn -> System.cmd("kill", [sleeper], stderr_to_stdout: true) end)

    File.write!(path, sleeper)
    assert {:ok, ref} = Flock.try_lock(path, :exclusive)
    Flock.unlock(ref)
    assert {:error, :locked} = Commonplace.CLI.acquire_db_lock(dir)

    # (b) A pid that IS alive but that we cannot signal (init, pid 1):
    # `kill -0` fails with EPERM, the CLI reads that as "dead", and takes
    # the lock over. Liveness by signal permission, not by the kernel's
    # lock table.
    File.write!(path, "1\n")
    assert {:ok, ^path} = Commonplace.CLI.acquire_db_lock(dir)
  end
end
