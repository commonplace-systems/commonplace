defmodule Commonplace.Trust.AuditDispatcherTest do
  @moduledoc """
  CX-t3xv acceptance criteria 2 (bounded queue + LOUD loss counter, zero
  silent shedding) and 4 (count parity goes red when one mechanism is
  suppressed).

  Both are denominator-rule tests. "12 denials recorded" is not a
  measurement — "12 recorded out of 1200 offered, 1188 shed" and
  "12 recorded out of 12 offered, 0 shed" are the same sentence with
  opposite meanings, and an audit stream that cannot tell them apart is
  the silent-underreport pattern auditing itself.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Trust.{AuditDispatcher, AuditLog}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_audit_disp_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"adt_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"adt_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"adt_tss_#{n}",
       pending_imports_name: :"adt_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    on_exit(fn ->
      if old_data_dir,
        do: Application.put_env(:commonplace, :data_dir, old_data_dir),
        else: Application.delete_env(:commonplace, :data_dir)

      File.rm_rf!(dir)
    end)

    %{store: store, n: n}
  end

  defp start_dispatcher!(store, n, opts \\ []) do
    sup = :"adt_tasks_#{n}_#{:rand.uniform(1_000_000)}"
    name = :"adt_disp_#{n}_#{:rand.uniform(1_000_000)}"
    start_supervised!({Task.Supervisor, name: sup}, id: sup)

    start_supervised!(
      # `opts` FIRST: Keyword.get takes the first occurrence, so a test
      # that overrides `enabled:`/`max_queue:` must win over the defaults.
      {AuditDispatcher,
       opts ++ [name: name, store: store, task_supervisor: sup, flush_ms: 20, enabled: true]},
      id: name
    )

    name
  end

  defp record(i), do: %{"event" => "test.denial", "doc_uuid" => "doc-#{i}", "reason" => ":unsigned"}

  # ── AC2: overflow increments a VISIBLE loss counter ──────────────────

  test "a deliberately induced overflow increments the loss counter — zero silent shedding",
       %{store: store, n: n} do
    # A tiny queue and a flush window long enough that nothing drains
    # while the burst is being offered — the overflow is engineered, not
    # hoped for.
    dispatcher = start_dispatcher!(store, n, max_queue: 5, flush_ms: 60_000)

    offered = 50
    for i <- 1..offered, do: AuditDispatcher.offer(dispatcher, record(i))

    status = AuditDispatcher.status(dispatcher)

    assert status.offered == offered
    assert status.shed > 0, "an overflow that sheds nothing is not an overflow: #{inspect(status)}"

    # The point of the criterion: events offered vs recorded vs shed SUM.
    assert AuditDispatcher.accounted?(status),
           "the audit stream lost events without accounting for them: #{inspect(status)}"

    assert status.shed == offered - status.queued - status.recorded - status.failed -
                            status.guarded - status.in_flight
  end

  # The control that makes the overflow test mean something: the SAME
  # burst against the DEFAULT bound must shed nothing. Without this, a
  # `shed > 0` assertion could be passing because the dispatcher sheds
  # indiscriminately rather than because the bound was reached — and a
  # counter that always fires is as uninformative as one that never does.
  test "CONTROL: the same burst under the default bound sheds NOTHING",
       %{store: store, n: n} do
    dispatcher = start_dispatcher!(store, n, flush_ms: 60_000)

    for i <- 1..50, do: AuditDispatcher.offer(dispatcher, record(i))

    status = AuditDispatcher.status(dispatcher)

    assert status.offered == 50
    assert status.shed == 0, "shedding below the bound: #{inspect(status)}"
    assert status.queued == 50
    assert AuditDispatcher.accounted?(status)
  end

  test "the loss counter is LOUD — shedding emits telemetry, not just a field",
       %{store: store, n: n} do
    dispatcher = start_dispatcher!(store, n, max_queue: 2, flush_ms: 60_000)

    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {:shed_probe, ref},
      [:commonplace, :trust, :audit, :shed],
      fn _e, meas, meta, _ -> send(parent, {:shed, ref, meas, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({:shed_probe, ref}) end)

    for i <- 1..20, do: AuditDispatcher.offer(dispatcher, record(i))

    assert_receive {:shed, ^ref, meas, meta}, 1_000
    assert meas.count == 1
    assert meta.reason == :queue_full
    assert is_integer(meas.shed_total)
  end

  test "a disabled dispatcher SHEDS with a reason — it does not silently accept",
       %{store: store, n: n} do
    dispatcher = start_dispatcher!(store, n, enabled: false)

    AuditDispatcher.offer(dispatcher, record(1))

    status = AuditDispatcher.status(dispatcher)
    assert status.offered == 1
    assert status.shed == 1
    assert status.recorded == 0
    refute status.enabled
    assert AuditDispatcher.accounted?(status)
  end

  test "offering to a dead dispatcher never raises into the deny site", %{store: store, n: n} do
    dispatcher = start_dispatcher!(store, n)
    stop_supervised!(dispatcher)

    # The deny site must not care. Losing the RECORD must never turn
    # into losing the ENFORCEMENT.
    assert :ok = AuditDispatcher.offer(dispatcher, record(1))
    assert :ok = AuditDispatcher.offer(:nonexistent_dispatcher_name_xyz, record(2))
  end

  # ── AC4: parity goes red when one mechanism is suppressed ────────────

  test "parity is green when both mechanisms see the same denials", %{store: store, n: n} do
    dispatcher = start_dispatcher!(store, n)

    for i <- 1..3, do: AuditDispatcher.offer(dispatcher, record(i))
    assert :ok = AuditDispatcher.flush(dispatcher, 5_000)

    parity = AuditDispatcher.parity(dispatcher)

    assert parity.a == 3
    assert parity.b == 3
    assert parity.in_parity
  end

  test "RED CONTROL: suppressing mechanism B (the substrate doc) turns parity RED",
       %{store: store, n: n} do
    dispatcher = start_dispatcher!(store, n)

    for i <- 1..3, do: AuditDispatcher.offer(dispatcher, record(i))
    assert :ok = AuditDispatcher.flush(dispatcher, 5_000)
    assert AuditDispatcher.parity(dispatcher).in_parity, "precondition: parity green"

    # Suppress B by advancing mechanism A alone — exactly what a
    # persist that reports success without landing would look like.
    :sys.replace_state(Process.whereis(dispatcher), fn s -> %{s | recorded: s.recorded + 5} end)

    parity = AuditDispatcher.parity(dispatcher)

    refute parity.in_parity,
           "a mechanism-B shortfall must show up as a parity ALARM: #{inspect(parity)}"

    assert parity.a == 8
    assert parity.b == 3

    # Never a bare verdict — the shapes needed to act are present.
    assert Map.has_key?(parity, :shed)
    assert Map.has_key?(parity, :failed)
    assert Map.has_key?(parity, :guarded)
  end

  test "RED CONTROL: suppressing mechanism A (the in-band counter) turns parity RED",
       %{store: store, n: n} do
    dispatcher = start_dispatcher!(store, n)

    for i <- 1..3, do: AuditDispatcher.offer(dispatcher, record(i))
    assert :ok = AuditDispatcher.flush(dispatcher, 5_000)
    assert AuditDispatcher.parity(dispatcher).in_parity, "precondition: parity green"

    :sys.replace_state(Process.whereis(dispatcher), fn s -> %{s | recorded: 0} end)

    parity = AuditDispatcher.parity(dispatcher)
    refute parity.in_parity, "a mechanism-A shortfall must be an ALARM too: #{inspect(parity)}"
    assert parity.a == 0
    assert parity.b == 3
  end

  test "parity reports NOT-in-parity (never green) when there is no dispatcher at all" do
    parity = AuditDispatcher.parity(:no_such_dispatcher_at_all)

    refute parity.in_parity,
           "an unmeasurable parity must never read as green — that is how dormancy hides"

    assert parity.reason == :no_dispatcher
  end

  # ── boot scoping: B's count is this node's boot, not the whole file ──

  test "mechanism B counts only THIS boot's records, so a shared doc cannot inflate parity",
       %{store: store, n: n} do
    first = start_dispatcher!(store, n, boot_id: "boot-one")
    for i <- 1..2, do: AuditDispatcher.offer(first, record(i))
    assert :ok = AuditDispatcher.flush(first, 5_000)

    second = start_dispatcher!(store, n, boot_id: "boot-two")
    AuditDispatcher.offer(second, record(99))
    assert :ok = AuditDispatcher.flush(second, 5_000)

    # The doc holds three records; each dispatcher sees only its own.
    all = AuditLog.log_uuid() |> RedLog.load(store) |> RedLog.read()
    assert length(all) == 3

    assert AuditDispatcher.parity(first) |> Map.take([:a, :b, :in_parity]) ==
             %{a: 2, b: 2, in_parity: true}

    assert AuditDispatcher.parity(second) |> Map.take([:a, :b, :in_parity]) ==
             %{a: 1, b: 1, in_parity: true}
  end
end
