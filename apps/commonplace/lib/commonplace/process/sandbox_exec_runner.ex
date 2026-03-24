defmodule Commonplace.Process.SandboxExecRunner do
  @moduledoc """
  Runs a unix command inside a sync sandbox.

  Creates a Sandbox, waits for initial sync, runs the command,
  and keeps the sandbox alive for file sync to complete.
  Captures stdout/stderr line-by-line via Port.open and appends
  each line as a red event to the process's event log.
  """

  use GenServer

  alias Commonplace.Process.Sandbox
  alias Commonplace.Dataflow.RedLog

  # Prefix used to tag stderr lines coming through the port
  @stderr_prefix "__CP_STDERR__"
  @max_line_length 8192

  defstruct [:sandbox_pid, :command, :args, :name, :port, :os_pid, :event_log, :event_log_uuid, :store, :env]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Get the event log UUID for this runner."
  def event_log_uuid(pid) do
    GenServer.call(pid, :event_log_uuid)
  end

  @doc "Get the sandbox directory path."
  def sandbox_dir(pid) do
    GenServer.call(pid, :sandbox_dir)
  end

  @doc "Get the OS PID of the running port process."
  def os_pid(pid) do
    GenServer.call(pid, :os_pid)
  end

  @impl true
  def init(opts) do
    root_uuid = Keyword.fetch!(opts, :root_uuid)
    store = Keyword.fetch!(opts, :store)
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    name = Keyword.get(opts, :name, "sandbox")
    env = Keyword.get(opts, :env, %{})
    sync_interval = Keyword.get(opts, :sync_interval, 50)
    log_uuid = Keyword.get(opts, :event_log_uuid, UUID.uuid4())

    # Create sandbox
    {:ok, sandbox_pid} = Sandbox.start_link(
      root_uuid: root_uuid,
      store: store,
      sync_interval: sync_interval
    )

    Process.unlink(sandbox_pid)

    # Create the event log
    event_log = RedLog.new(log_uuid, store)

    state = %__MODULE__{
      sandbox_pid: sandbox_pid,
      command: command,
      args: args,
      name: name,
      env: env,
      event_log: event_log,
      event_log_uuid: log_uuid,
      store: store
    }

    # Wait for initial sync then run command
    send(self(), :run_command)

    {:ok, state}
  end

  @impl true
  def handle_call(:event_log_uuid, _from, state) do
    {:reply, state.event_log_uuid, state}
  end

  @impl true
  def handle_call(:sandbox_dir, _from, state) do
    dir = if state.sandbox_pid && Process.alive?(state.sandbox_pid) do
      Sandbox.dir(state.sandbox_pid)
    end
    {:reply, dir, state}
  end

  @impl true
  def handle_call(:os_pid, _from, state) do
    {:reply, state.os_pid, state}
  end

  @impl true
  def handle_info(:run_command, state) do
    # Small delay for initial sync to materialize files
    Process.sleep(200)

    sandbox_dir = Sandbox.dir(state.sandbox_pid)

    # Build a shell command that tags stderr lines with a prefix
    # so we can distinguish them from stdout in the port output.
    # Uses bash explicitly since dash doesn't support the fd3 redirect pattern.
    user_cmd = build_shell_command(state.command, state.args)
    wrapper = "{ #{user_cmd} 2>&1 1>&3 | while IFS= read -r line; do echo '#{@stderr_prefix}'\"$line\"; done; } 3>&1"

    # Convert env map to charlists for Port.open
    env_list = Enum.map(state.env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    port = Port.open(
      {:spawn_executable, "/bin/bash"},
      [:binary, {:line, @max_line_length}, {:cd, sandbox_dir}, :exit_status,
       {:env, env_list}, {:args, ["-c", wrapper]}]
    )

    # Save OS PID persistently — needed for orphan cleanup after crashes
    saved_os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    {:noreply, %{state | port: port, os_pid: saved_os_pid}}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    {type, content} = parse_line(line)
    event_log = append_event(state.event_log, type, content)
    {:noreply, %{state | event_log: event_log}}
  end

  @impl true
  def handle_info({port, {:data, {:noeol, line}}}, %{port: port} = state) do
    # Partial line (exceeded max_line_length) — treat as a complete line
    {type, content} = parse_line(line)
    event_log = append_event(state.event_log, type, content)
    {:noreply, %{state | event_log: event_log}}
  end

  @impl true
  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) do
    # Command finished — commit the event log and schedule done check
    event_log = RedLog.commit(state.event_log)
    Process.send_after(self(), :check_done, 200)
    {:noreply, %{state | event_log: event_log, port: nil}}
  end

  @impl true
  def handle_info(:check_done, state) do
    # Process is done — stay alive so sync loop can pick up changes
    # The orchestrator manages our lifecycle
    {:noreply, state}
  end

  @shutdown_grace_ms 5000

  @impl true
  def terminate(_reason, state) do
    # Kill the OS process and its children first, before closing port or deleting sandbox.
    # Avoids process-group kills (kill -- -PID) which could affect the BEAM or
    # unrelated processes sharing the same group.
    if state.os_pid do
      System.cmd("kill", ["-TERM", "#{state.os_pid}"], stderr_to_stdout: true)
      System.cmd("pkill", ["-TERM", "-P", "#{state.os_pid}"], stderr_to_stdout: true)
    end

    # Close port if still open
    if state.port != nil do
      try do
        Port.close(state.port)
      catch
        _, _ -> :ok
      end
    end

    # Wait for the OS process to exit before cleaning up sandbox
    if state.os_pid do
      wait_for_exit(state.os_pid, @shutdown_grace_ms)
    end

    # Commit any remaining events
    if state.event_log != nil do
      RedLog.commit(state.event_log)
    end

    if state.sandbox_pid && Process.alive?(state.sandbox_pid) do
      Sandbox.stop(state.sandbox_pid)
    end

    :ok
  end

  defp wait_for_exit(os_pid, timeout) when timeout > 0 do
    case System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true) do
      {_, 0} ->
        # Still alive — wait and retry
        Process.sleep(200)
        wait_for_exit(os_pid, timeout - 200)

      _ ->
        # Dead
        :ok
    end
  end

  defp wait_for_exit(os_pid, _timeout) do
    # Timed out — force kill individual process and its children
    System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
    System.cmd("pkill", ["-9", "-P", "#{os_pid}"], stderr_to_stdout: true)
    Process.sleep(200)
  end

  # --- Private ---

  defp parse_line(line) do
    if String.starts_with?(line, @stderr_prefix) do
      {"stderr", String.trim_leading(line, @stderr_prefix)}
    else
      {"stdout", line}
    end
  end

  defp append_event(event_log, type, content) do
    event = %{
      "type" => type,
      "line" => content,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    RedLog.append_raw(event_log, event)
  end

  defp build_shell_command(command, args) do
    ([command | args])
    |> Enum.map(&shell_escape/1)
    |> Enum.join(" ")
  end

  defp shell_escape(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end
end
