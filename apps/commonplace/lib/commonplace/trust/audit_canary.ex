defmodule Commonplace.Trust.AuditCanary do
  @moduledoc """
  The deadman switch for denial auditing (CX-t3xv, brief §5).

  ## Why a canary and not a review item

  The class-specific failure of an observability subsystem is **dormancy
  nobody notices**: it has no user until the day it has an urgent one,
  and on that day the discovery is "it has been dead since the deploy."
  That is not hypothetical here — it is this subsystem's actual history.
  The audit log shipped in CX-hilo, was killed by two independent
  mechanisms, and stayed dead because nothing ever asked whether it was
  alive.

  So "is it started?" is converted from a question someone must remember
  to ask into **a running check**: a dedicated no-rights principal
  attempts a write on a schedule, the resulting denial MUST round-trip
  through BOTH mechanisms within a bound, and its absence fires an
  alarm. The canary is the audit auditing itself. Dormancy is henceforth
  an ALARM, not a discovery.

  ## What one tick does

  1. Read the posture. If `:local_write_gate` is `:off` there is no
     denial to provoke; the tick reports `:skipped` with that reason and
     is **not** counted as a pass. A canary that reports green when it
     did not run is the failure mode it exists to prevent.
  2. Snapshot mechanism A (`AuditDispatcher.status/0` counters) and
     mechanism B (records in the substrate audit doc for this boot).
  3. Provoke: write to the canary doc as a principal with no rights —
     an unsigned commit, which under `accept_unsigned: false` the local
     write gate refuses. The refusal is the point; the write is not
     expected to land.
  4. Wait up to `:bound_ms` for BOTH A and B to advance.
  5. Verdict:
     * both advanced → `:ok`;
     * either did not → **alarm** (`Logger.error`, telemetry, red
       broadcast), naming which side is short. Killing the auditor makes
       this fire — that is the deadman proven able to go red.
  6. Run the standing COUNT PARITY probe (`AuditDispatcher.parity/1`)
     and alarm separately on divergence. Two sinks that can silently
     diverge are worse than one; parity is what makes two stronger.

  ## The dry_run residue, stated rather than hidden

  Under `:dry_run` the gate LOGS a would-deny and the write still lands,
  so the canary doc accumulates one small commit per tick. Under
  `:enforce` — the deployed posture, and the one that matters — nothing
  lands, because the write is refused. The residue is bounded by the
  tick interval and is called out here rather than discovered later.

  ## Not a policy actor

  The canary never grants, revokes, refuses, or repairs anything. It
  provokes a denial that would be denied anyway and reads two counters.
  It is alarm and only alarm, the same posture
  `Commonplace.Invariants.Dispatcher` holds.
  """

  use GenServer

  require Logger

  alias Commonplace.Trust.AuditDispatcher

  @default_interval_ms 15 * 60_000
  @default_bound_ms 5_000

  @doc "The dedicated canary doc. Nothing else ever writes here."
  def canary_uuid, do: UUID.uuid5(:url, "urn:commonplace:trust-audit-canary")

  @doc """
  Starts the canary.

    * `:enabled` — default `Application.get_env(:commonplace,
      :audit_canary_enabled, true)`. The knob is visible in
      `status/0`, so "disabled" is a reportable state and not an
      invisible one.
    * `:interval_ms` — default 15 minutes, or
      `:audit_canary_interval_ms`.
    * `:bound_ms` — how long a denial has to round-trip (default 5s).
    * `:store`, `:dispatcher` — injectable for tests.
    * `:start_delay_ms` — delay before the first tick, so boot is not
      the busiest moment.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Last verdict, the knob, and the counters behind it. Never a bare
  verdict: a canary that says `:alarm` without saying which mechanism
  was short is unactionable.
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status, 30_000)

  @doc "Run one tick synchronously and return its verdict (tests/ops)."
  @spec tick_now(GenServer.server(), timeout()) :: map()
  def tick_now(server \\ __MODULE__, timeout \\ 30_000),
    do: GenServer.call(server, :tick_now, timeout)

  @impl true
  def init(opts) do
    state = %{
      enabled: Keyword.get(opts, :enabled, Application.get_env(:commonplace, :audit_canary_enabled, true)),
      interval_ms:
        Keyword.get(
          opts,
          :interval_ms,
          Application.get_env(:commonplace, :audit_canary_interval_ms, @default_interval_ms)
        ),
      bound_ms: Keyword.get(opts, :bound_ms, @default_bound_ms),
      store: Keyword.get(opts, :store, Commonplace.Store.CommitStoreClient),
      dispatcher: Keyword.get(opts, :dispatcher, AuditDispatcher),
      ticks: 0,
      passes: 0,
      alarms: 0,
      skips: 0,
      last: nil,
      last_at: nil
    }

    if state.enabled do
      Process.send_after(self(), :tick, Keyword.get(opts, :start_delay_ms, state.interval_ms))
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       enabled: state.enabled,
       interval_ms: state.interval_ms,
       bound_ms: state.bound_ms,
       ticks: state.ticks,
       passes: state.passes,
       alarms: state.alarms,
       skips: state.skips,
       last: state.last,
       last_at: state.last_at,
       # The cheapest precondition of all, and the one whose silent
       # falsification WAS the defect.
       handler_attached: Commonplace.Trust.AuditLog.attached?()
     }, state}
  end

  def handle_call(:tick_now, _from, state) do
    {verdict, state} = run_tick(state)
    {:reply, verdict, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {_verdict, state} = run_tick(state)
    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── the tick ─────────────────────────────────────────────────────────

  defp run_tick(state) do
    verdict = do_tick(state)

    state = %{
      state
      | ticks: state.ticks + 1,
        last: verdict,
        last_at: DateTime.utc_now(),
        passes: state.passes + if(verdict.result == :ok, do: 1, else: 0),
        alarms: state.alarms + if(verdict.result == :alarm, do: 1, else: 0),
        skips: state.skips + if(verdict.result == :skipped, do: 1, else: 0)
    }

    {verdict, state}
  end

  defp do_tick(state) do
    gate = Application.get_env(:commonplace, :local_write_gate, :dry_run)

    cond do
      gate == :off ->
        # NOT a pass. A skipped canary is a canary that did not witness
        # anything, and it must never read as green.
        skipped(:write_gate_off)

      not Commonplace.Trust.AuditLog.attached?() ->
        alarm(
          :handler_detached,
          %{},
          "the trust-audit telemetry handler is NOT ATTACHED — denials are still being " <>
            "ENFORCED, but nothing is recording them. This is the exact CX-t3xv failure."
        )

      true ->
        provoke_and_check(state, gate)
    end
  end

  defp provoke_and_check(state, gate) do
    a0 = mechanism_a(state)
    b0 = mechanism_b(state)

    case {a0, b0} do
      {nil, _} ->
        alarm(:dispatcher_unavailable, %{}, "AuditDispatcher is not running")

      {_, :unreadable} ->
        alarm(:substrate_unreadable, %{a: a0}, "could not read the substrate audit doc")

      _ ->
        provoke(state)

        case await(state, a0, b0) do
          {:ok, a1, b1} ->
            # Compare the two mechanisms at QUIESCENCE. Mechanism A's
            # counter is bumped when a persist task reports back, while
            # mechanism B's records are visible the moment the commit
            # lands — so a batch in flight can legitimately put B ahead
            # of A for a few milliseconds. Alarming on that would be a
            # false positive, and a deadman that cries wolf gets muted,
            # which is the failure this whole build exists to prevent.
            _ = AuditDispatcher.flush(state.dispatcher, state.bound_ms)

            parity = AuditDispatcher.parity(state.dispatcher)

            if parity.in_parity do
              %{result: :ok, gate: gate, a: {a0, a1}, b: {b0, b1}, parity: parity}
            else
              alarm(
                :parity_divergence,
                %{a: {a0, a1}, b: {b0, b1}, parity: parity},
                "mechanism A and mechanism B disagree on the denial count for this boot " <>
                  "(a=#{inspect(parity.a)} b=#{inspect(parity.b)}) — one of the two sinks is " <>
                  "losing records"
              )
            end

          {:timeout, a1, b1} ->
            short =
              [
                if(a1 <= a0, do: :mechanism_a_in_band),
                if(b1 == :unreadable or b1 <= b0, do: :mechanism_b_substrate)
              ]
              |> Enum.reject(&is_nil/1)

            alarm(
              :round_trip_timeout,
              %{a: {a0, a1}, b: {b0, b1}, short: short, bound_ms: state.bound_ms},
              "a deliberately provoked denial did NOT round-trip within #{state.bound_ms}ms. " <>
                "Short: #{inspect(short)}. Denials are still being ENFORCED; they are not " <>
                "being RECORDED."
            )
        end
    end
  end

  # A no-rights principal: an UNSIGNED write. Under
  # `accept_unsigned: false` the local write gate refuses it, which is
  # the denial the canary needs. No capability is minted, no policy is
  # touched, and nothing is granted to anyone — the canary's whole
  # authority is that it has none.
  defp provoke(state) do
    update =
      Yelixer.Doc.new()
      |> Commonplace.Document.ContentType.create(:text, "canary.txt")
      |> Commonplace.Document.ContentType.insert_text(
        0,
        "canary #{DateTime.utc_now() |> DateTime.to_iso8601()}"
      )
      |> Yelixer.Encoding.encode_update()

    Commonplace.Store.CommitStoreClient.create_chained_commit(
      state.store,
      canary_uuid(),
      update,
      %{},
      # Explicitly unsigned: never let an ambient identity accidentally
      # give the canary rights, which would make it stop provoking a
      # denial and start silently passing for the wrong reason.
      signing_context: :unsigned
    )
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  catch
    kind, value -> {:error, {kind, value}}
  end

  defp await(state, a0, b0) do
    deadline = System.monotonic_time(:millisecond) + state.bound_ms
    poll(state, a0, b0, deadline)
  end

  defp poll(state, a0, b0, deadline) do
    a1 = mechanism_a(state) || a0
    b1 = mechanism_b(state)

    cond do
      is_integer(b1) and a1 > a0 and b1 > b0 ->
        {:ok, a1, b1}

      System.monotonic_time(:millisecond) >= deadline ->
        {:timeout, a1, b1}

      true ->
        Process.sleep(100)
        poll(state, a0, b0, deadline)
    end
  end

  # Mechanism A: the in-band counter surface.
  defp mechanism_a(state) do
    case AuditDispatcher.status(state.dispatcher) do
      %{recorded: n} -> n
      _ -> nil
    end
  end

  # Mechanism B: the substrate red-log doc, this boot only.
  defp mechanism_b(state) do
    case AuditDispatcher.status(state.dispatcher) do
      %{boot_id: boot_id} -> AuditDispatcher.count_substrate_records(state.store, boot_id)
      _ -> :unreadable
    end
  end

  defp skipped(reason) do
    %{result: :skipped, reason: reason}
  end

  defp alarm(reason, details, message) do
    Logger.error("Commonplace.Trust.AuditCanary: ALARM (#{reason}) — #{message}")

    :telemetry.execute(
      [:commonplace, :trust, :audit, :canary_alarm],
      %{count: 1},
      Map.merge(details, %{reason: reason})
    )

    Commonplace.Dataflow.PubSub.broadcast_red(
      canary_uuid(),
      {:trust, :audit_canary_alarm, Map.merge(details, %{reason: reason, message: message})}
    )

    Map.merge(details, %{result: :alarm, reason: reason, message: message})
  end
end
