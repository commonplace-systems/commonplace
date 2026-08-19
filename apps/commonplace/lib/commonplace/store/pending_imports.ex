defmodule Commonplace.Store.PendingImports do
  @moduledoc """
  R4c carve-out: the R11 out-of-order-import retry queue (CX-tdkq.11 /
  CX-tdkq.22e), extracted out of `Commonplace.Store.CommitStore`'s GenServer
  state into its own process.

  A commit `import_commit/3` rejects for a reason that MIGHT resolve once
  something else lands — a missing namespace dependency, or a missing
  capability cert (`:awaiting_capability`) — is handed here via `enqueue/4`
  instead of being dropped. It is held (bounded, see `@max_pending_imports`
  below) and re-submitted whenever something suggests the block may have
  cleared:

    * `notify_landed/2` — cast by `CommitStore` after any commit
      successfully lands (a fresh commit might be the exact reference an
      earlier arrival was waiting on).
    * `notify_capability/2` — cast by `Commonplace.Store.TrustSideStore`
      after a capability cert is durably stored (might be the exact cert an
      `:awaiting_capability` deferral was waiting on).
    * A periodic sweep (`@default_sweep_interval_ms`, overridable via
      `Application.get_env(:commonplace, :pending_imports_sweep_interval_ms,
      ...)`, or disabled with `:infinity`) — the liveness backstop. A
      dropped cast (message loss, a crash between put and cast, whatever)
      must only ever DELAY a retry, never wedge it permanently; the sweep
      guarantees forward progress independent of any specific notification
      firing.

  ## Structural guarantee: no private validation shortcut

  Every re-submission in this module goes through
  `Commonplace.Store.CommitStore.import_commit/3` — the SAME public front
  door a first-time arrival uses. There is NO private "just check the one
  thing that was missing and skip the rest" path here. This means the full
  gate pipeline (trust, code-doc-delta-merge, namespace — see
  `CommitStore`'s `import_validation/3`) re-runs on EVERY retry, by
  construction. A commit held for `:awaiting_capability` that has, by retry
  time, ALSO become invalid for an unrelated reason (trust config changed
  underneath it, say) is rejected again, not silently landed. This makes
  the historical bug class "the retry path skips a gate the first attempt
  enforced" structurally unrepresentable — there is no code path here that
  COULD skip a gate, because there is no code path here that validates at
  all; validation lives entirely in `CommitStore.import_commit/3`.

  ## The queue is in-memory by design

  `state.pending` is plain process state — a crash of this GenServer loses
  it, exactly the same loss semantics `CommitStore` itself had before this
  carve-out (the queue used to be CommitStore's own state, and a
  CommitStore crash lost it the same way). What's different post-carve-out
  is blast radius: a `PendingImports` crash no longer takes the whole
  commit-write path down with it (see `Commonplace.Store.Supervisor`'s
  `rest_for_one` — a PendingImports crash restarts PendingImports alone,
  CommitStore is unaffected). Catch-up sync re-sends on restart, so a lost
  queue is a delay, not a correctness gap.

  Persisting this queue (making it durable across restarts) is a decision
  nobody should make silently while "fixing" a bug here — it changes the
  loss/replay contract catch-up sync is built around and needs its own
  design pass, not a quiet addition to a bug fix.
  """

  use GenServer

  alias Commonplace.Store.CommitStore

  # R11 (CX-tdkq.11): cap on commits held awaiting an out-of-order
  # dependency. Beyond this we fall back to a hard reject (as before) rather
  # than grow memory unbounded — a small queue, not a durable store.
  @max_pending_imports 1024

  # Liveness-backstop sweep interval. Overridable via
  # `config :commonplace, pending_imports_sweep_interval_ms: ms | :infinity`
  # or the `:sweep_interval_ms` start opt (tests want this short, or
  # disabled entirely with `:infinity`).
  @default_sweep_interval_ms 45_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Hold a rejected commit for retry. `reason` is whatever the gate that
  rejected it returned (`:awaiting_capability`, or a namespace reason like
  `{:unknown_reference, id}`) — kept only for telemetry, not re-inspected
  on retry (retry re-runs the FULL pipeline regardless of why it was
  originally held). Fire-and-forget cast: a bare `CommitStore` instance
  with no `PendingImports` companion running can still call this safely
  (casting to an unregistered name is a no-op, not an error) — the commit
  is then simply hard-rejected with no retry, same as pre-carve-out
  behavior when the queue was full.
  """
  def enqueue(server \\ __MODULE__, commit, opts, reason) do
    GenServer.cast(server, {:enqueue, commit, opts, reason})
  end

  @doc "Notify that a commit landed — re-submit the whole held queue."
  def notify_landed(server \\ __MODULE__, commit_id) do
    GenServer.cast(server, {:notify_landed, commit_id})
  end

  @doc "Notify that a capability cert landed — re-submit the whole held queue."
  def notify_capability(server \\ __MODULE__, cid) do
    GenServer.cast(server, {:notify_capability, cid})
  end

  @doc "Test/introspection helper: how many commits are currently held."
  def pending_count(server \\ __MODULE__), do: GenServer.call(server, :pending_count)

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    commit_store = Keyword.get(opts, :commit_store, CommitStore)

    interval =
      Keyword.get(
        opts,
        :sweep_interval_ms,
        Application.get_env(
          :commonplace,
          :pending_imports_sweep_interval_ms,
          @default_sweep_interval_ms
        )
      )

    timer_ref = schedule_sweep(interval)

    {:ok,
     %{
       name: name,
       commit_store: commit_store,
       pending: %{},
       sweep_interval_ms: interval,
       sweep_timer: timer_ref
     }}
  end

  @impl true
  def handle_cast({:enqueue, commit, opts, reason}, state) do
    {:noreply, maybe_queue_pending(commit, opts, reason, state)}
  end

  @impl true
  def handle_cast({:notify_landed, _commit_id}, state) do
    {:noreply, retry_all(state)}
  end

  @impl true
  def handle_cast({:notify_capability, _cid}, state) do
    {:noreply, retry_all(state)}
  end

  @impl true
  def handle_call(:pending_count, _from, state) do
    {:reply, map_size(state.pending), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    state = retry_all(state)
    timer_ref = schedule_sweep(state.sweep_interval_ms)
    {:noreply, %{state | sweep_timer: timer_ref}}
  end

  defp schedule_sweep(:infinity), do: nil

  defp schedule_sweep(ms) when is_integer(ms) and ms > 0,
    do: Process.send_after(self(), :sweep, ms)

  defp schedule_sweep(_), do: nil

  defp maybe_queue_pending(commit, opts, reason, state) do
    pending = state.pending

    cond do
      Map.has_key?(pending, commit.id) ->
        state

      map_size(pending) >= @max_pending_imports ->
        # Queue full — leave it hard-rejected (telemetry already fired by
        # CommitStore's caller before it reached us).
        state

      true ->
        :telemetry.execute(
          [:commonplace, :commit, :deferred, :out_of_order],
          %{system_time: System.system_time()},
          %{commit_id: commit.id, doc_uuid: commit.doc_uuid, reason: reason}
        )

        %{state | pending: Map.put(pending, commit.id, {commit, opts})}
    end
  end

  # Re-submit the WHOLE queue, unconditionally, through the NORMAL public
  # front door (CommitStore.import_commit/3) every time — see the
  # moduledoc's "Structural guarantee" section. A commit that lands here
  # unblocks its own removal AND, via CommitStore's own notify_landed cast
  # back to us, triggers another pass shortly after (mailbox-driven
  # cascade) — so a chain of N out-of-order commits resolves within a few
  # quick round trips, not necessarily one single pass.
  defp retry_all(state) do
    Enum.reduce(state.pending, state, fn {id, {commit, opts}}, st ->
      case CommitStore.import_commit(st.commit_store, commit, opts) do
        :ok -> %{st | pending: Map.delete(st.pending, id)}
        :already_exists -> %{st | pending: Map.delete(st.pending, id)}
        {:error, _reason} -> st
      end
    end)
  end
end
