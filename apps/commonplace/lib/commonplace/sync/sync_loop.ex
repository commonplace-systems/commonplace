defmodule Commonplace.Sync.SyncLoop do
  @moduledoc """
  Live sync loop — runs periodic bidirectional sync between disk and CRDT.

  Wraps Sync.Agent with a timer to provide automatic, continuous sync.
  Prevents re-entrant sync cycles.

  ## Crash isolation (CX-xmhw)

  The underlying `Sync.Agent` is **monitored, not linked**. A bare
  `start_link` would link the agent into the loop, so an agent crash would
  kill the loop and cascade up to whatever started it — the field failure
  was a user-process (`bartleby`) lifecycle event riding that link chain all
  the way into the `:commonplace` application supervisor and stopping the
  BEAM. Here the loop instead unlinks + monitors the agent: an agent crash
  becomes a handled `:DOWN` (the loop logs it and restarts the agent so sync
  continues), and the per-tick `sync_once` call is wrapped so an agent dying
  mid-call can't take the loop down either. The agent's death never escapes.
  """

  use GenServer

  require Logger

  alias Commonplace.Sync.Agent, as: SyncAgent

  defstruct [:agent_pid, :agent_ref, :agent_opts, :interval, :syncing, :cycle_count, :on_cycle]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, 1000)
    on_cycle = Keyword.get(opts, :on_cycle, fn _count -> :ok end)

    agent_opts = [
      root_uuid: Keyword.fetch!(opts, :root_uuid),
      sync_dir: Keyword.fetch!(opts, :dir),
      store: Keyword.get(opts, :store, Commonplace.Store.CommitStoreClient),
      shadow_tracking: Keyword.get(opts, :shadow_tracking, false)
    ]

    {agent_pid, agent_ref} = start_agent(agent_opts)

    state = %__MODULE__{
      agent_pid: agent_pid,
      agent_ref: agent_ref,
      agent_opts: agent_opts,
      interval: interval,
      syncing: false,
      cycle_count: 0,
      on_cycle: on_cycle
    }

    schedule_sync(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:sync, %{syncing: true} = state) do
    # Already syncing, skip and reschedule
    schedule_sync(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:sync, state) do
    state = %{state | syncing: true}

    # CX-xmhw: a synchronous call to an agent that crashes mid-call would
    # surface as an exit in THIS process and take the loop down — the same
    # cascade the monitor prevents for async deaths. Catch it; the agent's
    # :DOWN (already queued) drives the restart.
    try do
      SyncAgent.sync_once(state.agent_pid)
    catch
      :exit, reason ->
        Logger.warning("SyncLoop: sync_once failed (#{inspect(reason)}); agent will be restarted on :DOWN")
    end

    count = state.cycle_count + 1
    state.on_cycle.(count)

    state = %{state | syncing: false, cycle_count: count}
    schedule_sync(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{agent_ref: ref} = state) do
    # CX-xmhw: the Sync.Agent crashed. Contain it — log and restart the agent
    # so sync continues, rather than letting the death propagate.
    Logger.warning("SyncLoop: Sync.Agent crashed (#{inspect(reason)}); restarting it")
    {agent_pid, agent_ref} = start_agent(state.agent_opts)
    {:noreply, %{state | agent_pid: agent_pid, agent_ref: agent_ref, syncing: false}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.agent_pid && Process.alive?(state.agent_pid) do
      # We monitor the agent; stop it explicitly on our own shutdown so it
      # doesn't outlive the loop.
      GenServer.stop(state.agent_pid)
    end

    :ok
  end

  # Start the agent UNLINKED and monitored (see moduledoc). start_link links it
  # momentarily; unlink immediately, then monitor — the window is a synchronous
  # init with no message processing, so the agent cannot crash inside it.
  defp start_agent(agent_opts) do
    {:ok, agent_pid} = SyncAgent.start_link(agent_opts)
    Process.unlink(agent_pid)
    agent_ref = Process.monitor(agent_pid)
    {agent_pid, agent_ref}
  end

  defp schedule_sync(state) do
    Process.send_after(self(), :sync, state.interval)
  end
end
