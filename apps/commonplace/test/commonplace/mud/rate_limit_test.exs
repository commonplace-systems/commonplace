defmodule Commonplace.MUD.RateLimitTest do
  @moduledoc """
  CX-nf8p — the throughput gate. Covers the design §6 attack catalog:
  R1 (per-session flood → drop → sustained-disconnect), R2 (per-principal
  aggregate bites across two sessions), R3 (principal keys the bucket —
  independent per identity), R5 (a good command resets the consecutive-drop
  escalation), R6 (fail-OPEN-but-alarm on an internal error), plus the
  lazy-refill + burst-cap shape (same as the vein-regen test).

  Determinism: the buckets live in a public ETS table (`RateLimit.table/0`)
  and refill lazily from a stored monotonic timestamp — so a test forces a
  "refill" or an internal error by writing a row directly, rather than
  sleeping.
  """
  use ExUnit.Case, async: false

  alias Commonplace.MUD.RateLimit

  setup do
    old = Application.get_env(:commonplace, :mud_rate_limit)

    on_exit(fn ->
      if is_nil(old),
        do: Application.delete_env(:commonplace, :mud_rate_limit),
        else: Application.put_env(:commonplace, :mud_rate_limit, old)
    end)

    # Unique keys per test so the singleton table never cross-contaminates.
    %{sid: make_ref(), principal: "p-#{System.unique_integer([:positive])}"}
  end

  defp put_cfg(kw), do: Application.put_env(:commonplace, :mud_rate_limit, kw)
  defp now_ms, do: System.monotonic_time(:millisecond)

  # ---- R1: per-session flood → drops → sustained → disconnect ----

  test "R1: a per-session flood drains the burst, drops, then disconnects on sustained abuse", %{
    sid: sid,
    principal: p
  } do
    # session burst 3, rate ~0 during a tight loop; principal effectively
    # unbounded (so THIS test isolates the session scope). Disconnect after
    # 5 consecutive drops.
    put_cfg(
      session_rate: 1,
      session_burst: 3,
      principal_rate: 1,
      principal_burst: 100_000,
      disconnect_after_drops: 5
    )

    # The 3 burst tokens are allowed.
    assert :ok = RateLimit.check(sid, p)
    assert :ok = RateLimit.check(sid, p)
    assert :ok = RateLimit.check(sid, p)

    # Now empty → drops. n = 1,2,3,4 are plain drops.
    for _ <- 1..4, do: assert({:drop, :rate} = RateLimit.check(sid, p))

    # The 5th consecutive drop crosses the threshold → disconnect.
    assert {:disconnect, :rate} = RateLimit.check(sid, p)
  end

  # ---- R2: per-principal aggregate bites across sessions ----

  test "R2: two sessions of one principal are throttled by their SHARED principal bucket", %{
    principal: p
  } do
    # Session buckets huge (never bite); principal bucket = 4. Two distinct
    # sessions of the same principal → only 4 commands total pass.
    put_cfg(
      session_rate: 1,
      session_burst: 100_000,
      principal_rate: 1,
      principal_burst: 4,
      disconnect_after_drops: 100
    )

    s1 = make_ref()
    s2 = make_ref()

    # 4 allowed, alternating sessions — the aggregate is what's bounded.
    assert :ok = RateLimit.check(s1, p)
    assert :ok = RateLimit.check(s2, p)
    assert :ok = RateLimit.check(s1, p)
    assert :ok = RateLimit.check(s2, p)

    # The principal bucket is now empty even though each session's own
    # bucket still has ~100k tokens: proves the SECOND scope bites.
    assert {:drop, :rate} = RateLimit.check(s1, p)
    assert {:drop, :rate} = RateLimit.check(s2, p)
  end

  # ---- R3: principal keys the bucket (independent per identity) ----

  test "R3: distinct principals get independent buckets (the principal is the key)", %{sid: sid} do
    put_cfg(
      session_rate: 1,
      session_burst: 100_000,
      principal_rate: 1,
      principal_burst: 1,
      disconnect_after_drops: 100
    )

    p1 = "id-#{System.unique_integer([:positive])}"
    p2 = "id-#{System.unique_integer([:positive])}"

    # p1 spends its single principal token.
    assert :ok = RateLimit.check(sid, p1)
    assert {:drop, :rate} = RateLimit.check(sid, p1)

    # p2 has a FRESH bucket — so the principal argument, not the session,
    # is what keys the per-principal scope. (The unspoofability lives at
    # the CALL SITES, which pass the server-resolved identity, never a
    # client value — asserted in the web/bot wiring, not derivable here.)
    assert :ok = RateLimit.check(sid, p2)
  end

  # ---- R5: a good command resets the consecutive-drop escalation ----

  test "R5: an allowed command resets the drop-counter (slow-but-steady is never disconnected)",
       %{sid: sid, principal: p} do
    put_cfg(
      session_rate: 1,
      session_burst: 1,
      principal_rate: 1,
      principal_burst: 100_000,
      disconnect_after_drops: 3
    )

    assert :ok = RateLimit.check(sid, p)
    assert {:drop, :rate} = RateLimit.check(sid, p)
    assert {:drop, :rate} = RateLimit.check(sid, p)
    # drop-counter is now 2 (one below the disconnect threshold of 3).
    assert [{_, 2}] = :ets.lookup(RateLimit.table(), {:drops, sid})

    # Simulate a refill (top the session bucket back up) → the next command
    # is allowed, which RESETS the consecutive-drop counter.
    :ets.insert(RateLimit.table(), {{:session, sid}, 5.0, now_ms()})
    assert :ok = RateLimit.check(sid, p)
    assert [] = :ets.lookup(RateLimit.table(), {:drops, sid})

    # Drain again: it takes a FULL 3 consecutive drops to disconnect — the
    # earlier 2 did not carry over.
    assert {:drop, :rate} = RateLimit.check(sid, p)
    assert {:drop, :rate} = RateLimit.check(sid, p)
    assert {:disconnect, :rate} = RateLimit.check(sid, p)
  end

  # ---- R6: fail-OPEN-but-alarm on an internal error ----

  test "R6: an internal limiter error fails OPEN (allows) and emits a telemetry alarm", %{
    sid: sid,
    principal: p
  } do
    put_cfg(session_rate: 1, session_burst: 3, principal_rate: 1, principal_burst: 3)

    handler = "rate-limit-fail-open-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:commonplace, :mud, :rate_limit, :fail_open],
      fn _event, _measure, _meta, _cfg -> send(test_pid, :fail_open_fired) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    # Corrupt the session bucket row so the refill arithmetic raises inside
    # check/2 — the ETS table itself stays intact (only this row is bad).
    :ets.insert(RateLimit.table(), {{:session, sid}, :not_a_number, now_ms()})

    # Must NOT raise, and must ALLOW (fail-open) — the concurrency cap is
    # the standing backstop; breaking the game for everyone is the wrong
    # trade.
    assert :ok = RateLimit.check(sid, p)
    assert_receive :fail_open_fired, 500
  end

  # ---- lazy-refill + burst-cap (same shape as the vein-regen test) ----

  test "lazy-refill credits elapsed time but CLAMPS at burst", %{sid: sid, principal: p} do
    put_cfg(
      session_rate: 10,
      session_burst: 5,
      principal_rate: 1,
      principal_burst: 100_000,
      disconnect_after_drops: 100
    )

    # Drain the session burst (5), then a drop.
    for _ <- 1..5, do: assert(:ok = RateLimit.check(sid, p))
    assert {:drop, :rate} = RateLimit.check(sid, p)

    # Simulate a long idle: last_refill 10s ago at 10 tok/s = 100 tokens of
    # elapsed credit — but the bucket must CLAMP at burst (5), not overfill.
    :ets.insert(RateLimit.table(), {{:session, sid}, 0.0, now_ms() - 10_000})

    # Exactly `burst` commands are allowed after the idle, then a drop —
    # proving the clamp (a huge Δt does NOT grant more than `burst`).
    for _ <- 1..5, do: assert(:ok = RateLimit.check(sid, p))
    assert {:drop, :rate} = RateLimit.check(sid, p)
  end

  # ---- cleanup: watch/1 reaps the session bucket on session-down ----

  test "watch/1 reaps the per-session bucket + drop-counter when the session dies", %{
    principal: p
  } do
    put_cfg(
      session_rate: 1,
      session_burst: 1,
      principal_rate: 1,
      principal_burst: 100_000,
      disconnect_after_drops: 100
    )

    session = spawn(fn -> Process.sleep(:infinity) end)
    RateLimit.watch(session)

    # Lay down a session bucket + a drop-counter for this pid.
    assert :ok = RateLimit.check(session, p)
    assert {:drop, :rate} = RateLimit.check(session, p)
    assert [{_, _, _}] = :ets.lookup(RateLimit.table(), {:session, session})
    assert [{_, _}] = :ets.lookup(RateLimit.table(), {:drops, session})

    Process.exit(session, :kill)

    # The reap runs in the limiter's `:DOWN` handler — delivered
    # asynchronously to the kill. A single `:sys.get_state` barrier races
    # that delivery (the DOWN may not be in the mailbox yet when get_state
    # is processed → seed-dependent flake, CX-6hxa), so poll until the reap
    # actually lands.
    assert eventually(fn ->
             :ets.lookup(RateLimit.table(), {:session, session}) == [] and
               :ets.lookup(RateLimit.table(), {:drops, session}) == []
           end)
  end

  # Retry `fun` (a boolean predicate) until it holds or the bounded window
  # elapses (~1s). For observing eventually-consistent async state without a
  # fixed, racy sleep.
  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() ->
        true

      retries == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, retries - 1)
    end
  end
end
