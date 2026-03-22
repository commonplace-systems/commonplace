defmodule Commonplace.CLI.Ps do
  @moduledoc """
  List managed processes and their status.

  Shows process name, PID, mode, sandbox directory, and uptime.
  Connects to the running orchestrator to get live state.
  """

  alias Commonplace.CLI
  alias Commonplace.Process.Orchestrator

  def run(data_dir, _relative_path, _args) do
    CLI.ensure_started(data_dir)

    # Find the orchestrator — it should be running under the supervisor
    case find_orchestrator() do
      nil ->
        IO.puts("No orchestrator running. Start with: commonplace serve")
        System.halt(1)

      orch_pid ->
        info = Orchestrator.process_info(orch_pid)

        if map_size(info) == 0 do
          IO.puts("No managed processes.")
        else
          # Header
          IO.puts(String.pad_trailing("NAME", 25) <>
                  String.pad_trailing("PID", 10) <>
                  String.pad_trailing("MODE", 15) <>
                  String.pad_trailing("STATUS", 10) <>
                  "SANDBOX")
          IO.puts(String.duplicate("-", 90))

          info
          |> Enum.sort_by(fn {name, _} -> name end)
          |> Enum.each(fn {name, proc} ->
            status = if proc.alive, do: "running", else: "dead"
            mode = to_string(proc.mode)
            os_pid = if proc.os_pid, do: to_string(proc.os_pid), else: "-"
            sandbox = proc.sandbox_dir || "-"

            IO.puts(
              String.pad_trailing(name, 25) <>
              String.pad_trailing(os_pid, 10) <>
              String.pad_trailing(mode, 15) <>
              String.pad_trailing(status, 10) <>
              sandbox
            )
          end)
        end
    end
  end

  defp find_orchestrator do
    # The orchestrator is started by the serve command and registered
    # under its PID. We need to find it. Check if there's a pid file.
    data_dir = Application.get_env(:commonplace, :data_dir, "data")
    pid_file = Path.join(data_dir, "orchestrator.pid")

    case File.read(pid_file) do
      {:ok, _content} ->
        # PID file exists but we need the BEAM pid, not OS pid.
        # For now, scan the process list for Orchestrator GenServers.
        find_orchestrator_process()

      {:error, _} ->
        find_orchestrator_process()
    end
  end

  defp find_orchestrator_process do
    # Find any running Orchestrator GenServer in the local node
    Process.list()
    |> Enum.find(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} ->
          case Keyword.get(dict, :"$initial_call") do
            {Commonplace.Process.Orchestrator, :init, 1} -> true
            _ -> false
          end
        _ -> false
      end
    end)
  end
end
