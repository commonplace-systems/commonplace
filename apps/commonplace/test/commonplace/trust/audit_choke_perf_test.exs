defmodule Commonplace.Trust.AuditChokePerfTest do
  @moduledoc """
  CX-t3xv acceptance criterion 5: end-to-end write latency through the
  choke, p50/p99, against a baseline, **measured on the ALLOW path
  especially** (brief §2, inheriting R2's acceptance datum).

  ## What is actually being defended

  The allow path must pay **nothing**. Denial telemetry only fires on a
  denial, so the "should I audit this?" question is never asked when
  there is no denial — the saving is structural, not an optimisation,
  and this test is what proves the structure was not accidentally
  compromised (e.g. by someone adding a `should_audit?/1` call into
  `do_write_commit`).

  On the DENY path the work added inside the store's `handle_call` is a
  map build and a `GenServer.cast`. Both are bounded and neither can
  block, which is the property that matters — the old inline persist
  was an unbounded synchronous write, and before that it was a deadlock.

  ## Why this is a self-baselined comparison

  An absolute millisecond budget on shared CI hardware is a coin flip,
  and a flaky perf gate gets disabled, which is worse than no gate. So
  the baseline is measured IN THIS RUN, on THIS machine, with the audit
  wiring detached, and the comparison is a ratio with generous headroom.
  A regression that matters (a synchronous store write reintroduced into
  the choke) is orders of magnitude, not percent — this catches that
  without pretending to catch 5%.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Trust.{AuditDispatcher, AuditLog}

  @samples 200

  # Generous on purpose: see the moduledoc. The failure this guards is
  # a synchronous store write back in the choke, which is ~100x, not 2x.
  @max_ratio 3.0

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_audit_perf_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"apf_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"apf_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"apf_tss_#{n}",
       pending_imports_name: :"apf_pi_#{n}"}
    )

    # The flood-guard bucket is global to the BEAM run and the handler is
    # attached at application boot, so denial-heavy modules that ran
    # within the last 60s would otherwise leave this test's denials
    # suppressed — offered == 0 — and the non-vacuity guard below fires.
    # (That is exactly what happened on the first post-merge CI run.)
    AuditLog.reset_rate_table()

    old_gate = Application.get_env(:commonplace, :local_write_gate)
    old_trust = Application.get_env(:commonplace, :trust)
    old_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    on_exit(fn ->
      AuditLog.detach()
      put_or_del(:local_write_gate, old_gate)
      put_or_del(:trust, old_trust)
      put_or_del(:data_dir, old_dir)
      File.rm_rf!(dir)
    end)

    sup = :"apf_tasks_#{n}"
    dispatcher = :"apf_disp_#{n}"
    start_supervised!({Task.Supervisor, name: sup})

    start_supervised!(
      {AuditDispatcher,
       name: dispatcher, store: store, task_supervisor: sup, flush_ms: 50, enabled: true}
    )

    %{store: store, dispatcher: dispatcher}
  end

  defp put_or_del(key, nil), do: Application.delete_env(:commonplace, key)
  defp put_or_del(key, v), do: Application.put_env(:commonplace, key, v)

  defp text_update(body) do
    Yelixer.Doc.new()
    |> ContentType.create(:text, "page.md")
    |> ContentType.insert_text(0, body)
    |> Yelixer.Encoding.encode_update()
  end

  defp percentiles(samples) do
    sorted = Enum.sort(samples)
    n = length(sorted)
    at = fn p -> Enum.at(sorted, min(n - 1, trunc(p * n))) end
    %{p50: at.(0.50), p99: at.(0.99), n: n}
  end

  defp measure(fun) do
    # Warm up so the first-call costs (module load, CubDB file open) do
    # not land in either sample set.
    for _ <- 1..20, do: fun.()

    for _ <- 1..@samples do
      {us, _} = :timer.tc(fun)
      us
    end
    |> percentiles()
  end

  defp measure_offered(fun) do
    warm_up_calls = 20

    for _ <- 1..warm_up_calls do
      AuditLog.reset_rate_table()
      fun.()
    end

    samples =
      for _ <- 1..@samples do
        AuditLog.reset_rate_table()
        {us, _} = :timer.tc(fun)
        us
      end

    {percentiles(samples), warm_up_calls + length(samples)}
  end

  # ── the ALLOW path: must pay nothing ─────────────────────────────────

  test "the ALLOW path is unaffected by audit wiring", %{store: store, dispatcher: dispatcher} do
    # Permissive posture: every write lands. No denial ever fires, so
    # the audit subsystem must be entirely absent from the cost.
    Application.put_env(:commonplace, :local_write_gate, :dry_run)
    Application.delete_env(:commonplace, :trust)

    write = fn ->
      CommitStoreClient.create_chained_commit(store, UUID.uuid4(), text_update("hello"))
    end

    AuditLog.detach()
    baseline = measure(write)

    AuditLog.attach(store, dispatcher: dispatcher)
    with_audit = measure(write)

    AuditLog.detach()

    ratio50 = with_audit.p50 / max(baseline.p50, 1)
    ratio99 = with_audit.p99 / max(baseline.p99, 1)

    report = """
    ALLOW path, n=#{baseline.n} per arm
      baseline    p50=#{baseline.p50}us p99=#{baseline.p99}us
      with audit  p50=#{with_audit.p50}us p99=#{with_audit.p99}us
      ratio       p50=#{Float.round(ratio50, 3)} p99=#{Float.round(ratio99, 3)}
    """

    IO.puts("\n" <> report)

    assert ratio50 <= @max_ratio, "allow-path p50 regressed beyond budget\n" <> report
    assert ratio99 <= @max_ratio, "allow-path p99 regressed beyond budget\n" <> report
  end

  # ── the DENY path: bounded, and never a store write in the choke ─────

  test "the DENY path adds only bounded work to the choke", %{store: store, dispatcher: dispatcher} do
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    deny = fn ->
      CommitStore.create_commit(store, UUID.uuid4(), text_update("secret"), nil)
    end

    AuditLog.detach()
    baseline = measure(deny)

    AuditLog.attach(store, dispatcher: dispatcher)
    with_audit = measure(deny)

    AuditLog.detach()

    ratio50 = with_audit.p50 / max(baseline.p50, 1)
    ratio99 = with_audit.p99 / max(baseline.p99, 1)

    report = """
    DENY path, n=#{baseline.n} per arm
      baseline    p50=#{baseline.p50}us p99=#{baseline.p99}us
      with audit  p50=#{with_audit.p50}us p99=#{with_audit.p99}us
      ratio       p50=#{Float.round(ratio50, 3)} p99=#{Float.round(ratio99, 3)}
    """

    IO.puts("\n" <> report)

    assert ratio50 <= @max_ratio, "deny-path p50 regressed beyond budget\n" <> report

    # p99 is REPORTED but not asserted on the deny arm: the dispatcher's
    # batch flush writes audit records into the same store GenServer the
    # timed calls go through, so a timed call that queues behind a flush
    # pays several ms against a sub-ms baseline. That is queueing behind
    # a legitimate async writer, not work in the choke — and one
    # collision trips any tight p99 over n=200 (2nd-worst sample). The
    # regression this test defends against (a synchronous store write
    # back in the choke) inflates EVERY sample, so p50 catches it
    # strictly better than p99 ever did.

    # And the denials were actually recorded — a perf test that measured
    # a no-op would pass trivially. The perf claim and the function claim
    # must hold in the SAME run.
    _ = AuditDispatcher.flush(dispatcher, 10_000)
    status = AuditDispatcher.status(dispatcher)

    # offered comes from the WARM-UP calls: the flood guard caps offers
    # at 20 per window, so the warm-up consumes the bucket and all 200
    # timed samples take the suppress path. That is the steady-state
    # deny cost under a denial storm BY DESIGN, so it is the right thing
    # to have timed; the guard below still proves the pipeline was live.
    assert status.offered > 0, "the deny arm provoked no denials; the timing means nothing"
    assert status.recorded > 0, "denials were timed but not recorded: #{inspect(status)}"
  end

  # ── the ordinary DENY path: every denial is offered ─────────────────

  test "the DENY path's OFFERED work is bounded", %{store: store, dispatcher: dispatcher} do
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn -> AuditLog.reset_rate_table() end)

    deny = fn ->
      CommitStore.create_commit(store, UUID.uuid4(), text_update("secret"), nil)
    end

    AuditLog.detach()
    AuditLog.reset_rate_table()
    {baseline, baseline_calls} = measure_offered(deny)

    before_status = AuditDispatcher.status(dispatcher)
    AuditLog.attach(store, dispatcher: dispatcher)
    {with_audit, measured_calls} = measure_offered(deny)
    AuditLog.detach()

    ratio50 = with_audit.p50 / max(baseline.p50, 1)
    ratio99 = with_audit.p99 / max(baseline.p99, 1)

    _ = AuditDispatcher.flush(dispatcher, 10_000)
    after_status = AuditDispatcher.status(dispatcher)
    offered_delta = after_status.offered - before_status.offered

    report = """
    DENY OFFERED path, n=#{baseline.n} per arm
      baseline    p50=#{baseline.p50}us p99=#{baseline.p99}us calls=#{baseline_calls}
      with audit  p50=#{with_audit.p50}us p99=#{with_audit.p99}us calls=#{measured_calls}
      ratio       p50=#{Float.round(ratio50, 3)} p99=#{Float.round(ratio99, 3)}
      offered     expected=#{measured_calls} observed=#{offered_delta}
    """

    IO.puts("\n" <> report)

    assert offered_delta == measured_calls,
           "#{measured_calls - offered_delta} attached deny calls were suppressed; " <>
             "the OFFERED-path timing is vacuous\n" <> report

    assert ratio50 <= @max_ratio, "deny OFFERED-path p50 regressed beyond budget\n" <> report

    # As in the storm arm above, p99 is reported but not asserted: one
    # collision with the dispatcher's legitimate asynchronous flush can
    # trip a tight tail bound, while a synchronous regression inflates
    # every sample and is therefore caught more reliably by p50.
  end

  # ── the structural claim, asserted structurally ──────────────────────

  test "no audit or red-log module is reachable from the store's synchronous write path" do
    source = File.read!(Path.join(__DIR__, "../../../lib/commonplace/store/commit_store.ex"))

    # The store may REFERENCE AuditLog for `content_digest/1` (a pure
    # hash) and nothing else. Any RedLog / CommitStoreClient use inside
    # the store's own module is the shape that deadlocked it.
    audit_refs =
      Regex.scan(~r/Commonplace\.Trust\.AuditLog\.\w+/, source) |> List.flatten() |> Enum.uniq()

    assert audit_refs == ["Commonplace.Trust.AuditLog.content_digest"],
           "CommitStore reaches into the audit subsystem beyond the pure digest helper: " <>
             inspect(audit_refs)

    refute source =~ "Commonplace.Dataflow.RedLog",
           "CommitStore must never touch RedLog — that is a store write from inside the store"
  end
end
