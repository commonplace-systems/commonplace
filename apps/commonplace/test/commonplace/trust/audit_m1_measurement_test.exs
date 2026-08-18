defmodule Commonplace.Trust.AuditM1MeasurementTest do
  @moduledoc """
  AUDIT-M1 measurement harness. This file deliberately exercises the real
  enforce denial, telemetry handler, rate gate, dispatcher, signed audit write,
  and substrate readback. It is tagged `:scale` because its incident-shaped arm
  drives 148,647 denied writes.
  """

  use ExUnit.Case, async: false

  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Trust.{AuditDispatcher, AuditLog}

  @moduletag :scale
  @moduletag timeout: 180_000

  @organic_driven 148_647
  @prefill_driven 15
  @rate_table :commonplace_trust_audit_log_rate
  @event [:commonplace, :commit, :rejected, :local_trust]

  setup do
    dir = Path.join(System.tmp_dir!(), "audit_m1_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"audit_m1_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"audit_m1_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"audit_m1_tss_#{n}",
       pending_imports_name: :"audit_m1_pi_#{n}"}
    )

    old_gate = Application.get_env(:commonplace, :local_write_gate)
    old_trust = Application.get_env(:commonplace, :trust)
    old_data_dir = Application.get_env(:commonplace, :data_dir)
    old_logger_level = Logger.level()

    Application.put_env(:commonplace, :data_dir, dir)
    assert {:ok, _signing_context} = NodeIdentity.signing_context()
    Application.put_env(:commonplace, :local_write_gate, :enforce)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Logger.configure(level: :error)

    task_supervisor = :"audit_m1_tasks_#{n}"
    dispatcher = :"audit_m1_dispatcher_#{n}"
    start_supervised!({Task.Supervisor, name: task_supervisor})

    start_supervised!(
      {AuditDispatcher,
       name: dispatcher,
       store: store,
       task_supervisor: task_supervisor,
       flush_ms: 10,
       enabled: true}
    )

    AuditLog.reset_rate_table()
    assert :ok = AuditLog.attach(store, dispatcher: dispatcher)

    on_exit(fn ->
      AuditLog.detach()
      AuditLog.reset_rate_table()
      restore(:local_write_gate, old_gate)
      restore(:trust, old_trust)
      restore(:data_dir, old_data_dir)
      Logger.configure(level: old_logger_level)
      File.rm_rf!(dir)
    end)

    %{store: store, dispatcher: dispatcher}
  end

  test "same event on two docs has an independent cap and starves neither doc", context do
    low_frequency_doc = UUID.uuid4()
    organic_doc = UUID.uuid4()
    before = snapshot(context)

    drive_denials(context.store, low_frequency_doc, @prefill_driven)
    storm_t0 = System.monotonic_time(:millisecond)
    drive_denials(context.store, organic_doc, @organic_driven)
    storm_elapsed_ms = System.monotonic_time(:millisecond) - storm_t0

    measurement =
      settle_and_measure(context, before, %{
        low_frequency: low_frequency_doc,
        organic: organic_doc
      })

    print_measurement("independent_doc_buckets", measurement)

    # The storm's wall-clock decides how many first-event-anchored windows
    # it crosses — a loaded host legitimately crosses several, each admitting
    # the cap. Assertions therefore bind INVARIANTS, never a window count:
    # a storm spanning T ms crosses at most div(T, window) + 1 windows
    # (+1 more margin for the clock read living outside the gate).
    windows_max = div(storm_elapsed_ms, Commonplace.Trust.AuditRateLimiter.window_ms()) + 2

    assert measurement.attached_before
    assert measurement.attached_after
    assert measurement.stage.entered == @prefill_driven + @organic_driven
    assert measurement.stage.handler_failed == 0
    # The stage identity, exact at any window count.
    assert measurement.stage.rate_suppressed ==
             measurement.stage.entered - measurement.stage.offer_events

    # Bucket independence — THE property: the storm starves nothing outside
    # its own {event, doc} bucket.
    assert measurement.captured.low_frequency == @prefill_driven
    # Every admitted organic event was durably recorded (none lost between
    # gate and doc), and admission stayed throttled: at least one window's
    # cap (driven >> cap), at most the elapsed-time ceiling.
    assert measurement.captured.organic ==
             measurement.stage.offer_events - @prefill_driven

    assert measurement.captured.organic >= AuditLog.rate_cap()
    assert measurement.captured.organic <= AuditLog.rate_cap() * windows_max
    # Mid-storm expired windows flush out-of-band while the storm still
    # runs; every summary must be truthful and every dispatched record must
    # land: offered = admitted events + flushed summaries, all recorded.
    assert_truthful_summaries(measurement)

    assert measurement.dispatcher.offered ==
             measurement.stage.offer_events + measurement.captured.summaries

    assert measurement.dispatcher.recorded == measurement.dispatcher.offered
    assert measurement.dispatcher.shed == 0
    # Flushed suppression never exceeds total suppression (the remainder is
    # the still-open window's pending accrual).
    assert measurement.suppressed_in_summaries <= measurement.stage.rate_suppressed
  end

  test "an expired final window writes a truthful summary without a next bucket event", context do
    organic_doc = UUID.uuid4()
    before = snapshot(context)

    drive_denials(context.store, organic_doc, @organic_driven)
    interim = settle_and_measure(context, before, %{organic: organic_doc})
    expire_bucket(organic_doc)

    # A slow storm crosses windows and flushes summaries mid-drive; the
    # property under test is only the FINAL window: expiring it must add
    # exactly one more durable summary with NO further bucket event driven.
    measurement =
      await_summaries(context, before, %{organic: organic_doc}, interim.captured.summaries + 1)

    print_measurement("final_window_timer_flush", measurement)

    assert measurement.attached_before
    assert measurement.attached_after
    assert measurement.stage.entered == @organic_driven
    assert measurement.stage.handler_failed == 0
    # The stage identity, exact at any window count.
    assert measurement.stage.rate_suppressed ==
             measurement.stage.entered - measurement.stage.offer_events

    assert measurement.captured.organic == measurement.stage.offer_events
    assert measurement.captured.summaries == interim.captured.summaries + 1
    assert_truthful_summaries(measurement)
    # THE CONSERVATION LAW, window-count-independent: with every window now
    # expired and flushed, nothing is pending — every driven event is either
    # a durable record or durably accounted suppression. This is the exact
    # property the incident boot lacked (5 records, zero summaries,
    # 148,642 unaccounted).
    assert measurement.captured.organic + measurement.suppressed_in_summaries ==
             @organic_driven

    assert measurement.suppressed_in_summaries == measurement.stage.rate_suppressed

    assert measurement.dispatcher.offered ==
             measurement.stage.offer_events + measurement.captured.summaries

    assert measurement.dispatcher.recorded == measurement.dispatcher.offered
    assert measurement.dispatcher.shed == 0
  end

  # Every summary must prove itself: driven splits exactly into admitted +
  # suppressed, admission never exceeded the cap, and the summary names the
  # storming doc — a forged or drifted summary fails one of these.
  defp assert_truthful_summaries(measurement) do
    for summary <- measurement.summaries_records do
      assert summary["driven"] == summary["admitted"] + summary["suppressed"]
      assert summary["admitted"] <= AuditLog.rate_cap()
      assert summary["suppressed"] > 0
      assert is_binary(summary["doc_uuid"])
    end
  end

  defp drive_denials(store, doc_uuid, count) do
    update = text_update("AUDIT-M1 denied write")

    for _ <- 1..count do
      assert {:error, {:trust_rejected, :unsigned}} =
               CommitStore.create_commit(store, doc_uuid, update, nil)
    end
  end

  defp snapshot(context) do
    %{
      attached: AuditLog.attached?(),
      stage: AuditLog.counters(),
      dispatcher: AuditDispatcher.status(context.dispatcher)
    }
  end

  defp settle_and_measure(context, before, docs) do
    assert :ok = AuditDispatcher.flush(context.dispatcher, 30_000)

    stage = numeric_delta(before.stage, AuditLog.counters())
    dispatcher = numeric_delta(before.dispatcher, AuditDispatcher.status(context.dispatcher))
    records = audit_records(context.store, before.dispatcher.boot_id)

    captured =
      Map.new(docs, fn {label, doc_uuid} ->
        {label, Enum.count(records, &(&1["doc_uuid"] == doc_uuid and &1["summary"] != true))}
      end)
      |> Map.put(:summaries, Enum.count(records, &(&1["summary"] == true)))

    summaries_records = Enum.filter(records, &(&1["summary"] == true))

    %{
      attached_before: before.attached,
      attached_after: AuditLog.attached?(),
      stage: stage,
      dispatcher: dispatcher,
      captured: captured,
      summaries_records: summaries_records,
      suppressed_in_summaries: Enum.sum_by(summaries_records, & &1["suppressed"])
    }
  end

  defp await_summaries(context, before, docs, expected, attempts \\ 100)

  defp await_summaries(context, before, docs, expected, attempts) when attempts > 0 do
    owner = Process.whereis(Commonplace.Trust.AuditRateLimiter)
    if owner, do: send(owner, :flush_rate_windows)
    if owner, do: :sys.get_state(owner)
    measurement = settle_and_measure(context, before, docs)

    if measurement.captured.summaries == expected do
      measurement
    else
      await_summaries(context, before, docs, expected, attempts - 1)
    end
  end

  defp await_summaries(context, before, docs, _expected, 0) do
    settle_and_measure(context, before, docs)
  end

  defp expire_bucket(doc_uuid) do
    stale_window = System.system_time(:millisecond) - 60_001

    # A slow storm leaves at most the CURRENT window's row (expired rows are
    # swept ~1s), but a sweep can race this read — take the latest window,
    # which is by construction the one still accruing.
    rows = :ets.match_object(@rate_table, {{@event, doc_uuid, :_}, :_, :_})
    assert rows != []

    {{@event, ^doc_uuid, window_start} = key, driven, dispatcher} =
      Enum.max_by(rows, fn {{_, _, start}, _, _} -> start end)

    true = :ets.delete(@rate_table, key)
    true = :ets.insert(@rate_table, {{@event, doc_uuid, stale_window}, driven, dispatcher})
    true = :ets.insert(@rate_table, {{:current, @event, doc_uuid}, stale_window})
    assert window_start > stale_window
  end

  defp audit_records(store, boot_id) do
    AuditLog.log_uuid()
    |> RedLog.load(store)
    |> RedLog.read()
    |> Enum.filter(&(&1["boot_id"] == boot_id))
  end

  defp numeric_delta(before, after_snapshot) do
    before
    |> Map.keys()
    |> Enum.filter(&(is_integer(before[&1]) and is_integer(after_snapshot[&1])))
    |> Map.new(fn key -> {key, Map.fetch!(after_snapshot, key) - Map.fetch!(before, key)} end)
  end

  defp print_measurement(shape, measurement) do
    IO.puts(
      "AUDIT-M1 shape=#{shape} stage=#{inspect(measurement.stage)} " <>
        "dispatcher=#{inspect(measurement.dispatcher)} captured=#{inspect(measurement.captured)} " <>
        "summary_suppressed=#{measurement.suppressed_in_summaries} " <>
        "attached=#{measurement.attached_before}/#{measurement.attached_after}"
    )
  end

  defp text_update(body) do
    Yelixer.Doc.new()
    |> ContentType.create(:text, "page.md")
    |> ContentType.insert_text(0, body)
    |> Yelixer.Encoding.encode_update()
  end

  defp restore(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore(key, value), do: Application.put_env(:commonplace, key, value)
end
