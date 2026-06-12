defmodule Commonplace.Process.Sweep do
  @moduledoc """
  Reap a prior orchestrator generation's managed processes
  (CX-tdkq.12, decision O1).

  Managed processes are unnamed and unlinked BY DESIGN (a crashing user
  process must not take reconciliation down) — which means an
  orchestrator that crashes leaves its whole generation running,
  untracked. The next orchestrator must sweep before it reconciles, or
  every declared process is started AGAIN next to its surviving twin.

  The sweep's source of truth is `orchestrator_status.json` — written
  atomically after every process start and every reconcile tick, so it
  survives both an orchestrator crash (same VM: `beam_pid` entries are
  killable) and a whole-BEAM crash (`os_pid` trees + sandbox dirs are
  reaped cross-VM; stale beam_pids parse but are simply not alive).
  This subsumes serve's old `kill_managed_orphans` — cleanup now happens
  on EVERY orchestrator (re)start, not only at serve boot.

  Tolerance contract: garbage entries (unparseable pids, dead pids,
  vanished OS pids, missing file) are skipped silently — the sweep's
  job is convergence, not bookkeeping.
  """

  require Logger

  @grace_ms 5_000

  @doc """
  Sweep all entries recorded in `<data_dir>/orchestrator_status.json`,
  then remove the file. Returns `{:ok, swept_count}`. Never raises on
  malformed files. `opts[:grace_ms]` shortens the OS-process SIGTERM
  grace (tests).
  """
  @spec sweep_status_file(String.t(), keyword()) :: {:ok, non_neg_integer()}
  def sweep_status_file(data_dir, opts \\ []) do
    status_file = Path.join(data_dir, "orchestrator_status.json")

    case File.read(status_file) do
      {:error, _} ->
        {:ok, 0}

      {:ok, content} ->
        entries =
          case Jason.decode(content) do
            {:ok, %{"processes" => procs}} when is_map(procs) -> procs
            _ -> %{}
          end

        Enum.each(entries, fn {name, info} -> sweep_entry(name, info, opts) end)
        File.rm(status_file)
        {:ok, map_size(entries)}
    end
  end

  defp sweep_entry(name, info, opts) when is_map(info) do
    sweep_beam_pid(info["beam_pid"], name)

    case info["os_pid"] do
      os when is_integer(os) -> kill_process_tree(Integer.to_string(os), opts)
      os when is_binary(os) and os != "" -> kill_process_tree(os, opts)
      _ -> :ok
    end

    case info["sandbox_dir"] do
      dir when is_binary(dir) and dir != "" -> File.rm_rf(dir)
      _ -> :ok
    end
  end

  defp sweep_entry(_name, _info, _opts), do: :ok

  defp sweep_beam_pid(beam_pid_s, name) when is_binary(beam_pid_s) do
    case parse_pid(beam_pid_s) do
      {:ok, pid} ->
        if Process.alive?(pid) do
          Logger.debug("Sweep: stopping prior-generation process #{name} (#{beam_pid_s})")

          try do
            GenServer.stop(pid, :shutdown, 1_000)
          catch
            # Not a GenServer / won't stop / already gone — kill hard.
            _, _ -> Process.exit(pid, :kill)
          end
        end

      :error ->
        :ok
    end
  end

  defp sweep_beam_pid(_other, _name), do: :ok

  defp parse_pid(s) do
    {:ok, :erlang.list_to_pid(String.to_charlist(s))}
  rescue
    ArgumentError -> :error
  end

  @doc """
  SIGTERM-grace-SIGKILL an OS process tree by pid string. Ported from
  serve.ex (CX-tdkq.12 Task 4 makes serve delegate here): hits the
  process group, the pid, and its children — PGID often differs from
  PID under escripts/Ports, so group-kill alone misses targets.
  """
  def kill_process_tree(pid_str, opts \\ []) do
    grace_ms = Keyword.get(opts, :grace_ms, @grace_ms)

    group_alive =
      match?({_, 0}, System.cmd("kill", ["-0", "--", "-#{pid_str}"], stderr_to_stdout: true))

    pid_alive = match?({_, 0}, System.cmd("kill", ["-0", pid_str], stderr_to_stdout: true))

    if group_alive or pid_alive do
      if group_alive,
        do: System.cmd("kill", ["-TERM", "--", "-#{pid_str}"], stderr_to_stdout: true)

      if pid_alive do
        System.cmd("pkill", ["-TERM", "-P", pid_str], stderr_to_stdout: true)
        System.cmd("kill", ["-TERM", pid_str], stderr_to_stdout: true)
      end

      Process.sleep(grace_ms)

      if group_alive, do: System.cmd("kill", ["-9", "--", "-#{pid_str}"], stderr_to_stdout: true)
      System.cmd("pkill", ["-9", "-P", pid_str], stderr_to_stdout: true)
      System.cmd("kill", ["-9", pid_str], stderr_to_stdout: true)
      Process.sleep(500)
    end

    :ok
  end
end
