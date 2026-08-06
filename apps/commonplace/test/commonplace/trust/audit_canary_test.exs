defmodule Commonplace.Trust.AuditCanaryTest do
  @moduledoc """
  CX-t3xv acceptance criterion 3: the canary denial round-trips on
  schedule, and **killing the auditor makes the canary alarm fire** —
  the deadman proven able to go red.

  A deadman switch that has never been observed firing is not a deadman
  switch; it is a comment. Every alarm branch below is provoked on
  purpose, because "it would alarm" is exactly the claim the previous
  build's silence was made of.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Trust.{AuditCanary, AuditDispatcher, AuditLog}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_audit_canary_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"acn_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"acn_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"acn_tss_#{n}",
       pending_imports_name: :"acn_pi_#{n}"}
    )

    old = %{
      gate: Application.get_env(:commonplace, :local_write_gate),
      trust: Application.get_env(:commonplace, :trust),
      data_dir: Application.get_env(:commonplace, :data_dir)
    }

    Application.put_env(:commonplace, :data_dir, dir)

    on_exit(fn ->
      AuditLog.detach()
      put_or_del(:local_write_gate, old.gate)
      put_or_del(:trust, old.trust)
      put_or_del(:data_dir, old.data_dir)
      File.rm_rf!(dir)
    end)

    AuditLog.reset_rate_table()

    sup = :"acn_tasks_#{n}"
    dispatcher = :"acn_disp_#{n}"
    start_supervised!({Task.Supervisor, name: sup})

    start_supervised!(
      {AuditDispatcher,
       name: dispatcher, store: store, task_supervisor: sup, flush_ms: 10, enabled: true}
    )

    %{store: store, n: n, dispatcher: dispatcher}
  end

  defp put_or_del(key, nil), do: Application.delete_env(:commonplace, key)
  defp put_or_del(key, v), do: Application.put_env(:commonplace, key, v)

  defp strict_enforce! do
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)
  end

  defp start_canary!(ctx, opts \\ []) do
    name = :"acn_canary_#{ctx.n}_#{:rand.uniform(1_000_000)}"

    start_supervised!(
      {AuditCanary,
       opts ++
         [
           name: name,
           store: ctx.store,
           dispatcher: ctx.dispatcher,
           enabled: true,
           bound_ms: 3_000,
           # Never let the timer fire during a test; every tick here is
           # explicit, so a pass cannot come from a tick nobody asked for.
           interval_ms: 3_600_000,
           start_delay_ms: 3_600_000
         ]},
      id: name
    )

    name
  end

  # ── GREEN: the round trip ────────────────────────────────────────────

  test "the canary's provoked denial round-trips through BOTH mechanisms", ctx do
    AuditLog.attach(ctx.store, dispatcher: ctx.dispatcher)
    strict_enforce!()
    canary = start_canary!(ctx)

    verdict = AuditCanary.tick_now(canary)

    assert verdict.result == :ok, "canary did not round-trip: #{inspect(verdict)}"

    {a0, a1} = verdict.a
    {b0, b1} = verdict.b

    # Never a bare verdict: both sides actually MOVED.
    assert a1 > a0, "mechanism A did not advance: #{inspect(verdict)}"
    assert b1 > b0, "mechanism B did not advance: #{inspect(verdict)}"
    assert verdict.parity.in_parity

    status = AuditCanary.status(canary)
    assert status.ticks == 1
    assert status.passes == 1
    assert status.alarms == 0
    assert status.handler_attached
  end

  test "the canary provokes a REAL denial — it does not simulate one", ctx do
    AuditLog.attach(ctx.store, dispatcher: ctx.dispatcher)
    strict_enforce!()
    canary = start_canary!(ctx)

    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {:canary_denial_probe, ref},
      [:commonplace, :commit, :rejected, :local_trust],
      fn _e, _m, meta, _ -> send(parent, {:denied, ref, meta.doc_uuid}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({:canary_denial_probe, ref}) end)

    AuditCanary.tick_now(canary)

    canary_uuid = AuditCanary.canary_uuid()

    # Selective receive on the canary's OWN doc: any other denial in
    # flight is not evidence about this one.
    assert_receive {:denied, ^ref, ^canary_uuid}, 3_000

    # LAYER 1: the provoked write really was refused, nothing landed.
    assert :none = Commonplace.Store.CommitStore.latest_commit(ctx.store, canary_uuid)
  end

  # ── RED: killing the auditor makes the canary fire ───────────────────

  test "RED CONTROL: detaching the telemetry handler makes the canary ALARM", ctx do
    AuditLog.attach(ctx.store, dispatcher: ctx.dispatcher)
    strict_enforce!()
    canary = start_canary!(ctx)

    assert AuditCanary.tick_now(canary).result == :ok, "precondition: canary green"

    # Kill the auditor exactly the way the CX-t3xv defect killed it.
    AuditLog.detach()

    verdict = AuditCanary.tick_now(canary)

    assert verdict.result == :alarm
    assert verdict.reason == :handler_detached
    assert verdict.message =~ "ENFORCED"

    status = AuditCanary.status(canary)
    assert status.alarms == 1
    refute status.handler_attached
  end

  test "RED CONTROL: an auditor that cannot PERSIST alarms too (attached is not enough)", ctx do
    # The subtler death: the handler is attached, the events flow, and
    # the substrate write is refused. "Handler attached" would report
    # green; the round-trip check does not.
    sup = :"acn_broken_tasks_#{ctx.n}"
    broken = :"acn_broken_disp_#{ctx.n}"
    start_supervised!({Task.Supervisor, name: sup}, id: sup)

    start_supervised!(
      {AuditDispatcher,
       name: broken,
       store: ctx.store,
       task_supervisor: sup,
       flush_ms: 10,
       enabled: true,
       # CX-oc30, restored: unsigned audit writes.
       signing_context_fn: fn -> {:ok, :unsigned} end},
      id: broken
    )

    AuditLog.attach(ctx.store, dispatcher: broken)
    strict_enforce!()

    canary = start_canary!(Map.put(ctx, :dispatcher, broken), bound_ms: 1_000)

    verdict = AuditCanary.tick_now(canary)

    assert verdict.result == :alarm
    assert verdict.reason == :round_trip_timeout
    assert AuditLog.attached?(), "the handler IS attached — that is the point of this control"
    assert :mechanism_b_substrate in verdict.short
  end

  test "RED CONTROL: parity divergence alarms even when the round trip succeeds", ctx do
    AuditLog.attach(ctx.store, dispatcher: ctx.dispatcher)
    strict_enforce!()
    canary = start_canary!(ctx)

    assert AuditCanary.tick_now(canary).result == :ok, "precondition: canary green"

    # Advance mechanism A without B — the shape of a sink that reports
    # success it did not achieve.
    :sys.replace_state(Process.whereis(ctx.dispatcher), fn s ->
      %{s | recorded: s.recorded + 7}
    end)

    verdict = AuditCanary.tick_now(canary)

    assert verdict.result == :alarm
    assert verdict.reason == :parity_divergence
    refute verdict.parity.in_parity
  end

  # ── A skipped canary must never read as green ────────────────────────

  test "with the write gate OFF the canary reports SKIPPED, not a pass", ctx do
    AuditLog.attach(ctx.store, dispatcher: ctx.dispatcher)
    Application.put_env(:commonplace, :local_write_gate, :off)
    canary = start_canary!(ctx)

    verdict = AuditCanary.tick_now(canary)

    assert verdict.result == :skipped
    assert verdict.reason == :write_gate_off

    status = AuditCanary.status(canary)
    assert status.skips == 1

    assert status.passes == 0,
           "a canary that did not run must NEVER be counted as a pass — that is how " <>
             "dormancy disguises itself as health"
  end

  test "the schedule and the enable knob are visible in status", ctx do
    canary = start_canary!(ctx, interval_ms: 1_234, bound_ms: 99)
    status = AuditCanary.status(canary)

    assert status.enabled
    assert status.interval_ms == 1_234
    assert status.bound_ms == 99
  end

  test "a disabled canary schedules nothing", ctx do
    name = :"acn_off_#{ctx.n}"

    start_supervised!(
      {AuditCanary,
       name: name,
       store: ctx.store,
       dispatcher: ctx.dispatcher,
       enabled: false,
       start_delay_ms: 1},
      id: name
    )

    Process.sleep(50)
    status = AuditCanary.status(name)
    refute status.enabled
    assert status.ticks == 0
  end

  # ── The scheduled path, not just the manual one ──────────────────────

  test "the canary ticks on its SCHEDULE, unattended", ctx do
    AuditLog.attach(ctx.store, dispatcher: ctx.dispatcher)
    strict_enforce!()

    name = :"acn_sched_#{ctx.n}"

    start_supervised!(
      {AuditCanary,
       name: name,
       store: ctx.store,
       dispatcher: ctx.dispatcher,
       enabled: true,
       bound_ms: 2_000,
       interval_ms: 50,
       start_delay_ms: 10},
      id: name
    )

    # Poll for the unattended tick rather than sleeping a guessed amount.
    assert eventually(fn -> AuditCanary.status(name).ticks >= 2 end, 5_000),
           "the canary never ticked on its own: #{inspect(AuditCanary.status(name))}"

    status = AuditCanary.status(name)
    assert status.passes >= 1, "unattended ticks did not pass: #{inspect(status)}"
  end

  defp eventually(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(25) && do_eventually(fun, deadline)
    end
  end
end
