defmodule Commonplace.Process.Sandbox do
  @moduledoc """
  Filesystem sandbox for unix processes.

  Creates a temp directory and runs a SyncLoop to materialize
  a CRDT subtree into it. Unix processes run inside the sandbox
  and their file writes flow back to the CRDT.
  """

  use GenServer

  alias Commonplace.Sync.SyncLoop
  alias Commonplace.Sync.Agent, as: SyncAgent

  defstruct [:root_uuid, :store, :sandbox_dir, :sync_pid, :sync_interval]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Get the sandbox directory path."
  def dir(pid), do: GenServer.call(pid, :dir)

  @doc "Execute a command in the sandbox directory."
  def exec(pid, command, args \\ []) do
    GenServer.call(pid, {:exec, command, args}, 30_000)
  end

  @doc "Stop the sandbox and clean up."
  def stop(pid) do
    GenServer.stop(pid)
  end

  @impl true
  def init(opts) do
    root_uuid = Keyword.fetch!(opts, :root_uuid)
    store = Keyword.get(opts, :store, Commonplace.Store.CommitStore)
    sync_interval = Keyword.get(opts, :sync_interval, 1000)

    # Create temp directory
    sandbox_dir = Path.join(System.tmp_dir!(), "cp_sandbox_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(sandbox_dir)

    # Start a SyncLoop to materialize the subtree (unlinked for clean shutdown)
    {:ok, sync_pid} = SyncLoop.start_link(
      dir: sandbox_dir,
      root_uuid: root_uuid,
      store: store,
      interval: sync_interval
    )

    Process.unlink(sync_pid)

    state = %__MODULE__{
      root_uuid: root_uuid,
      store: store,
      sandbox_dir: sandbox_dir,
      sync_pid: sync_pid,
      sync_interval: sync_interval
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:dir, _from, state) do
    {:reply, state.sandbox_dir, state}
  end

  @impl true
  def handle_call({:exec, command, args}, _from, state) do
    # Run the command in the sandbox directory
    result = System.cmd(command, args, cd: state.sandbox_dir, stderr_to_stdout: true)
    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Stop the sync loop
    if state.sync_pid && Process.alive?(state.sync_pid) do
      try do
        GenServer.stop(state.sync_pid, :shutdown, 2000)
      catch
        :exit, _ -> :ok
      end
    end

    # Clean up sandbox directory
    File.rm_rf!(state.sandbox_dir)

    :ok
  end
end
