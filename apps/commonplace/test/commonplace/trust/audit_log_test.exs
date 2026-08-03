defmodule Commonplace.Trust.AuditLogTest do
  @moduledoc """
  CX-hilo: the three trust-rejection telemetry events must land in the
  durable red log, and the read-gate's high-volume event must be
  flood-guarded rather than writing one commit per firing.
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

    AuditLog.attach(store_name)
    :ets.delete_all_objects(@rate_table)

    on_exit(fn ->
      AuditLog.detach()
      File.rm_rf!(commit_dir)
    end)

    %{store: store_name}
  end

  defp read_log(store) do
    AuditLog.log_uuid()
    |> RedLog.load(store)
    |> RedLog.read()
  end

  test "rejected local-write commit lands in the red log", %{store: store} do
    commit_id = :crypto.strong_rand_bytes(16)

    :telemetry.execute(
      [:commonplace, :commit, :rejected, :local_trust],
      %{system_time: System.system_time()},
      %{mode: :enforce, doc_uuid: "doc-123", commit_id: commit_id, reason: :untrusted_signer}
    )

    [event] = read_log(store)
    assert event["event"] == "commonplace.commit.rejected.local_trust"
    assert event["doc_uuid"] == "doc-123"
    assert event["mode"] == "enforce"
    assert event["reason"] =~ "untrusted_signer"
    assert event["commit_id"] == Base.encode16(commit_id, case: :lower)
  end

  test "ignored revocation lands in the red log", %{store: store} do
    :telemetry.execute(
      [:commonplace, :trust, :revocation, :ignored],
      %{system_time: System.system_time()},
      %{cap_id: "cap-abc", revoker_pubkey: "pub-xyz"}
    )

    [event] = read_log(store)
    assert event["event"] == "commonplace.trust.revocation.ignored"
    assert event["cap_id"] == "cap-abc"
    assert event["revoker_pubkey"] == "pub-xyz"
  end

  test "dry-run would-refuse read lands in the red log", %{store: store} do
    :telemetry.execute(
      [:commonplace, :trust, :read, :would_refuse],
      %{count: 1},
      %{surface: :mcp, target: "doc-456", reader: "citizen-1", visibility: :private}
    )

    [event] = read_log(store)
    assert event["event"] == "commonplace.trust.read.would_refuse"
    assert event["doc_uuid"] == "doc-456"
    assert event["reader"] == "citizen-1"
    assert event["surface"] == "mcp"
    assert event["visibility"] == "private"
  end

  test "handler failure is swallowed, never raised into the caller", %{store: store} do
    # Malformed metadata (missing everything build_payload expects) must
    # not crash the caller that fired the telemetry event — this event
    # name fires directly on a trust-gate denial path.
    :telemetry.execute(
      [:commonplace, :trust, :revocation, :ignored],
      %{},
      %{}
    )

    [event] = read_log(store)
    assert event["event"] == "commonplace.trust.revocation.ignored"
    assert event["cap_id"] == nil
  end

  describe "flood guard" do
    test "caps persisted events per window and suppresses the rest", %{store: store} do
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
        |> read_log()
        |> Enum.filter(&(&1["event"] == "commonplace.trust.read.would_refuse"))

      # Cap is 20 per window (see Commonplace.Trust.AuditLog moduledoc).
      assert length(logged) == 20

      [{^event_name, _window_start, count, suppressed}] = :ets.lookup(@rate_table, event_name)
      assert count == 20
      assert suppressed == 5
    end

    test "window rollover emits one summary record for what was suppressed", %{store: store} do
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

      :telemetry.execute(event_name, %{count: 1}, %{
        surface: :test,
        target: "doc-rollover",
        reader: "r",
        visibility: :public
      })

      events = read_log(store)

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
end
