defmodule Commonplace.CLI.ServeCleanupTest do
  @moduledoc """
  CX-tdkq.12 (O5): serve's orphan cleanup is now ONLY the prior serve's
  own OS pid (orchestrator.pid). Managed-process reaping moved to
  `Commonplace.Process.Sweep` (tested in core) and runs on every
  orchestrator (re)start — serve must NOT consume the status file the
  sweep relies on.
  """
  use ExUnit.Case

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_serve_cleanup_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "kill_orphans leaves orchestrator_status.json for the sweep", %{dir: dir} do
    status_file = Path.join(dir, "orchestrator_status.json")
    File.write!(status_file, Jason.encode!(%{"processes" => %{}}))

    Commonplace.CLI.Serve.kill_orphans(dir)

    assert File.exists?(status_file)
  end

  test "kill_orphans without any pid file does not crash", %{dir: dir} do
    assert Commonplace.CLI.Serve.kill_orphans(dir)
  end

  test "kill_orphans removes a stale orchestrator.pid", %{dir: dir} do
    pid_file = Path.join(dir, "orchestrator.pid")
    # A pid that certainly isn't running (max pid space is well below this).
    File.write!(pid_file, "99999999\n")

    Commonplace.CLI.Serve.kill_orphans(dir)

    refute File.exists?(pid_file)
  end
end
