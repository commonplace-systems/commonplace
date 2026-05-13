defmodule Commonplace.Bots.RateLimitTest do
  use ExUnit.Case, async: false

  alias Commonplace.Bots.RateLimit

  setup do
    # The application-supervised RateLimit may already be running.
    # Reset its config to tight test values and clear state between
    # tests by re-configuring; for state clearing, restart it under
    # the supervisor.
    bots_sup = Commonplace.Bots.Supervisor
    _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.RateLimit)
    _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.RateLimit)

    {:ok, _pid} = Supervisor.start_child(bots_sup, Commonplace.Bots.RateLimit)

    on_exit(fn ->
      _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.RateLimit)
      _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.RateLimit)
      {:ok, _pid} = Supervisor.start_child(bots_sup, Commonplace.Bots.RateLimit)
    end)

    :ok
  end

  test "default acquire is :ok" do
    assert :ok = RateLimit.acquire("room", "alice")
  end

  test "per-room concurrency cap blocks the third concurrent worker in one room" do
    :ok = RateLimit.config(per_room_concurrency: 2, global_concurrency: 100)

    assert :ok = RateLimit.acquire("a", "alice")
    assert :ok = RateLimit.acquire("a", "bob")
    assert {:throttled, :room_concurrency} = RateLimit.acquire("a", "carol")
  end

  test "global concurrency cap blocks across rooms" do
    :ok = RateLimit.config(per_room_concurrency: 100, global_concurrency: 2)

    assert :ok = RateLimit.acquire("a", "alice")
    assert :ok = RateLimit.acquire("b", "bob")
    assert {:throttled, :global_concurrency} = RateLimit.acquire("c", "carol")
  end

  test "release/2 frees a slot" do
    :ok = RateLimit.config(per_room_concurrency: 1, global_concurrency: 100)

    assert :ok = RateLimit.acquire("a", "alice")
    assert {:throttled, :room_concurrency} = RateLimit.acquire("a", "bob")

    :ok = RateLimit.release("a", "alice")
    assert :ok = RateLimit.acquire("a", "bob")
  end

  test "per-room burst window blocks after N posts" do
    :ok =
      RateLimit.config(
        per_room_max_posts: 2,
        per_room_window_ms: 60_000,
        per_room_concurrency: 100,
        global_concurrency: 100,
        per_bot_cooldown_ms: 0
      )

    :ok = RateLimit.record_post("a", "alice")
    :ok = RateLimit.record_post("a", "alice")

    assert {:throttled, :per_room_burst} = RateLimit.acquire("a", "bob")
  end

  test "per-bot cooldown blocks the same bot but allows others" do
    :ok =
      RateLimit.config(
        per_bot_cooldown_ms: 60_000,
        per_room_max_posts: 100,
        per_room_concurrency: 100,
        global_concurrency: 100
      )

    :ok = RateLimit.record_post("a", "alice")

    assert {:throttled, :per_bot_cooldown} = RateLimit.acquire("a", "alice")
    assert :ok = RateLimit.acquire("a", "bob")
  end

  test "release on unknown room is a no-op" do
    assert :ok = RateLimit.release("ghost", "alice")
  end

  test "snapshot exposes internal counters" do
    :ok = RateLimit.acquire("x", "alice")
    snap = RateLimit.snapshot()
    assert snap.global_concurrency == 1
    assert snap.room_concurrency == %{"x" => 1}
  end
end
