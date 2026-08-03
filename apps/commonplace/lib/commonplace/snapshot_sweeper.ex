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

  ## Stuck-doc tracking (CX-inpn)

  Docs carrying CRDT sub-types nested inside maps/arrays trip the R5
  guard (`Commonplace.Store.Snapshotter.build_payload/2`) at every
  snapshot attempt, forever — refusing the cut is correct (it avoids
  silent data loss) but before this left no operator-visible record of
  which docs were stuck. Each periodic sweep tick now records every
  `{:ok, :skipped, {:nested_subtypes, names, chain_length}}` result
  from `SnapshotTrigger.maybe_snapshot/3` and replaces the previous
  tick's set wholesale — a doc that gets fixed (the nesting removed,
  or CX-tdkq.14's structural replay lands) simply drops off the next
  sweep. `stuck_docs/1` exposes the current set.

  This state is in-memory only: a sweeper restart loses the
  accumulated set, but the very next sweep tick rebuilds it from
  scratch, so nothing is permanently lost — only a temporary
  observability gap until the next tick.

  `chain_length` comes for free: `SnapshotTrigger.maybe_snapshot/3`
  already walks the chain once per doc per sweep to decide whether to
  fire; this module doesn't do a second walk. When a stuck doc's
  chain length reaches `@chain_length_watermark`, a `Logger.warning`
  names it — throttled to fire only on the sweep where a doc *first*
  crosses the watermark (tracked against the previous sweep's
  over-watermark set), not on every subsequent sweep.

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
    * `:name` — GenServer registration name (defaults to `__MODULE__`;
      override for tests that run more than one sweeper in the same
      node).
  """

  use GenServer
  require Logger

  alias Commonplace.SnapshotTrigger
  alias Commonplace.Store.CommitStore

  @default_interval 60_000

  # CX-inpn: chain length past which a stuck (nested-subtype-guarded)
  # doc gets an operator warning — chosen well below the 10k commit_log
  # truncation cap so there's room to intervene before it's hit.
  @chain_length_watermark 5_000

  defstruct [
    :store,
    :interval,
    :trigger_opts,
    stuck_docs: %{},
    over_watermark: MapSet.new()
  ]

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
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

  @doc """
  Returns the docs stuck behind the nested-subtypes (R5) guard as of
  the most recent sweep tick, as a list of `{doc_uuid, names}` —
  `names` being the sub-type names `Snapshotter.build_payload/2`
  refused to drop. Empty before the sweeper's first tick, and
  replaced wholesale by every subsequent tick (CX-inpn).
  """
  @spec stuck_docs(GenServer.server()) :: [{String.t(), [String.t()]}]
  def stuck_docs(server \\ __MODULE__) do
    GenServer.call(server, :stuck_docs)
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
    state = do_sweep(state)
    schedule_sweep(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:stuck_docs, _from, state) do
    {:reply, Map.to_list(state.stuck_docs), state}
  end

  defp do_sweep(state) do
    {stuck, over_watermark} =
      state.store
      |> CommitStore.all_doc_uuids()
      |> Enum.reduce({%{}, MapSet.new()}, fn uuid, acc ->
        state.store
        |> SnapshotTrigger.maybe_snapshot(uuid, state.trigger_opts)
        |> record_sweep_result(uuid, state, acc)
      end)

    %{state | stuck_docs: stuck, over_watermark: over_watermark}
  end

  defp record_sweep_result(
         {:ok, :skipped, {:nested_subtypes, names, chain_length}},
         uuid,
         state,
         {stuck_acc, watermark_acc}
       ) do
    maybe_warn_watermark(uuid, chain_length, state.over_watermark)

    watermark_acc =
      if chain_length >= @chain_length_watermark do
        MapSet.put(watermark_acc, uuid)
      else
        watermark_acc
      end

    {Map.put(stuck_acc, uuid, names), watermark_acc}
  end

  defp record_sweep_result(_result, _uuid, _state, acc), do: acc

  defp maybe_warn_watermark(uuid, chain_length, previous_over_watermark) do
    if chain_length >= @chain_length_watermark and
         not MapSet.member?(previous_over_watermark, uuid) do
      Logger.warning(
        "SnapshotSweeper: doc #{uuid} stuck behind the nested-subtypes snapshot guard " <>
          "with chain length #{chain_length} (>= #{@chain_length_watermark}) — " <>
          "approaching the commit_log truncation cap (CX-inpn)"
      )
    end
  end

  defp schedule_sweep(state) do
    Process.send_after(self(), :sweep, state.interval)
  end
end
