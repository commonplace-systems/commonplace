defmodule Commonplace.Store.CommitStoreQueuePoller do
  @moduledoc """
  CX-9hql (R4c rung-0): periodic mailbox-depth sampler for
  `Commonplace.Store.CommitStore`.

  The per-call `queue_len` sample in `[:commonplace, :commit_store, :call]`
  is entry-sampled — it only fires when a call is PROCESSED. During a
  genuine stall (the mailbox is deep but nothing is draining it) that
  signal goes silent exactly when it would be most interesting. This
  poller closes that gap by sampling the store's mailbox depth on a
  timer, independent of whether the store is making progress.

  ## Why a separate process, not a self-tick inside CommitStore

  A self-tick (`Process.send_after(self(), :tick, ms)` inside the
  CommitStore GenServer itself) would enqueue the tick message into the
  same mailbox it's trying to measure — during a real stall the tick
  competes with the very backlog it's supposed to reveal, and would
  itself queue up your health-check. Sampling from a separate process via
  `Process.info(store_pid, :message_queue_len)` reads the mailbox length
  from OUTSIDE, so it stays accurate (and cheap) even when the store is
  completely wedged.

  ## Lifecycle

  Started (unlinked, so a poller crash never takes the store down) from
  `CommitStore.init/1` via `maybe_start_queue_poller/1`, monitoring the
  store pid so the poller exits cleanly when the store terminates.

  Disabled by setting `config :commonplace, commit_store_queue_poll_ms: nil`
  (or `false`) — disabled by default in the test env (see `config/test.exs`)
  so it doesn't pollute test telemetry assertions with a background timer.
  """

  use GenServer

  @doc false
  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    target_pid = Keyword.fetch!(opts, :target_pid)
    store_name = Keyword.fetch!(opts, :store_name)
    interval_ms = Keyword.fetch!(opts, :interval_ms)

    Process.monitor(target_pid)
    schedule_tick(interval_ms)

    {:ok, %{target_pid: target_pid, store_name: store_name, interval_ms: interval_ms}}
  end

  @impl true
  def handle_info(:tick, state) do
    case Process.info(state.target_pid, :message_queue_len) do
      {:message_queue_len, queue_len} ->
        :telemetry.execute(
          [:commonplace, :commit_store, :queue_depth],
          %{queue_len: queue_len},
          %{store: state.store_name}
        )

      nil ->
        :ok
    end

    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  # The store we're watching went down — nothing left to poll.
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{target_pid: pid} = state) do
    {:stop, :normal, state}
  end

  defp schedule_tick(ms), do: Process.send_after(self(), :tick, ms)
end
