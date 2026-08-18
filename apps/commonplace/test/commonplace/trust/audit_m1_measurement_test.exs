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

  test "clean-bucket organic storm locates all loss at the rate gate", context do
    organic_doc = UUID.uuid4()
    before = snapshot(context)

    drive_denials(context.store, organic_doc, @organic_driven)

    measurement = settle_and_measure(context, before, %{organic: organic_doc})
    print_measurement("storm", measurement)

    assert measurement.attached_before
    assert measurement.attached_after
    assert measurement.stage.entered == @organic_driven
    assert measurement.stage.rate_suppressed == @organic_driven - AuditLog.rate_cap()
    assert measurement.stage.offer_events == AuditLog.rate_cap()
    assert measurement.stage.handler_failed == 0
    assert measurement.dispatcher.offered == AuditLog.rate_cap()
    assert measurement.dispatcher.recorded == AuditLog.rate_cap()
    assert measurement.dispatcher.shed == 0
    assert measurement.captured.organic == AuditLog.rate_cap()
  end

  test "shared event bucket predicts five organic captures and one suppression summary",
       context do
    low_frequency_doc = UUID.uuid4()
    organic_doc = UUID.uuid4()
    before = snapshot(context)

    drive_denials(context.store, low_frequency_doc, @prefill_driven)
    drive_denials(context.store, organic_doc, @organic_driven)

    before_rollover =
      settle_and_measure(context, before, %{
        low_frequency: low_frequency_doc,
        organic: organic_doc
      })

    # Accelerate only the clock boundary. The bucket count and its suppression
    # arithmetic are the values produced by the real denial storm above.
    [{@event, window_start, count, suppressed}] = :ets.lookup(@rate_table, @event)
    stale_window = System.system_time(:millisecond) - 60_001
    true = :ets.insert(@rate_table, {@event, stale_window, count, suppressed})

    drive_denials(context.store, low_frequency_doc, 1)

    after_rollover =
      settle_and_measure(context, before, %{
        low_frequency: low_frequency_doc,
        organic: organic_doc
      })

    print_measurement("mixed_before_rollover", before_rollover)
    print_measurement("mixed_after_rollover", after_rollover)

    assert window_start <= stale_window + 60_001
    assert before_rollover.attached_before
    assert before_rollover.attached_after
    assert before_rollover.stage.entered == @prefill_driven + @organic_driven
    assert before_rollover.stage.rate_suppressed == @organic_driven - 5
    assert before_rollover.stage.offer_events == AuditLog.rate_cap()
    assert before_rollover.stage.handler_failed == 0
    assert before_rollover.captured.low_frequency == @prefill_driven
    assert before_rollover.captured.organic == 5
    assert before_rollover.captured.summaries == 0
    assert before_rollover.dispatcher.offered == AuditLog.rate_cap()
    assert before_rollover.dispatcher.recorded == AuditLog.rate_cap()
    assert before_rollover.dispatcher.shed == 0

    assert after_rollover.stage.entered == @prefill_driven + @organic_driven + 1
    assert after_rollover.stage.offered == AuditLog.rate_cap() + 2
    assert after_rollover.stage.offer_events == AuditLog.rate_cap() + 1
    assert after_rollover.captured.low_frequency == @prefill_driven + 1
    assert after_rollover.captured.organic == 5
    assert after_rollover.captured.summaries == 1
    assert after_rollover.suppressed_in_summaries == @organic_driven - 5
    assert after_rollover.dispatcher.offered == AuditLog.rate_cap() + 2
    assert after_rollover.dispatcher.recorded == AuditLog.rate_cap() + 2
    assert after_rollover.dispatcher.shed == 0
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
        {label, Enum.count(records, &(&1["doc_uuid"] == doc_uuid))}
      end)
      |> Map.put(:summaries, Enum.count(records, &(&1["summary"] == true)))

    %{
      attached_before: before.attached,
      attached_after: AuditLog.attached?(),
      stage: stage,
      dispatcher: dispatcher,
      captured: captured,
      suppressed_in_summaries:
        records
        |> Enum.filter(&(&1["summary"] == true))
        |> Enum.sum_by(& &1["suppressed"])
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
