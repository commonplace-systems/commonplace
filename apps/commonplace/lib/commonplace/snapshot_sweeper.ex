defmodule Commonplace.SnapshotSweeper do
  @moduledoc """
  Periodic snapshot-sweep service (CX-fab5).

  Walks every doc known to the local CommitStore on a configurable
  interval and invokes `Commonplace.SnapshotTrigger.maybe_snapshot/3`
  on each. Catches docs that have accumulated chain length but haven't
  been written through a path that fires the producer-side trigger
  (CX-tvyb) — e.g. docs touched only by remote `import_commit` calls,
  or docs that were churned heavily before the snapshot infrastructure
  came online.

  ## Concurrency

  The underlying `SnapshotTrigger.maybe_snapshot/3` is safe under
  concurrent invocation: deterministic-anyone snapshotting (CX-umz)
  means two callers observing the same parent build the same bytes
  and the same id, and the CAS write only commits one. So this
  sweeper composes cleanly with the producer-side hook (CX-tvyb), the
  reader-side lazy path (CX-fkvc), and the explicit CLI command
  (CX-2ok0) — multiple hooks racing on the same threshold-crossing
  collapse into a single snapshot commit.

  ## Configuration

    * `:store` — CommitStore name (defaults to the application-default
      `Commonplace.Store.CommitStore`).
    * `:interval` — milliseconds between sweep ticks (default 60_000).
    * `:chain_length_threshold` — passed through to the SnapshotTrigger
      primitive on each call.
  """

  use GenServer

  alias Commonplace.SnapshotTrigger
  alias Commonplace.Store.CommitStore

  @default_interval 60_000

  defstruct [:store, :interval, :trigger_opts]

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Run one sweep over every doc in `store`. Mostly useful for tests and
  the explicit operator command — production runs through the
  GenServer's periodic tick.
  """
  @spec sweep(GenServer.server(), keyword()) :: :ok
  def sweep(store \\ CommitStore, opts \\ []) do
    store
    |> CommitStore.all_doc_uuids()
    |> Enum.each(fn uuid ->
      _ = SnapshotTrigger.maybe_snapshot(store, uuid, opts)
    end)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    state = %__MODULE__{
      store: Keyword.get(opts, :store, CommitStore),
      interval: Keyword.get(opts, :interval, @default_interval),
      trigger_opts: Keyword.take(opts, [:chain_length_threshold])
    }

    schedule_sweep(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(state.store, state.trigger_opts)
    schedule_sweep(state)
    {:noreply, state}
  end

  defp schedule_sweep(state) do
    Process.send_after(self(), :sweep, state.interval)
  end
end
