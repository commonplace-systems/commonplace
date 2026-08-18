defmodule Commonplace.Trust.AuditLogCounterTest do
  use ExUnit.Case, async: false

  alias Commonplace.Trust.{AuditLog, AuditRateLimiter, DenialCounter}

  @event [:commonplace, :commit, :rejected, :local_trust]
  @rate_table :commonplace_trust_audit_log_rate

  setup do
    assert :ok = AuditLog.attach(:counter_fixture_store, dispatcher: self())
    assert :ok = AuditLog.reset_rate_table()
    refute :ets.whereis(@rate_table) == :undefined
    assert :ets.tab2list(@rate_table) == []

    on_exit(fn -> AuditLog.detach() end)
    :ok
  end

  test "ordinary denial under cap increments entered, built, and offered only" do
    before = AuditLog.counters()
    assert before.boot_id == DenialCounter.boot_id()

    assert :ok = deny("ordinary-doc")

    after_counts = AuditLog.counters()
    report("ordinary_denial_under_cap", before, after_counts)

    assert after_counts.entered == before.entered + 1
    assert after_counts.built == before.built + 1
    assert after_counts.offered == before.offered + 1
    assert after_counts.guarded == before.guarded
    assert after_counts.rate_suppressed == before.rate_suppressed
    assert after_counts.handler_failed == before.handler_failed
  end

  test "denial naming the audit log's own doc increments guarded but not offered" do
    before = AuditLog.counters()

    assert :ok = deny(AuditLog.log_uuid())

    after_counts = AuditLog.counters()
    report("audit_log_own_doc", before, after_counts)

    assert after_counts.entered == before.entered + 1
    assert after_counts.built == before.built + 1
    assert after_counts.guarded == before.guarded + 1
    assert after_counts.offered == before.offered
    assert after_counts.rate_suppressed == before.rate_suppressed
    assert after_counts.handler_failed == before.handler_failed
  end

  test "denials past the call-site rate cap increment rate_suppressed but not guarded" do
    cap_at_call_site = AuditLog.rate_cap()
    assert is_integer(cap_at_call_site) and cap_at_call_site > 0
    before = AuditLog.counters()

    for _sequence <- 1..(cap_at_call_site + 1) do
      assert :ok = deny("rate-doc")
    end

    after_counts = AuditLog.counters()
    report("past_rate_cap_#{cap_at_call_site}", before, after_counts)

    assert after_counts.entered == before.entered + cap_at_call_site + 1
    assert after_counts.built == before.built + cap_at_call_site + 1
    assert after_counts.offered == before.offered + cap_at_call_site
    assert after_counts.rate_suppressed == before.rate_suppressed + 1
    assert after_counts.guarded == before.guarded
    assert after_counts.handler_failed == before.handler_failed

    delta = delta(before, after_counts)

    assert delta.entered ==
             delta.guarded + delta.rate_suppressed + delta.offer_events + delta.handler_failed
  end

  test "an out-of-band summary increments offered without inventing an input event" do
    stale_window = System.system_time(:millisecond) - 3_600_000
    key = {@event, "summary-doc", stale_window}
    :ets.insert(@rate_table, {key, 27, self()})
    :ets.insert(@rate_table, {{:current, @event, "summary-doc"}, stale_window})

    before = AuditLog.counters()
    owner = Process.whereis(AuditRateLimiter)
    send(owner, :flush_rate_windows)
    _ = :sys.get_state(owner)
    after_counts = AuditLog.counters()
    report("rate_limit_summary", before, after_counts)

    delta = delta(before, after_counts)

    assert_receive {:"$gen_cast", {:audit, summary}}
    assert summary["suppressed"] == 7
    assert delta.offered == 1
    assert delta.entered == 0
    assert delta.offer_events == 0

    assert delta.entered ==
             delta.guarded + delta.rate_suppressed + delta.offer_events + delta.handler_failed
  end

  test "build_payload raise increments handler_failed but not built" do
    before = AuditLog.counters()

    assert :ok = AuditLog.handle_event(@event, :measurements_are_not_a_map, %{}, config())

    after_counts = AuditLog.counters()
    report("build_payload_raises", before, after_counts)

    assert after_counts.entered == before.entered + 1
    assert after_counts.handler_failed == before.handler_failed + 1
    assert after_counts.built == before.built
    assert after_counts.guarded == before.guarded
    assert after_counts.rate_suppressed == before.rate_suppressed
    assert after_counts.offered == before.offered
  end

  defp deny(doc_uuid) do
    AuditLog.handle_event(
      @event,
      %{system_time: System.system_time()},
      %{mode: :enforce, doc_uuid: doc_uuid, commit_id: <<1>>, reason: :unsigned},
      config()
    )
  end

  defp config, do: %{dispatcher: self(), store: :counter_fixture_store}

  # Derived from the snapshot rather than from a repeated field list: a
  # hardcoded list silently omits any counter added later, and the omission
  # surfaces as "key not found" in whichever test happens to use it rather than
  # as "the helper is stale".
  defp delta(before, after_counts) do
    before
    |> Map.drop([:boot_id])
    |> Map.new(fn {key, was} -> {key, Map.fetch!(after_counts, key) - was} end)
  end

  defp report(provocation, before, after_counts) do
    IO.puts(
      "AUDIT_STAGE_COUNTERS #{provocation} before=#{inspect(before)} after=#{inspect(after_counts)}"
    )
  end
end
