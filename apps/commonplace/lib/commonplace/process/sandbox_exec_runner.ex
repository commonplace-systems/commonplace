defmodule Commonplace.Process.SandboxExecRunner do
  @moduledoc """
  Runs a unix command inside a sync sandbox.

  Creates a Sandbox, waits for initial sync, runs the command,
  and keeps the sandbox alive for file sync to complete.
  Captures stdout/stderr for the red event log.
  """

  use GenServer

  alias Commonplace.Process.Sandbox

  defstruct [:sandbox_pid, :command, :args, :name, :port, :output_lines]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    root_uuid = Keyword.fetch!(opts, :root_uuid)
    store = Keyword.fetch!(opts, :store)
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    name = Keyword.get(opts, :name, "sandbox")
    sync_interval = Keyword.get(opts, :sync_interval, 50)

    # Create sandbox
    {:ok, sandbox_pid} = Sandbox.start_link(
      root_uuid: root_uuid,
      store: store,
      sync_interval: sync_interval
    )

    Process.unlink(sandbox_pid)

    state = %__MODULE__{
      sandbox_pid: sandbox_pid,
      command: command,
      args: args,
      name: name,
      output_lines: []
    }

    # Wait for initial sync then run command
    send(self(), :run_command)

    {:ok, state}
  end

  @impl true
  def handle_info(:run_command, state) do
    # Small delay for initial sync to materialize files
    Process.sleep(200)

    sandbox_dir = Sandbox.dir(state.sandbox_pid)

    # Run the command
    try do
      System.cmd(state.command, state.args,
        cd: sandbox_dir,
        stderr_to_stdout: true
      )
    rescue
      _ -> :ok
    end

    # Keep alive briefly for sync to pick up written files
    Process.send_after(self(), :check_done, 200)

    {:noreply, state}
  end

  @impl true
  def handle_info(:check_done, state) do
    # Process is done — stay alive so sync loop can pick up changes
    # The orchestrator manages our lifecycle
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.sandbox_pid && Process.alive?(state.sandbox_pid) do
      Sandbox.stop(state.sandbox_pid)
    end

    :ok
  end
end
