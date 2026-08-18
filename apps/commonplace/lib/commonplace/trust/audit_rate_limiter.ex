defmodule Commonplace.Trust.AuditRateLimiter do
  @moduledoc """
  Supervised owner and timer-driven flusher for denial-audit rate windows.

  Admission never enters this process's mailbox. Denial emitters increment a
  public ETS counter directly through `admit/3`; this process exists so the
  table has one permanent, supervised owner and so expired suppression counts
  become durable audit records even when that bucket receives no later event.

  The logical bucket is `{event_name, doc_uuid}`. The ETS key also contains the
  fixed window start. Keeping successive windows in distinct rows removes the
  boundary race in which a first event in the new window could overwrite the
  old window before its summary was flushed. Expired rows are deleted on every
  sweep, bounding table growth to recently active document buckets rather than
  the lifetime of the node.
  """

  use GenServer

  alias Commonplace.Trust.{AuditDispatcher, AuditLogCounter, DenialCounter}

  @table :commonplace_trust_audit_log_rate
  @failed_open_counter_key {__MODULE__, :failed_open_boot_counter}
  @window_ms 60_000
  @cap 20
  @sweep_ms 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The maximum admitted records in one `{event_name, doc}` window."
  def cap, do: @cap

  @doc "The fixed-window duration used by the audit gate."
  def window_ms, do: @window_ms

  @doc "The public ETS table owned by this supervised process."
  def table, do: @table

  @doc "Return the fail-open rescue count for this BEAM boot."
  @spec failed_open_snapshot() :: %{boot_id: String.t(), failed_open: non_neg_integer()}
  def failed_open_snapshot do
    {boot_id, counter} = failed_open_counter()
    %{boot_id: boot_id, failed_open: :atomics.get(counter, 1)}
  end

  @doc """
  Count an event at its emitting site and return its admission decision.

  `:ets.update_counter/4` is atomic and never waits on the owner mailbox. The
  stored count is total driven events; suppression is therefore exactly
  `driven - min(driven, cap)` and cannot drift from a second counter.
  """
  def admit(event_name, doc_uuid, dispatcher) do
    now = System.system_time(:millisecond)
    window_start = current_window(event_name, doc_uuid, now)
    key = {event_name, doc_uuid, window_start}
    driven = :ets.update_counter(@table, key, {2, 1}, {key, 0, dispatcher})

    if driven <= @cap, do: :log, else: :suppress
  rescue
    # A hard-killed owner is restarted by Commonplace.Supervisor. During that
    # narrow table-less interval, fail open for AUDIT RECORDING (the denial
    # itself remains enforced): never make an arbitrary emitting caller create
    # or own the table, and never turn lifecycle churn into silent audit loss.
    ArgumentError ->
      increment_failed_open_counter()

      :telemetry.execute(
        [:commonplace, :trust, :audit, :rate_limiter, :failed_open],
        %{count: 1},
        %{event_name: event_name, doc_uuid: doc_uuid}
      )

      :log
  end

  defp increment_failed_open_counter do
    {_boot_id, counter} = failed_open_counter()
    :atomics.add_get(counter, 1, 1)
  end

  defp failed_open_counter do
    case :persistent_term.get(@failed_open_counter_key, :missing) do
      :missing ->
        init_failed_open_counter()
        :persistent_term.get(@failed_open_counter_key)

      state ->
        state
    end
  end

  defp init_failed_open_counter do
    case :persistent_term.get(@failed_open_counter_key, :missing) do
      :missing ->
        counter = :atomics.new(1, signed: false)
        :persistent_term.put(@failed_open_counter_key, {DenialCounter.boot_id(), counter})
        :ok

      {_boot_id, _counter} ->
        :ok
    end
  end

  defp current_window(event_name, doc_uuid, now) do
    pointer = {:current, event_name, doc_uuid}

    case :ets.lookup(@table, pointer) do
      [{^pointer, window_start}] when now - window_start < @window_ms ->
        window_start

      [{^pointer, expired_start}] ->
        # ⚠️ MATCH-SPEC BODY ESCAPING: in a spec BODY an unescaped tuple is an
        # OPERATION, so splicing the pointer tuple raw makes the whole spec
        # invalid — select_replace then RAISES on every natural rollover and
        # the fail-open rescue admits unthrottled until the sweeper clears the
        # stale pointer (measured: ~1s of cap bypass per window boundary,
        # environment-latent because a sub-60s storm never rolls over).
        # {:const, term} returns the term literally and cannot mis-parse.
        replacement = [{{pointer, expired_start}, [], [{:const, {pointer, now}}]}]

        case :ets.select_replace(@table, replacement) do
          1 -> now
          0 -> current_window(event_name, doc_uuid, now)
        end

      [] ->
        if :ets.insert_new(@table, {pointer, now}) do
          now
        else
          current_window(event_name, doc_uuid, now)
        end
    end
  end

  @impl true
  def init(opts) do
    :ok = init_failed_open_counter()
    table = Keyword.get(opts, :table, @table)
    sweep_ms = Keyword.get(opts, :sweep_ms, @sweep_ms)
    window_ms = Keyword.get(opts, :window_ms, @window_ms)
    cap = Keyword.get(opts, :cap, @cap)

    ^table = :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep(sweep_ms)

    {:ok, %{table: table, sweep_ms: sweep_ms, window_ms: window_ms, cap: cap}}
  end

  @impl true
  def handle_info(:sweep_rate_windows, state) do
    flush_expired(state, System.system_time(:millisecond))
    schedule_sweep(state.sweep_ms)
    {:noreply, state}
  end

  def handle_info(:flush_rate_windows, state) do
    flush_expired(state, System.system_time(:millisecond))
    {:noreply, state}
  end

  defp flush_expired(state, now) do
    state.table
    |> :ets.tab2list()
    |> Enum.each(fn
      {{event_name, doc_uuid, window_start} = key, _driven, _dispatcher}
      when now - window_start >= state.window_ms ->
        flush_window(state, key, event_name, doc_uuid, window_start)

      _current_window ->
        :ok
    end)
  rescue
    # A concurrent test reset can clear rows between tab2list/take. A missing
    # row is already handled below; a missing table means this owner is dying.
    ArgumentError -> :ok
  end

  defp flush_window(state, key, event_name, doc_uuid, window_start) do
    case :ets.take(state.table, key) do
      [{^key, driven, dispatcher}] ->
        pointer = {:current, event_name, doc_uuid}
        :ets.select_delete(state.table, [{{pointer, window_start}, [], [true]}])
        admitted = min(driven, state.cap)
        suppressed = driven - admitted

        if suppressed > 0 do
          # DURABILITY BOUND: summaries already offered here live in the audit
          # doc and survive owner/app restart. A hard kill can erase only the
          # current, not-yet-expired window's ETS accrual (at most ONE window);
          # expired rows are swept every second and never need a later event.
          summary = %{
            "event" => "audit_log.rate_limited",
            "gate" => "audit_log",
            "check" => "rate_limit",
            "doc_uuid" => doc_uuid,
            "suppressed_event" => Enum.join(event_name, "."),
            "window_start_ms" => window_start,
            "window_ms" => state.window_ms,
            "driven" => driven,
            "admitted" => admitted,
            "suppressed" => suppressed,
            "summary" => true
          }

          AuditLogCounter.increment(:offered)
          AuditDispatcher.offer(dispatcher, summary)
        end

      [] ->
        :ok
    end
  end

  defp schedule_sweep(sweep_ms) do
    Process.send_after(self(), :sweep_rate_windows, sweep_ms)
  end
end
