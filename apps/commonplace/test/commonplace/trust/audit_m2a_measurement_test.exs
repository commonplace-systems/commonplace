defmodule Commonplace.Trust.AuditM2AMeasurementTest do
  @moduledoc """
  AUDIT-M2A measurement harness. The three tests are run individually in
  source order: multi-window baseline, owner death, then stream stop.

  The harness exercises the real enforce denial, telemetry handler, rate gate,
  dispatcher, signed audit write, and substrate readback. Only clock boundaries
  are accelerated by backdating the live bucket's window timestamp.
  """

  use ExUnit.Case, async: false

  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Trust.{AuditDispatcher, AuditLog, AuditRateLimiter}

  @moduletag :scale
  @moduletag timeout: 180_000

  @rate_table :commonplace_trust_audit_log_rate
  @storm_event [:commonplace, :commit, :rejected, :local_trust]
  @different_event [:commonplace, :trust, :revocation, :ignored]
  @events_per_window 100
  @windows_crossed 5

  setup do
    dir = Path.join(System.tmp_dir!(), "audit_m2a_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"audit_m2a_store_#{n}"

    store_opts = [
      data_dir: dir,
      name: :"audit_m2a_sup_#{n}",
      commit_store_name: store,
      trust_side_store_name: :"audit_m2a_tss_#{n}",
      pending_imports_name: :"audit_m2a_pi_#{n}"
    ]

    start_supervised!({Commonplace.Store.Supervisor, store_opts})

    old_gate = Application.get_env(:commonplace, :local_write_gate)
    old_trust = Application.get_env(:commonplace, :trust)
    old_data_dir = Application.get_env(:commonplace, :data_dir)
    old_logger_level = Logger.level()

    Application.put_env(:commonplace, :data_dir, dir)
    assert {:ok, _signing_context} = NodeIdentity.signing_context()
    Application.put_env(:commonplace, :local_write_gate, :enforce)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Logger.configure(level: :error)

    task_supervisor = :"audit_m2a_tasks_#{n}"
    dispatcher = :"audit_m2a_dispatcher_#{n}"
    task_opts = [name: task_supervisor]

    dispatcher_opts = [
      name: dispatcher,
      store: store,
      task_supervisor: task_supervisor,
      flush_ms: 10,
      enabled: true
    ]

    start_supervised!({Task.Supervisor, task_opts})
    start_supervised!({AuditDispatcher, dispatcher_opts})

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

    %{
      store: store,
      dispatcher: dispatcher,
      store_opts: store_opts,
      task_opts: task_opts,
      dispatcher_opts: dispatcher_opts
    }
  end

  test "arm 01: every expired storm window is summarized without a following event", context do
    organic_doc = UUID.uuid4()
    before = snapshot(context)

    for expected_summaries <- 1..@windows_crossed do
      drive_denials(context.store, organic_doc, @events_per_window)
      expire_bucket(@storm_event, organic_doc)
      assert_summary_count(context, before, organic_doc, expected_summaries)
    end

    measurement = settle_and_measure(context, before, %{organic: organic_doc})
    summary_suppressed = Enum.map(measurement.summaries, & &1["suppressed"])
    suppressed_per_window = @events_per_window - AuditLog.rate_cap()

    print_measurement("arm_01_multi_window", measurement,
      windows_crossed: @windows_crossed,
      summaries_expected: @windows_crossed,
      summary_suppressed: summary_suppressed
    )

    assert measurement.attached_before
    assert measurement.attached_after
    assert measurement.stage.entered == @windows_crossed * @events_per_window
    assert measurement.stage.rate_suppressed == @windows_crossed * suppressed_per_window
    assert measurement.stage.offer_events == @windows_crossed * AuditLog.rate_cap()
    assert measurement.stage.handler_failed == 0
    assert measurement.captured.organic == @windows_crossed * AuditLog.rate_cap()
    assert length(measurement.summaries) == @windows_crossed
    assert summary_suppressed == List.duplicate(suppressed_per_window, @windows_crossed)
    assert measurement.dispatcher.offered == measurement.stage.offered
    assert measurement.dispatcher.recorded == measurement.stage.offered
    assert measurement.dispatcher.shed == 0
    assert measurement.dispatcher.failed == 0
  end

  test "arm 02: caller death cannot own the table; flushed loss survives owner restart",
       context do
    first_doc = UUID.uuid4()
    second_doc = UUID.uuid4()
    third_doc = UUID.uuid4()
    before = snapshot(context)
    owner = Process.whereis(AuditRateLimiter)

    assert is_pid(owner)
    assert :ets.info(@rate_table, :owner) == owner

    caller = spawn(fn -> emit_direct_denial(first_doc) end)
    caller_ref = Process.monitor(caller)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
    assert :ets.info(@rate_table, :owner) == owner

    drive_denials(context.store, first_doc, @events_per_window - 1)
    expire_bucket(@storm_event, first_doc)
    first = assert_summary_count(context, before, first_doc, 1)
    assert first.suppressed_in_summaries == @events_per_window - AuditLog.rate_cap()

    owner_ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}

    restarted_owner = await_restarted_owner(owner)
    assert :ets.info(@rate_table, :owner) == restarted_owner

    # The first summary lives in the audit doc, not in the restarted owner's
    # volatile table. New accrual therefore continues without erasing it.
    assert settle_and_measure(context, before, %{first: first_doc}).suppressed_in_summaries ==
             @events_per_window - AuditLog.rate_cap()

    drive_denials(context.store, second_doc, @events_per_window)
    expire_bucket(@storm_event, second_doc)

    before_harness_restart = assert_summary_count(context, before, second_doc, 2)

    restart_harness(context)

    durable_before_new_accrual = summary_records(context.store)
    assert Enum.map(durable_before_new_accrual, & &1["suppressed"]) == [80, 80]

    after_restart_before = snapshot(context)
    drive_denials(context.store, third_doc, @events_per_window)
    expire_bucket(@storm_event, third_doc)
    measurement = assert_summary_count(context, after_restart_before, third_doc, 3)
    durable_after_new_accrual = summary_records(context.store)

    print_measurement("arm_02_supervised_owner_restart", measurement,
      owner: inspect(owner),
      restarted_owner: inspect(restarted_owner),
      before_harness_restart: Enum.map(before_harness_restart.summaries, & &1["suppressed"]),
      after_harness_restart: Enum.map(durable_after_new_accrual, & &1["suppressed"])
    )

    assert measurement.suppressed_in_summaries ==
             3 * (@events_per_window - AuditLog.rate_cap())

    assert Enum.sum_by(durable_after_new_accrual, & &1["suppressed"]) ==
             3 * (@events_per_window - AuditLog.rate_cap())

    assert measurement.dispatcher.shed == 0
    assert measurement.dispatcher.failed == 0
  end

  test "arm 03: stopping a stream leaves no stranded final window", context do
    organic_doc = UUID.uuid4()
    before = snapshot(context)

    drive_denials(context.store, organic_doc, @events_per_window)
    expire_bucket(@storm_event, organic_doc)

    _before_different_bucket = assert_summary_count(context, before, organic_doc, 1)

    :telemetry.execute(
      @different_event,
      %{system_time: System.system_time()},
      %{cap_id: "AUDIT-M2A", revoker_pubkey: "measurement"}
    )

    after_different_bucket =
      settle_and_measure(context, before, %{
        organic: organic_doc,
        different_bucket: nil
      })

    print_measurement("arm_03_stream_stop", after_different_bucket,
      summaries_expected_without_same_bucket_event: 1,
      summaries_found: length(after_different_bucket.summaries),
      suppressed_summarized: after_different_bucket.suppressed_in_summaries,
      stranded: 0
    )

    assert after_different_bucket.captured.organic == AuditLog.rate_cap()
    assert after_different_bucket.captured.different_bucket == 1
    assert length(after_different_bucket.summaries) == 1

    assert after_different_bucket.suppressed_in_summaries ==
             @events_per_window - AuditLog.rate_cap()

    assert after_different_bucket.stage.handler_failed == 0
    assert after_different_bucket.dispatcher.offered == after_different_bucket.stage.offered
    assert after_different_bucket.dispatcher.recorded == after_different_bucket.stage.offered
    assert after_different_bucket.dispatcher.shed == 0
    assert after_different_bucket.dispatcher.failed == 0
  end

  defp emit_direct_denial(doc_uuid) do
    :telemetry.execute(
      @storm_event,
      %{system_time: System.system_time()},
      %{mode: :enforce, doc_uuid: doc_uuid, commit_id: nil, reason: :unsigned}
    )
  end

  defp drive_denials(store, doc_uuid, count) do
    update = text_update("AUDIT-M2A denied write")

    for _ <- 1..count do
      assert {:error, {:trust_rejected, :unsigned}} =
               CommitStore.create_commit(store, doc_uuid, update, nil)
    end
  end

  defp expire_bucket(event, doc_uuid) do
    stale_window = System.system_time(:millisecond) - 60_001

    [{{^event, ^doc_uuid, window_start} = key, driven, dispatcher}] =
      :ets.match_object(@rate_table, {{event, doc_uuid, :_}, :_, :_})

    true = :ets.delete(@rate_table, key)
    true = :ets.insert(@rate_table, {{event, doc_uuid, stale_window}, driven, dispatcher})
    true = :ets.insert(@rate_table, {{:current, event, doc_uuid}, stale_window})
    assert window_start > stale_window
  end

  defp assert_summary_count(context, before, doc_uuid, expected) do
    owner = Process.whereis(AuditRateLimiter)
    if owner, do: send(owner, :flush_rate_windows)
    if owner, do: :sys.get_state(owner)

    measurement = settle_and_measure(context, before, %{organic: doc_uuid})
    assert length(measurement.summaries) == expected
    measurement
  end

  defp await_restarted_owner(old_owner, attempts \\ 100)

  defp await_restarted_owner(old_owner, attempts) when attempts > 0 do
    _ = :sys.get_state(Commonplace.Supervisor)

    case Process.whereis(AuditRateLimiter) do
      pid when is_pid(pid) and pid != old_owner -> pid
      _ -> await_restarted_owner(old_owner, attempts - 1)
    end
  end

  defp await_restarted_owner(_old_owner, 0), do: flunk("audit rate owner did not restart")

  defp restart_harness(context) do
    assert :ok = stop_supervised(AuditDispatcher)
    assert :ok = stop_supervised(context.task_opts[:name])
    assert :ok = stop_supervised(Commonplace.Store.Supervisor)

    start_supervised!({Commonplace.Store.Supervisor, context.store_opts})
    start_supervised!({Task.Supervisor, context.task_opts})
    start_supervised!({AuditDispatcher, context.dispatcher_opts})
    assert :ok = AuditLog.attach(context.store, dispatcher: context.dispatcher)
  end

  defp summary_records(store) do
    AuditLog.log_uuid()
    |> RedLog.load(store)
    |> RedLog.read()
    |> Enum.filter(&(&1["summary"] == true))
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
    summaries = Enum.filter(records, &(&1["summary"] == true))

    captured =
      Map.new(docs, fn
        {label, nil} ->
          {label, Enum.count(records, &(&1["event"] == Enum.join(@different_event, ".")))}

        {label, doc_uuid} ->
          {label, Enum.count(records, &(&1["doc_uuid"] == doc_uuid and &1["summary"] != true))}
      end)

    %{
      attached_before: before.attached,
      attached_after: AuditLog.attached?(),
      stage: stage,
      dispatcher: dispatcher,
      captured: captured,
      summaries: summaries,
      suppressed_in_summaries: Enum.sum_by(summaries, & &1["suppressed"])
    }
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

  defp print_measurement(shape, measurement, details) do
    IO.puts(
      "AUDIT-M2A shape=#{shape} details=#{inspect(details, charlists: :as_lists)} " <>
        "stage=#{inspect(measurement.stage)} dispatcher=#{inspect(measurement.dispatcher)} " <>
        "captured=#{inspect(measurement.captured)} " <>
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
