defmodule Commonplace.Trust.AuditRateLimiterTest do
  @moduledoc """
  Fast, always-on pins for `AuditRateLimiter.admit/3` — most importantly the
  NATURAL ROLLOVER path (`select_replace` on an expired pointer), which a
  sub-60-second test storm never reaches: the AUDIT-M2 review found the
  original replace spec was invalid (unescaped tuple in a match-spec body),
  so every wall-clock rollover raised and the fail-open rescue admitted
  unthrottled for up to a sweep interval. This file makes that branch a
  permanent resident of the ordinary suite.
  """

  use ExUnit.Case, async: false

  alias Commonplace.Trust.{AuditLog, AuditRateLimiter}

  @event [:commonplace, :commit, :rejected, :local_trust]

  setup do
    AuditLog.reset_rate_table()
    on_exit(fn -> AuditLog.reset_rate_table() end)

    %{
      table: AuditRateLimiter.table(),
      dispatcher: :"unused_dispatcher_#{:rand.uniform(1_000_000)}"
    }
  end

  test "admission caps within one window", %{dispatcher: dispatcher} do
    doc = UUID.uuid4()

    decisions =
      for _ <- 1..(AuditRateLimiter.cap() + 5),
          do: AuditRateLimiter.admit(@event, doc, dispatcher)

    assert Enum.count(decisions, &(&1 == :log)) == AuditRateLimiter.cap()
    assert Enum.count(decisions, &(&1 == :suppress)) == 5
  end

  test "the fail-open snapshot carries its boot identity and count" do
    assert %{boot_id: boot_id, failed_open: failed_open} =
             AuditRateLimiter.failed_open_snapshot()

    assert is_binary(boot_id)
    assert is_integer(failed_open) and failed_open >= 0
  end

  test "a table-less admit fails open loudly and ordinary admission resumes",
       %{table: table, dispatcher: dispatcher} do
    handler_id = {:audit_rate_limiter_failed_open, make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:commonplace, :trust, :audit, :rate_limiter, :failed_open],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:failed_open, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    before = AuditRateLimiter.failed_open_snapshot()

    owner = Process.whereis(AuditRateLimiter)
    owner_ref = Process.monitor(owner)

    on_exit(fn ->
      if Process.whereis(AuditRateLimiter) == nil do
        {:ok, _owner} = Supervisor.restart_child(Commonplace.Supervisor, AuditRateLimiter)
      end
    end)

    assert :ok = Supervisor.terminate_child(Commonplace.Supervisor, AuditRateLimiter)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :shutdown}
    assert :undefined == :ets.whereis(table)

    rescued_doc = UUID.uuid4()

    rescued =
      for _ <- 1..3,
          do: AuditRateLimiter.admit(@event, rescued_doc, dispatcher)

    assert rescued == [:log, :log, :log]

    for _ <- 1..3 do
      assert_receive {:failed_open, [:commonplace, :trust, :audit, :rate_limiter, :failed_open],
                      %{count: 1}, %{event_name: @event, doc_uuid: ^rescued_doc}}
    end

    refute_receive {:failed_open, _, _, _}
    assert Process.whereis(AuditRateLimiter) == nil

    after_rescue = AuditRateLimiter.failed_open_snapshot()
    assert after_rescue.boot_id == before.boot_id
    assert after_rescue.failed_open == before.failed_open + 3

    assert {:ok, restarted_owner} =
             Supervisor.restart_child(Commonplace.Supervisor, AuditRateLimiter)

    assert Process.whereis(AuditRateLimiter) == restarted_owner
    assert :ets.whereis(table) != :undefined

    fresh_doc = UUID.uuid4()

    ordinary =
      for _ <- 1..(AuditRateLimiter.cap() + 1),
          do: AuditRateLimiter.admit(@event, fresh_doc, dispatcher)

    assert Enum.count(ordinary, &(&1 == :log)) == AuditRateLimiter.cap()
    assert List.last(ordinary) == :suppress
  end

  test "natural rollover replaces the expired pointer atomically and re-caps — never fail-open",
       %{table: table, dispatcher: dispatcher} do
    doc = UUID.uuid4()

    for _ <- 1..(AuditRateLimiter.cap() + 3), do: AuditRateLimiter.admit(@event, doc, dispatcher)

    pointer = {:current, @event, doc}
    [{^pointer, ws1}] = :ets.lookup(table, pointer)

    # Age the bucket past the window the way wall-clock does: move BOTH the
    # pointer and the accrued row to a stale window start (the same shape the
    # scale harness's expire_bucket uses). Moving the row matters for
    # determinism: this whole test runs inside one millisecond, so a rollover
    # here can land on the SAME ms as ws1 — with the old row left at ws1 the
    # fresh window would collide with it, which no real rollover can do
    # (real ones are >= window_ms after the window start).
    stale = ws1 - 2 * AuditRateLimiter.window_ms()

    [{{@event, ^doc, ^ws1} = old_key, driven_before, row_dispatcher}] =
      :ets.match_object(table, {{@event, doc, ws1}, :_, :_})

    true = :ets.delete(table, old_key)
    true = :ets.insert(table, {{@event, doc, stale}, driven_before, row_dispatcher})
    true = :ets.insert(table, {pointer, stale})

    # The first event after expiry must ROLL the pointer (select_replace, the
    # spec that used to raise) and count as event #1 of the fresh window.
    assert :log == AuditRateLimiter.admit(@event, doc, dispatcher)

    [{^pointer, ws2}] = :ets.lookup(table, pointer)
    assert ws2 > stale

    [{{@event, ^doc, ^ws2}, 1, _}] = :ets.match_object(table, {{@event, doc, ws2}, :_, :_})

    # And the fresh window RE-CAPS: cap-1 more :log, then :suppress — if the
    # rollover had failed open, these would all be :log.
    rest = for _ <- 1..AuditRateLimiter.cap(), do: AuditRateLimiter.admit(@event, doc, dispatcher)
    assert Enum.count(rest, &(&1 == :log)) == AuditRateLimiter.cap() - 1
    assert List.last(rest) == :suppress
  end
end
