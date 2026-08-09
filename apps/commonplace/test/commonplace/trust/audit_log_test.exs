defmodule Commonplace.Trust.AuditLogTest do
  @moduledoc """
  CX-hilo: the trust-rejection telemetry events must land in the durable
  red log, and the read-gate's high-volume event must be flood-guarded
  rather than writing one commit per firing.

  ## What this file does NOT prove (CX-t3xv)

  Read this before treating a green run here as evidence the audit trail
  works. These tests fire `:telemetry.execute/3` **from the test
  process**, under the **permissive** default trust config, with the
  `:local_write_gate` knob untouched. That posture is structurally
  incapable of reproducing either mechanism that actually killed this
  subsystem:

    * the `:calling_self` deadlock needs the handler to run inside
      `CommitStore`'s `handle_call` (telemetry handlers run in the
      caller's process, so firing from here runs the handler here);
    * the unsigned-audit-write denial needs `accept_unsigned: false`
      plus `local_write_gate: :enforce`.

  This file therefore tests payload SHAPING and the flood guard, and
  nothing about the subsystem's survival under enforcement. The posture
  that matters lives in `Commonplace.Trust.AuditEnforceEtiologyTest` and
  `Commonplace.Trust.AuditDualMechanismTest`. Keeping that distinction
  visible is the point: a green check that could not have gone red for
  the real cause is how this subsystem stayed dead.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Store.CommitStore
  alias Commonplace.Trust.AuditLog

  @rate_table :commonplace_trust_audit_log_rate

  setup do
    commit_dir = Path.join(System.tmp_dir!(), "cp_audit_log_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(commit_dir)
    store_name = :"audit_log_store_#{:rand.uniform(999_999)}"
    start_supervised!({CommitStore, data_dir: commit_dir, name: store_name})

    # CX-t3xv: persistence is out-of-band now, so these tests need a
    # dispatcher pointed at THIS store (the app-level one writes to the
    # default store) and a flush before reading.
    sup = :"audit_log_tasks_#{:rand.uniform(999_999)}"
    dispatcher = :"audit_log_disp_#{:rand.uniform(999_999)}"
    start_supervised!({Task.Supervisor, name: sup})

    start_supervised!(
      {Commonplace.Trust.AuditDispatcher,
       name: dispatcher, store: store_name, task_supervisor: sup, flush_ms: 5, enabled: true}
    )

    AuditLog.attach(store_name, dispatcher: dispatcher)

    AuditLog.reset_rate_table()

    on_exit(fn ->
      AuditLog.detach()
      File.rm_rf!(commit_dir)
    end)

    %{store: store_name, dispatcher: dispatcher}
  end

  defp read_log(store, dispatcher) do
    Commonplace.Trust.AuditDispatcher.flush(dispatcher, 5_000)

    AuditLog.log_uuid()
    |> RedLog.load(store)
    |> RedLog.read()
  end

  test "rejected local-write commit lands in the red log", %{store: store, dispatcher: d} do
    commit_id = :crypto.strong_rand_bytes(16)

    :telemetry.execute(
      [:commonplace, :commit, :rejected, :local_trust],
      %{system_time: System.system_time()},
      %{mode: :enforce, doc_uuid: "doc-123", commit_id: commit_id, reason: :untrusted_signer}
    )

    [event] = read_log(store, d)
    assert event["event"] == "commonplace.commit.rejected.local_trust"
    assert event["doc_uuid"] == "doc-123"
    assert event["mode"] == "enforce"
    assert event["reason"] =~ "untrusted_signer"
    assert event["commit_id"] == Base.encode16(commit_id, case: :lower)
  end

  test "ignored revocation lands in the red log", %{store: store, dispatcher: d} do
    :telemetry.execute(
      [:commonplace, :trust, :revocation, :ignored],
      %{system_time: System.system_time()},
      %{cap_id: "cap-abc", revoker_pubkey: "pub-xyz"}
    )

    [event] = read_log(store, d)
    assert event["event"] == "commonplace.trust.revocation.ignored"
    assert event["cap_id"] == "cap-abc"
    assert event["revoker_pubkey"] == "pub-xyz"
  end

  test "dry-run would-refuse read lands in the red log", %{store: store, dispatcher: d} do
    :telemetry.execute(
      [:commonplace, :trust, :read, :would_refuse],
      %{count: 1},
      %{surface: :mcp, target: "doc-456", reader: "citizen-1", visibility: :private}
    )

    [event] = read_log(store, d)
    assert event["event"] == "commonplace.trust.read.would_refuse"
    assert event["doc_uuid"] == "doc-456"
    assert event["reader"] == "citizen-1"
    assert event["surface"] == "mcp"
    assert event["visibility"] == "private"
  end

  test "firing process distinguishes an unnamed emitter from the registered CommitStore",
       %{store: store} do
    AuditLog.attach(store, dispatcher: self())
    AuditLog.reset_rate_table()

    # Control the unnamed branch: prove this process actually has no
    # registered name before expecting the explicit descriptor.
    assert {:registered_name, []} = Process.info(self(), :registered_name)

    :telemetry.execute(
      [:commonplace, :trust, :revocation, :ignored],
      %{system_time: 123},
      %{cap_id: "cap-process", revoker_pubkey: "pub-process"}
    )

    assert_receive {:"$gen_cast", {:audit, direct_record}}

    assert direct_record["firing_process"] == %{
             "registered_name" => "unnamed",
             "pid" => inspect(self())
           }

    assert Map.delete(direct_record, "firing_process") == %{
             "event" => "commonplace.trust.revocation.ignored",
             "gate" => "revocation",
             "check" => "revocation_ignored",
             "cap_id" => "cap-process",
             "revoker_pubkey" => "pub-process",
             "system_time" => 123
           }

    store_pid = Process.whereis(store)
    assert is_pid(store_pid)
    assert {:registered_name, ^store} = Process.info(store_pid, :registered_name)

    old_gate = Application.get_env(:commonplace, :local_write_gate)
    old_trust = Application.get_env(:commonplace, :trust)

    on_exit(fn ->
      restore_env(:local_write_gate, old_gate)
      restore_env(:trust, old_trust)
    end)

    Application.put_env(:commonplace, :local_write_gate, :enforce)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})

    doc_uuid = UUID.uuid4()
    update = Yelixer.Doc.new() |> Yelixer.Encoding.encode_update()

    assert {:error, {:trust_rejected, :unsigned}} =
             CommitStore.create_commit(store, doc_uuid, update, nil)

    assert_receive {:"$gen_cast", {:audit, store_record}}

    assert store_record["firing_process"] == %{
             "registered_name" => Atom.to_string(store),
             "pid" => inspect(store_pid)
           }

    refute direct_record["firing_process"] == store_record["firing_process"],
           "firing_process must discriminate: direct=#{inspect(direct_record["firing_process"])} " <>
             "store=#{inspect(store_record["firing_process"])}"
  end

  test "handler failure is swallowed, never raised into the caller", %{
    store: store,
    dispatcher: d
  } do
    # Malformed metadata (missing everything build_payload expects) must
    # not crash the caller that fired the telemetry event — this event
    # name fires directly on a trust-gate denial path.
    :telemetry.execute(
      [:commonplace, :trust, :revocation, :ignored],
      %{},
      %{}
    )

    [event] = read_log(store, d)
    assert event["event"] == "commonplace.trust.revocation.ignored"
    assert event["cap_id"] == nil
  end

  describe "flood guard" do
    test "caps persisted events per window and suppresses the rest", %{
      store: store,
      dispatcher: d
    } do
      event_name = [:commonplace, :trust, :read, :would_refuse]

      for i <- 1..25 do
        :telemetry.execute(event_name, %{count: 1}, %{
          surface: :test,
          target: "doc-#{i}",
          reader: "r",
          visibility: :public
        })
      end

      logged =
        store
        |> read_log(d)
        |> Enum.filter(&(&1["event"] == "commonplace.trust.read.would_refuse"))

      # Cap is 20 per window (see Commonplace.Trust.AuditLog moduledoc).
      assert length(logged) == 20

      [{^event_name, _window_start, count, suppressed}] = :ets.lookup(@rate_table, event_name)
      assert count == 20
      assert suppressed == 5
    end

    test "window rollover emits one summary record for what was suppressed", %{
      store: store,
      dispatcher: d
    } do
      event_name = [:commonplace, :trust, :read, :would_refuse]

      for i <- 1..25 do
        :telemetry.execute(event_name, %{count: 1}, %{
          surface: :test,
          target: "doc-#{i}",
          reader: "r",
          visibility: :public
        })
      end

      # Force the window to look expired (as if 61s had passed) so the
      # next event triggers rollover, without a real sleep.
      [{^event_name, window_start, count, suppressed}] = :ets.lookup(@rate_table, event_name)
      :ets.insert(@rate_table, {event_name, window_start - 61_000, count, suppressed})
      counters_before_rollover = AuditLog.counters()

      :telemetry.execute(event_name, %{count: 1}, %{
        surface: :test,
        target: "doc-rollover",
        reader: "r",
        visibility: :public
      })

      counters_after_rollover = AuditLog.counters()
      assert counters_after_rollover.entered == counters_before_rollover.entered + 1
      assert counters_after_rollover.built == counters_before_rollover.built + 1

      # `offered` counts records handed to the dispatcher, not input events:
      # the rollover produces one summary record and one payload record.
      assert counters_after_rollover.offered == counters_before_rollover.offered + 2

      events = read_log(store, d)

      summaries = Enum.filter(events, &(&1["event"] == "audit_log.rate_limited"))
      assert [summary] = summaries
      assert summary["suppressed"] == 5
      assert summary["suppressed_event"] == "commonplace.trust.read.would_refuse"

      # The event that triggered the rollover is itself logged (first in
      # the new window), on top of the earlier capped 20.
      would_refuse_events =
        Enum.filter(events, &(&1["event"] == "commonplace.trust.read.would_refuse"))

      assert length(would_refuse_events) == 21
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore_env(key, value), do: Application.put_env(:commonplace, key, value)
end
