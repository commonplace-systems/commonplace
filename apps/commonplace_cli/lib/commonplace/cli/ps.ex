defmodule Commonplace.CLI.Ps do
  @moduledoc """
  List managed processes and their status.

  Reads the orchestrator status file written by the running serve daemon.
  """

  alias Commonplace.CLI

  def run(data_dir, _relative_path, _args) do
    CLI.ensure_started(data_dir)

    status_file = Path.join(data_dir, "orchestrator_status.json")
    pid_file = Path.join(data_dir, "orchestrator.pid")

    unless File.exists?(status_file) do
      IO.puts("No orchestrator running. Start with: commonplace serve")
      System.halt(1)
    end

    status = status_file |> File.read!() |> Jason.decode!()

    # Verify the orchestrator process is actually alive
    os_pid = status["pid"]
    unless os_pid && os_process_alive?(os_pid) do
      IO.puts("Orchestrator status file is stale (PID #{os_pid} not running).")
      IO.puts("Start with: commonplace serve")
      File.rm(status_file)
      File.rm(pid_file)
      System.halt(1)
    end

    processes = status["processes"] || %{}

    if map_size(processes) == 0 do
      IO.puts("Orchestrator running (PID #{os_pid}). No managed processes.")
    else
      IO.puts(
        String.pad_trailing("NAME", 25) <>
        String.pad_trailing("PID", 10) <>
        String.pad_trailing("MODE", 15) <>
        String.pad_trailing("STATUS", 10) <>
        "SANDBOX"
      )
      IO.puts(String.duplicate("-", 90))

      processes
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.each(fn {name, proc} ->
        status_str = if proc["alive"], do: "running", else: "dead"
        mode = proc["mode"] || "-"
        os_pid_str = if proc["os_pid"], do: to_string(proc["os_pid"]), else: "-"
        sandbox = proc["sandbox_dir"] || "-"

        IO.puts(
          String.pad_trailing(name, 25) <>
          String.pad_trailing(os_pid_str, 10) <>
          String.pad_trailing(mode, 15) <>
          String.pad_trailing(status_str, 10) <>
          sandbox
        )
      end)
    end
  end

  defp os_process_alive?(pid_str) do
    case System.cmd("kill", ["-0", to_string(pid_str)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end
end
