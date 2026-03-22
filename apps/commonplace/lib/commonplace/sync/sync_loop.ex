defmodule Commonplace.Sync.SyncLoop do
  @moduledoc """
  Live sync loop — runs periodic bidirectional sync between disk and CRDT.

  Wraps Sync.Agent with a timer to provide automatic, continuous sync.
  Prevents re-entrant sync cycles.
  """

  use GenServer

  alias Commonplace.Sync.Agent, as: SyncAgent

  defstruct [:agent_pid, :interval, :syncing, :cycle_count, :on_cycle]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, 1000)
    on_cycle = Keyword.get(opts, :on_cycle, fn _count -> :ok end)

    # Start the underlying sync agent
    {:ok, agent_pid} = SyncAgent.start_link(
      root_uuid: Keyword.fetch!(opts, :root_uuid),
      sync_dir: Keyword.fetch!(opts, :dir),
      store: Keyword.get(opts, :store, Commonplace.Store.CommitStore),
      shadow_tracking: Keyword.get(opts, :shadow_tracking, false)
    )

    state = %__MODULE__{
      agent_pid: agent_pid,
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

    SyncAgent.sync_once(state.agent_pid)

    count = state.cycle_count + 1
    state.on_cycle.(count)

    state = %{state | syncing: false, cycle_count: count}
    schedule_sync(state)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.agent_pid && Process.alive?(state.agent_pid) do
      GenServer.stop(state.agent_pid)
    end

    :ok
  end

  defp schedule_sync(state) do
    Process.send_after(self(), :sync, state.interval)
  end
end
