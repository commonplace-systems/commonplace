defmodule Commonplace.Process.SweepTest do
  @moduledoc """
  CX-tdkq.12 (O1): the sweep's OS-process side. Ported from the CLI's
  ServeCleanupTest when `kill_managed_orphans` moved core-ward — the
  status-file reaping contract now belongs to `Process.Sweep` and runs
  on every orchestrator (re)start, not just serve boot.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Process.Sweep

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_sweep_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, status_file: Path.join(dir, "orchestrator_status.json")}
  end

  defp orphan_entry(os_pid, extra \\ %{}) do
    Map.merge(
      %{
        "os_pid" => os_pid,
        "mode" => "sandbox_exec",
        "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "alive" => true
      },
      extra
    )
  end

  test "kills the OS process tree recorded in the status file", %{dir: dir, status_file: status_file} do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, {:args, ["3600"]}])
    {:os_pid, sleep_pid} = Port.info(port, :os_pid)

    File.write!(
      status_file,
      Jason.encode!(%{"pid" => "99999", "processes" => %{"orphan" => orphan_entry(sleep_pid)}})
    )

    assert {:ok, 1} = Sweep.sweep_status_file(dir, grace_ms: 100)

    {_, exit_code} = System.cmd("kill", ["-0", "#{sleep_pid}"], stderr_to_stdout: true)
    assert exit_code != 0
    refute File.exists?(status_file)
  end

  test "cleans up the recorded sandbox dir", %{dir: dir, status_file: status_file} do
    sandbox = Path.join(dir, "sandbox_scratch")
    File.mkdir_p!(sandbox)

    File.write!(
      status_file,
      Jason.encode!(%{
        "processes" => %{"s" => orphan_entry(nil, %{"sandbox_dir" => sandbox})}
      })
    )

    assert {:ok, 1} = Sweep.sweep_status_file(dir, grace_ms: 100)
    refute File.exists?(sandbox)
  end

  test "missing status file is a no-op", %{dir: dir} do
    assert {:ok, 0} = Sweep.sweep_status_file(dir, grace_ms: 100)
  end

  test "corrupt status file is removed without crashing", %{dir: dir, status_file: status_file} do
    File.write!(status_file, "not valid json{{{")
    assert {:ok, 0} = Sweep.sweep_status_file(dir, grace_ms: 100)
    refute File.exists?(status_file)
  end

  test "null os_pid entries are skipped", %{dir: dir, status_file: status_file} do
    File.write!(
      status_file,
      Jason.encode!(%{"processes" => %{"starting" => orphan_entry(nil)}})
    )

    assert {:ok, 1} = Sweep.sweep_status_file(dir, grace_ms: 100)
    refute File.exists?(status_file)
  end
end
