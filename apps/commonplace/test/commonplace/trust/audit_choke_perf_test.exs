defmodule Commonplace.Trust.AuditChokePerfTest do
  @moduledoc """
  CX-t3xv acceptance criterion 5: end-to-end write latency through the
  choke, p50/p99, against a baseline, **measured on the ALLOW path
  especially** (brief §2, inheriting R2's acceptance datum). Each
  percentile is a separately named ExUnit arm so a failure identifies
  the property that went red.

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
  That property is asserted structurally from `AuditLogCounter`, not
  inferred from a wall-clock ratio. The structural arm remains blocking
  everywhere, but it is blind to a constant-factor blowup: work that is
  100x slower still counts as four operations per denial. The wall-clock
  arm is the only instrument for that class, so it remains blocking where
  its enclosure says it can measure.

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

  # CX-dsqc empirical basis (five isolated runs, 2026-08-11): at n=200 the
  # ALLOW-p99 ratios were 1.827, 1.172, 0.795, 1.091, and 0.603. Two impossible
  # sub-1.0 results expose tail noise, while every run remains separated from
  # the unchanged 3.0 budget. At n=1_000 the confirmation distribution was
  # 0.959, 0.962, 0.871, 1.586, and 1.013: its range narrowed from 1.224 to
  # 0.715 and its maximum is still well clear of 3.0. Use n=1_000 and let the
  # impossibility guard name the three sub-1.0 runs as no-verdicts.
  @allow_p99_samples 1_000

  # CX-d0sc's identical-code runs at 1-minute load averages 8.6-9.5 spread
  # from 0.38 to 3.26, unlike CX-dsqc's quiet five-run distributions above.
  # Fix 8.0 a priori as the round-number line below the lowest observed noisy
  # load; it is never tuned from this run. This DETECTOR replaces unconditional
  # wall-clock eligibility. It is not a tighter assertion: @max_ratio remains
  # 3.0 and is applied unchanged whenever the enclosure holds.
  @max_enclosure_load_1m 8.0

  # Generous on purpose: see the moduledoc. The failure this guards is
  # a synchronous store write back in the choke, which is ~100x, not 2x.
  @max_ratio 3.0
  @max_counter_operations_per_denial 4

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

  defp measure(fun, sample_count \\ @samples) do
    # Warm up so the first-call costs (module load, CubDB file open) do
    # not land in either sample set.
    for _ <- 1..20, do: fun.()

    for _ <- 1..sample_count do
      {us, _} = :timer.tc(fun)
      us
    end
    |> percentiles()
  end

  defp measure_allow(store, dispatcher, sample_count \\ @samples) do
    Application.put_env(:commonplace, :local_write_gate, :dry_run)
    Application.delete_env(:commonplace, :trust)

    write = fn ->
      CommitStoreClient.create_chained_commit(store, UUID.uuid4(), text_update("hello"))
    end

    AuditLog.detach()
    baseline = measure(write, sample_count)

    AuditLog.attach(store, dispatcher: dispatcher)
    with_audit = measure(write, sample_count)

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
    %{p50: ratio50, p99: ratio99, report: report}
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

  test "the ALLOW path p50 ratio is within budget", %{store: store, dispatcher: dispatcher} do
    with_wall_clock_enclosure("ALLOW p50", fn ->
      measurement = measure_allow(store, dispatcher)

      assert_ratio_verdict!("ALLOW p50", measurement.p50, @max_ratio, measurement.report)
    end)
  end

  test "the ALLOW path p99 ratio is within budget", %{store: store, dispatcher: dispatcher} do
    with_wall_clock_enclosure("ALLOW p99", fn ->
      measurement = measure_allow(store, dispatcher, @allow_p99_samples)

      assert_ratio_verdict!("ALLOW p99", measurement.p99, @max_ratio, measurement.report)
    end)
  end

  # ── the ordinary DENY path: every denial is offered ─────────────────

  @tag capture_log: true
  test "the DENY OFFERED path p50 ratio is within budget", %{
    store: store,
    dispatcher: dispatcher
  } do
    with_wall_clock_enclosure("DENY OFFERED p50", fn ->
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

      # This remains the original 3.0 budget. CX-dsqc forbids changing the
      # DENY OFFERED budget while the structural discriminator is established.
      assert_ratio_verdict!("DENY OFFERED p50", ratio50, @max_ratio, report)

      # p99 is reported but not asserted: one
      # collision with the dispatcher's legitimate asynchronous flush can
      # trip a tight tail bound, while a synchronous regression inflates
      # every sample and is therefore caught more reliably by p50.
    end)
  end

  # ── the DENY path: bounded work asserted from exact counter deltas ───

  @tag capture_log: true
  test "the DENY OFFERED path adds a constant counter-operation signature per denial", %{
    store: store,
    dispatcher: dispatcher
  } do
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    deny = fn ->
      CommitStore.create_commit(store, UUID.uuid4(), text_update("secret"), nil)
    end

    AuditLog.attach(store, dispatcher: dispatcher)

    curve =
      for denials <- [1, 10, 100, 500] do
        before_counts = AuditLog.counters()

        for _ <- 1..denials do
          AuditLog.reset_rate_table()
          deny.()
        end

        delta = counter_delta(before_counts, AuditLog.counters())
        operations = delta |> Map.values() |> Enum.sum()

        %{
          denials: denials,
          operations: operations,
          operations_per_denial: operations / denials,
          delta: delta
        }
      end

    IO.puts("\nDENY OFFERED counter-operation curve: #{inspect(curve)}")

    for point <- curve do
      assert point.delta == %{
               built: point.denials,
               entered: point.denials,
               guarded: 0,
               handler_failed: 0,
               offer_events: point.denials,
               offered: point.denials,
               rate_suppressed: 0
             }
    end

    assert_counter_curve!(
      "DENY OFFERED structural",
      curve,
      @max_counter_operations_per_denial
    )

    _ = AuditDispatcher.flush(dispatcher, 10_000)
    status = AuditDispatcher.status(dispatcher)
    assert status.recorded > 0, "denials were counted but not recorded: #{inspect(status)}"
  end

  # ── positive controls: every reshaped arm can still go red ──────────

  test "wall-clock arms name the load and marker when their enclosure declines" do
    enclosure = %{load_1m: 8.75, concurrent_build_marker: "cc1(pid=4242)"}

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:no_verdict, message} =
                 with_wall_clock_enclosure(
                   "ALLOW p50",
                   fn -> send(self(), :wall_clock_measurement_ran) end,
                   fn -> enclosure end
                 )

        assert message ==
                 "NO VERDICT ALLOW p50: enclosure failed; 1-minute loadavg=8.75 " <>
                   "(detector line < 8.0); concurrent-build-marker=cc1(pid=4242); " <>
                   "wall-clock ratio assertion skipped"

        refute_received :wall_clock_measurement_ran
      end)

    assert output =~ "NO VERDICT ALLOW p50: enclosure failed"
  end

  test "the structural arm still gives its verdict when wall-clock arms decline" do
    enclosure = %{load_1m: 8.75, concurrent_build_marker: "cc1(pid=4242)"}

    assert {:no_verdict, _message} =
             with_wall_clock_enclosure(
               "DENY OFFERED p50",
               fn -> send(self(), :wall_clock_measurement_ran) end,
               fn -> enclosure end
             )

    refute_received :wall_clock_measurement_ran

    assert :constant =
             assert_counter_curve!(
               "DENY OFFERED structural while wall clock declined",
               [
                 %{denials: 1, operations_per_denial: 4.0},
                 %{denials: 10, operations_per_denial: 4.0},
                 %{denials: 100, operations_per_denial: 4.0}
               ],
               @max_counter_operations_per_denial
             )
  end

  test "positive control: the ALLOW p50 ratio arm rejects over-budget work" do
    assert_ratio_positive_control!("ALLOW p50", @max_ratio)
  end

  test "positive control: the ALLOW p99 ratio arm rejects over-budget work" do
    assert_ratio_positive_control!("ALLOW p99", @max_ratio)
  end

  test "positive control: the DENY OFFERED p50 ratio arm rejects over-budget work" do
    assert_ratio_positive_control!("DENY OFFERED p50", @max_ratio)
  end

  test "positive control: the DENY OFFERED structural arm rejects growing work" do
    inflated_curve = [
      %{denials: 1, operations_per_denial: 4.0},
      %{denials: 10, operations_per_denial: 4.0},
      %{denials: 100, operations_per_denial: 5.0}
    ]

    error =
      assert_raise ExUnit.AssertionError, fn ->
        assert_counter_curve!(
          "DENY OFFERED structural control",
          inflated_curve,
          @max_counter_operations_per_denial
        )
      end

    IO.puts("POSITIVE CONTROL DENY OFFERED structural: #{Exception.message(error)}")
  end

  # ── the synchronous call graph claim, asserted structurally ─────────

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

  defp counter_delta(before_counts, after_counts) do
    before_counts
    |> Map.drop([:boot_id])
    |> Map.new(fn {key, was} -> {key, Map.fetch!(after_counts, key) - was} end)
  end

  defp with_wall_clock_enclosure(arm, verdict, probe \\ &measure_enclosure/0) do
    enclosure = probe.()

    if enclosure_holds?(enclosure) do
      verdict.()
    else
      message =
        "NO VERDICT #{arm}: enclosure failed; 1-minute loadavg=#{format_load(enclosure.load_1m)} " <>
          "(detector line < #{@max_enclosure_load_1m}); " <>
          "concurrent-build-marker=#{enclosure.concurrent_build_marker || "none"}; " <>
          "wall-clock ratio assertion skipped"

      IO.puts(message)
      {:no_verdict, message}
    end
  end

  defp enclosure_holds?(%{load_1m: load, concurrent_build_marker: nil})
       when is_number(load) and load < @max_enclosure_load_1m,
       do: true

  defp enclosure_holds?(_enclosure), do: false

  defp measure_enclosure do
    %{
      load_1m: read_load_1m(),
      concurrent_build_marker: concurrent_build_marker()
    }
  end

  defp read_load_1m do
    with {:ok, loadavg} <- File.read("/proc/loadavg"),
         [load | _] <- String.split(loadavg),
         {load, ""} <- Float.parse(load) do
      load
    else
      _ -> :unavailable
    end
  end

  # A second beam.smp or a cc1 compiler is a cheap, Linux-local indication
  # that another build can perturb the timing. This deliberately risks a
  # false positive for unrelated BEAM work; it can miss short-lived or
  # differently named compilers, and a process can start just after the scan.
  defp concurrent_build_marker do
    own_pid = System.pid()

    "/proc/[0-9]*/comm"
    |> Path.wildcard()
    |> Enum.find_value(fn path ->
      pid = path |> Path.dirname() |> Path.basename()

      with false <- pid == own_pid,
           {:ok, comm} <- File.read(path),
           comm = String.trim(comm),
           true <- comm in ["beam.smp", "cc1", "cc1plus"] do
        "#{comm}(pid=#{pid})"
      else
        _ -> nil
      end
    end)
  end

  defp format_load(load) when is_float(load), do: Float.to_string(load)
  defp format_load(load), do: inspect(load)

  defp assert_ratio_verdict!(arm, ratio, budget, report) do
    if ratio < 1.0 do
      IO.puts(
        "NO VERDICT #{arm}: noise-dominated ratio=#{Float.round(ratio, 3)} " <>
          "is below the physical floor 1.0; budget assertion skipped\n" <> report
      )

      :noise_dominated
    else
      assert ratio <= budget,
             "#{arm} regressed beyond ratio budget #{budget}\n" <> report

      :within_budget
    end
  end

  defp assert_counter_curve!(arm, curve, budget) do
    operations_per_denial = Enum.map(curve, & &1.operations_per_denial)

    assert length(Enum.uniq(operations_per_denial)) == 1,
           "#{arm} grew with denial count: #{inspect(curve)}"

    assert Enum.all?(operations_per_denial, &(&1 <= budget)),
           "#{arm} exceeded #{budget} counter operations per denial: #{inspect(curve)}"

    :constant
  end

  defp assert_ratio_positive_control!(arm, budget) do
    inflated_ratio = budget + 1.0

    error =
      assert_raise ExUnit.AssertionError, fn ->
        with_wall_clock_enclosure(
          arm,
          fn ->
            assert_ratio_verdict!(
              "#{arm} positive control",
              inflated_ratio,
              budget,
              "deliberately inflated counted work"
            )
          end,
          fn -> %{load_1m: 0.0, concurrent_build_marker: nil} end
        )
      end

    IO.puts("POSITIVE CONTROL #{arm}: #{Exception.message(error)}")
  end
end
