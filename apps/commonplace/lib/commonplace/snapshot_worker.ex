defmodule Commonplace.SnapshotWorker do
  @moduledoc """
  Single-flight scheduler in front of `Commonplace.SnapshotTrigger`
  (architecture-review R4 part b, CX-tdkq.4 / CX-0nkq).

  ## Why this exists

  `SnapshotTrigger.maybe_snapshot/3` is fired from several sites — the
  producer-side hook, the sync agent, the periodic sweeper, and (most
  aggressively) the reader-side lazy path `DocBuilder.maybe_lazy_snapshot`,
  which under read pressure spawns many concurrent attempts for the *same*
  doc. The original relief was a coarse per-doc time debounce (a 10s ETS
  window): best-effort, and it suppressed legitimate snapshots as readily
  as redundant ones.

  This worker is the precise replacement the debounce always deferred to.
  It guarantees **at most one snapshot computation per doc is in-flight at
  a time**, and collapses any requests that arrive during an in-flight run
  into a **single** coalesced re-run (computed once against the latest
  state when the in-flight run finishes). Correctness never depended on
  either mechanism — deterministic-anyone snapshotting (CX-umz) plus the
  CAS write make snapshots idempotent regardless — so this is purely about
  not doing redundant work.

  ## Design

  Each in-flight computation runs in its own monitored process, so the
  GenServer stays responsive to coalesce further requests while a snapshot
  is being built. Per-doc state:

    * `inflight` — docs with a computation currently running.
    * `pending` — at most one coalesced `{store, opts}` per doc, captured
      from the most recent request that arrived while it was in-flight.

  When a computation finishes (or crashes — best-effort, a failure is
  logged-by-omission and simply re-dispatched if pending), the doc leaves
  `inflight`; if it has a `pending` entry, exactly one re-run dispatches.

  The trigger function is injectable (`:trigger` opt) so it can be tested
  deterministically without depending on snapshot timing; it defaults to
  `&SnapshotTrigger.maybe_snapshot/3`.
  """

  use GenServer

  alias Commonplace.SnapshotTrigger
  alias Commonplace.Store.CommitStore

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Request a (coalesced, single-flight) snapshot attempt for `doc_uuid`.

  Fire-and-forget: returns `:ok` immediately. If a computation for this
  doc is already in-flight, this request is coalesced into a single
  pending re-run rather than starting a second one.
  """
  def request(server \\ __MODULE__, store, doc_uuid, opts \\ []) do
    GenServer.cast(server, {:request, store, doc_uuid, opts})
  end

  @impl true
  def init(opts) do
    trigger = Keyword.get(opts, :trigger, &SnapshotTrigger.maybe_snapshot/3)
    {:ok, %{trigger: trigger, inflight: %{}, pending: %{}, refs: %{}}}
  end

  @impl true
  def handle_cast({:request, store, doc_uuid, opts}, state) do
    state =
      if Map.has_key?(state.inflight, doc_uuid) do
        # A run is in-flight — coalesce. Keep the most recent request's
        # store/opts; later requests overwrite, so the re-run computes
        # against the freshest intent.
        put_in(state.pending[doc_uuid], {store, opts})
      else
        dispatch(state, doc_uuid, store, opts)
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _refs} ->
        {:noreply, state}

      {doc_uuid, refs} ->
        state = %{state | refs: refs, inflight: Map.delete(state.inflight, doc_uuid)}

        state =
          case Map.pop(state.pending, doc_uuid) do
            {nil, _pending} ->
              state

            {{store, opts}, pending} ->
              dispatch(%{state | pending: pending}, doc_uuid, store, opts)
          end

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Spawn the snapshot computation in a monitored process and mark the doc
  # in-flight. The worker doesn't care about the result (snapshots are
  # best-effort); it only needs the DOWN to know when to release the slot
  # and re-dispatch any coalesced pending request.
  defp dispatch(state, doc_uuid, store, opts) do
    trigger = state.trigger
    store = store || CommitStore
    {_pid, ref} = spawn_monitor(fn -> trigger.(store, doc_uuid, opts) end)

    state
    |> put_in([:inflight, doc_uuid], ref)
    |> put_in([:refs, ref], doc_uuid)
  end
end
