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
