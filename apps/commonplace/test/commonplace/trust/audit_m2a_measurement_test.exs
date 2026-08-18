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
  alias Commonplace.Trust.{AuditDispatcher, AuditLog}

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

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"audit_m2a_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"audit_m2a_tss_#{n}",
       pending_imports_name: :"audit_m2a_pi_#{n}"}
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

    task_supervisor = :"audit_m2a_tasks_#{n}"
    dispatcher = :"audit_m2a_dispatcher_#{n}"
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

  test "arm 01: a continuous storm emits one summary at every crossed window", context do
    organic_doc = UUID.uuid4()
    before = snapshot(context)

    drive_denials(context.store, organic_doc, @events_per_window)

    for _ <- 1..@windows_crossed do
      expire_bucket(@storm_event)
      drive_denials(context.store, organic_doc, @events_per_window)
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
    assert measurement.stage.entered == (@windows_crossed + 1) * @events_per_window
    assert measurement.stage.rate_suppressed == (@windows_crossed + 1) * suppressed_per_window
    assert measurement.stage.offer_events == (@windows_crossed + 1) * AuditLog.rate_cap()
    assert measurement.stage.handler_failed == 0
    assert measurement.captured.organic == (@windows_crossed + 1) * AuditLog.rate_cap()
    assert length(measurement.summaries) == @windows_crossed
    assert summary_suppressed == List.duplicate(suppressed_per_window, @windows_crossed)
    assert measurement.dispatcher.offered == measurement.stage.offered
    assert measurement.dispatcher.recorded == measurement.stage.offered
    assert measurement.dispatcher.shed == 0
    assert measurement.dispatcher.failed == 0
  end

  test "arm 02: owner death erases suppression state but reopens organic admissions", context do
    low_frequency_doc = UUID.uuid4()
    organic_doc = UUID.uuid4()
    attach_time_owner = :ets.info(@rate_table, :owner)
    true = :ets.delete(@rate_table)
    assert :undefined == :ets.whereis(@rate_table)

    test_pid = self()

    owner =
      spawn(fn ->
        receive do
          {:emit_first, dispatcher} ->
            emit_direct_denial(low_frequency_doc)
            send(test_pid, {:first_emitted, self(), dispatcher})

            receive do
              :hold -> :ok
            end
        end
      end)

    on_exit(fn ->
      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end)

    before = snapshot(context)
    send(owner, {:emit_first, context.dispatcher})
    assert_receive {:first_emitted, ^owner, dispatcher}
    assert dispatcher == context.dispatcher
    assert :ets.info(@rate_table, :owner) == owner

    drive_denials(context.store, low_frequency_doc, 14)
    drive_denials(context.store, organic_doc, @events_per_window)

    [{@storm_event, _window_start, count_before_death, suppressed_lost}] =
      :ets.lookup(@rate_table, @storm_event)

    assert count_before_death == AuditLog.rate_cap()
    assert suppressed_lost == 95

    owner_ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}
    assert :undefined == :ets.whereis(@rate_table)

    drive_denials(context.store, organic_doc, @events_per_window)
    recreated_owner = :ets.info(@rate_table, :owner)
    assert recreated_owner == Process.whereis(context.store)

    further_windows_crossed = 3

    for _ <- 1..further_windows_crossed do
      expire_bucket(@storm_event)
      drive_denials(context.store, organic_doc, @events_per_window)
    end

    measurement =
      settle_and_measure(context, before, %{
        low_frequency: low_frequency_doc,
        organic: organic_doc
      })

    summary_suppressed = Enum.map(measurement.summaries, & &1["suppressed"])
    organic_before_death = 5
    rebirth_extra_admissions = AuditLog.rate_cap()
    organic_without_rebirth = organic_before_death + further_windows_crossed * AuditLog.rate_cap()

    print_measurement("arm_02_owner_death", measurement,
      attach_time_owner: inspect(attach_time_owner),
      deliberate_owner: inspect(owner),
      table_dead_after_owner: true,
      recreated_owner: inspect(recreated_owner),
      suppressed_lost: suppressed_lost,
      rebirth_extra_admissions: rebirth_extra_admissions,
      organic_without_rebirth: organic_without_rebirth,
      organic_with_rebirth: measurement.captured.organic,
      summary_suppressed: summary_suppressed
    )

    assert measurement.attached_before
    assert measurement.attached_after
    assert measurement.stage.entered == 1 + 14 + @events_per_window * 5
    assert measurement.stage.rate_suppressed == 95 + 80 * 4
    assert measurement.stage.offer_events == 100
    assert measurement.stage.handler_failed == 0
    assert measurement.captured.low_frequency == 15
    assert measurement.captured.organic == organic_without_rebirth + rebirth_extra_admissions
    assert measurement.captured.organic == 85
    assert summary_suppressed == [80, 80, 80]
    refute suppressed_lost in summary_suppressed
    assert measurement.dispatcher.offered == measurement.stage.offered
    assert measurement.dispatcher.recorded == measurement.stage.offered
    assert measurement.dispatcher.shed == 0
    assert measurement.dispatcher.failed == 0
  end

  test "arm 03: stopping a stream strands only its final window", context do
    organic_doc = UUID.uuid4()
    before = snapshot(context)

    drive_denials(context.store, organic_doc, @events_per_window)
    expire_bucket(@storm_event)

    before_different_bucket = settle_and_measure(context, before, %{organic: organic_doc})
    assert before_different_bucket.summaries == []

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

    [{@storm_event, _stale_window, count, suppressed_stranded}] =
      :ets.lookup(@rate_table, @storm_event)

    [{@different_event, _window_start, 1, 0}] = :ets.lookup(@rate_table, @different_event)

    print_measurement("arm_03_stream_stop", after_different_bucket,
      summaries_expected_without_same_bucket_event: 0,
      summaries_found: length(after_different_bucket.summaries),
      suppressed_stranded: suppressed_stranded,
      missing_summary_bound_per_stream: 1
    )

    assert count == AuditLog.rate_cap()
    assert suppressed_stranded == @events_per_window - AuditLog.rate_cap()
    assert after_different_bucket.captured.organic == AuditLog.rate_cap()
    assert after_different_bucket.captured.different_bucket == 1
    assert after_different_bucket.summaries == []
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

  defp expire_bucket(event) do
    [{^event, _window_start, count, suppressed}] = :ets.lookup(@rate_table, event)
    stale_window = System.system_time(:millisecond) - 60_001
    true = :ets.insert(@rate_table, {event, stale_window, count, suppressed})
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
          {label, Enum.count(records, &(&1["doc_uuid"] == doc_uuid))}
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
