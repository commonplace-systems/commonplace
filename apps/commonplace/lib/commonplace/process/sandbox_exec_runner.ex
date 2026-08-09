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
  alias Commonplace.Crypto.AgentKeys

  require Logger

  # Prefix used to tag stderr lines coming through the port
  @stderr_prefix "__CP_STDERR__"
  @max_line_length 8192

  defstruct [:sandbox_pid, :command, :args, :name, :port, :os_pid, :event_log, :event_log_uuid,
             :store, :env, :signing_context, :capability_cid]

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
    case resolve_signing_context(opts) do
      {:ok, signing_context} -> init_runner(opts, signing_context)
      {:error, reason} -> {:stop, reason}
    end
  end

  defp init_runner(opts, signing_context) do
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
      store: store,
      signing_context: signing_context,
      capability_cid: Keyword.get(opts, :capability_cid)
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
    event_log = commit_event_log(state)
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
    # Reap the OS process TREE first, before closing the port or deleting the
    # sandbox. The bash we spawn runs a pipeline — the user command plus the
    # `__CP_STDERR__` relay loop — as its children. The previous code killed the
    # bash PARENT (`kill os_pid`) before `pkill -P os_pid`'d its children, so the
    # children REPARENTED to init and escaped the -P match → orphans that hold
    # the Port's stdout pipe open and hang piped readers / CI (CX-exg0). Fix:
    # snapshot the whole descendant tree WHILE bash is alive, then signal it
    # leaves-first, escalating TERM→KILL. (Still per-pid, never a `kill -- -PID`
    # process-group kill, which could hit the BEAM or unrelated processes.)
    if state.os_pid do
      reap_tree(state.os_pid, @shutdown_grace_ms)
    end

    # Close port if still open
    if state.port != nil do
      try do
        Port.close(state.port)
      catch
        _, _ -> :ok
      end
    end

    # Commit any remaining events
    if state.event_log != nil do
      _ = commit_event_log(state)
    end

    if state.sandbox_pid && Process.alive?(state.sandbox_pid) do
      Sandbox.stop(state.sandbox_pid)
    end

    :ok
  end

  # Kill `os_pid` and every descendant. Descendants are collected FIRST (while
  # the root is still alive, so reparenting can't hide them), then the whole set
  # is signalled by pid — leaves-first — TERM, then KILL for any survivors.
  defp reap_tree(os_pid, grace_ms) do
    tree = descendant_os_pids(os_pid) ++ [os_pid]
    signal_tree(tree, "-TERM")

    unless wait_all_dead(tree, grace_ms) do
      signal_tree(tree, "-KILL")
      wait_all_dead(tree, 1_000)
    end

    :ok
  end

  # Recursively collect all descendant OS pids of `os_pid` via `pgrep -P`.
  defp descendant_os_pids(os_pid) do
    case System.cmd("pgrep", ["-P", "#{os_pid}"], stderr_to_stdout: true) do
      {out, 0} ->
        children =
          out
          |> String.split("\n", trim: true)
          |> Enum.map(&String.to_integer/1)

        children ++ Enum.flat_map(children, &descendant_os_pids/1)

      _ ->
        []
    end
  end

  defp signal_tree(pids, sig) do
    Enum.each(pids, fn p -> System.cmd("kill", [sig, "#{p}"], stderr_to_stdout: true) end)
  end

  defp wait_all_dead(pids, timeout) when timeout > 0 do
    if Enum.all?(pids, &os_dead?/1) do
      true
    else
      Process.sleep(100)
      wait_all_dead(pids, timeout - 100)
    end
  end

  defp wait_all_dead(_pids, _timeout), do: false

  defp os_dead?(pid) do
    not match?({_, 0}, System.cmd("kill", ["-0", "#{pid}"], stderr_to_stdout: true))
  end

  # --- Private ---

  # Direct legacy callers that do not supply an identity retain their unsigned
  # behavior. Orchestrated processes always supply one and must already have a
  # registered key: this lookup never provisions custody.
  defp resolve_signing_context(opts) do
    case Keyword.get(opts, :identity_uuid) do
      nil ->
        {:ok, nil}

      identity_uuid ->
        secret_store = Keyword.get(opts, :secret_store, Commonplace.Store.SecretStore)

        case AgentKeys.signing_context(identity_uuid, secret_store) do
          {:ok, ctx} ->
            {:ok, ctx}

          {:error, reason} = error ->
            Logger.error(
              "Sandbox process #{Keyword.get(opts, :name, "sandbox")}: signing identity unavailable: #{inspect(reason)}"
            )

            error
        end
    end
  end

  defp commit_event_log(state) do
    case RedLog.commit(state.event_log, commit_opts(state)) do
      {:ok, event_log} ->
        event_log

      {:error, reason} ->
        Logger.error(
          "Sandbox process #{state.name}: event-log commit refused: #{inspect(reason)}"
        )

        state.event_log
    end
  end

  defp commit_opts(%{signing_context: nil}), do: []

  defp commit_opts(state) do
    metadata =
      case state.capability_cid do
        nil -> %{}
        cid -> %{kind: :regular, capability_proof: cid}
      end

    [signing_context: state.signing_context, metadata: metadata]
  end

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
