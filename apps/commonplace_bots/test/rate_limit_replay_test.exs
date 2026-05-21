defmodule Commonplace.Bots.RateLimit.ReplayTest do
  @moduledoc """
  CX-q8nk(3): rate-limit replay-from-log rebuild on dispatcher
  subscribe. Recent bot-authored posts in _messages seed both the
  per-room sliding-window counter and per-bot cooldown so a
  dispatcher restart inside the 60s window doesn't allow an extra
  burst.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bots.{Demo, Dispatcher, RateLimit}
  alias Commonplace.Chat.Actions
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bots_rlreplay_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    store_sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(store_sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(store_sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(store_sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()

    bots_sup = Commonplace.Bots.Supervisor

    _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.Dispatcher)
    _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.Dispatcher)
    _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.RateLimit)
    _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.RateLimit)
    {:ok, _pid} = Supervisor.start_child(bots_sup, Commonplace.Bots.RateLimit)

    on_exit(fn ->
      _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.Dispatcher)
      _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.Dispatcher)

      {:ok, _pid} =
        Supervisor.start_child(
          bots_sup,
          Supervisor.child_spec({Commonplace.Bots.Dispatcher, []},
            id: Commonplace.Bots.Dispatcher
          )
        )

      _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.RateLimit)
      _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.RateLimit)
      {:ok, _pid} = Supervisor.start_child(bots_sup, Commonplace.Bots.RateLimit)

      _ = Supervisor.terminate_child(store_sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(store_sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(
          store_sup,
          {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"}
        )

      Commonplace.Tree.DocCache.clear()
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp mint_root do
    uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(Commonplace.Store.CommitStore, uuid, update, nil)
    uuid
  end

  defp restart_dispatcher_with(opts) do
    bots_sup = Commonplace.Bots.Supervisor
    _ = Supervisor.terminate_child(bots_sup, Commonplace.Bots.Dispatcher)
    _ = Supervisor.delete_child(bots_sup, Commonplace.Bots.Dispatcher)

    {:ok, _pid} =
      Supervisor.start_child(
        bots_sup,
        Supervisor.child_spec({Commonplace.Bots.Dispatcher, opts},
          id: Commonplace.Bots.Dispatcher
        )
      )
  end

  describe "RateLimit.seed_from_history/2" do
    test "seeds per-room sliding window from recent ISO posts" do
      :ok =
        RateLimit.config(
          per_room_max_posts: 3,
          per_room_window_ms: 60_000,
          per_room_concurrency: 100,
          global_concurrency: 100,
          per_bot_cooldown_ms: 0
        )

      now = DateTime.utc_now()

      posts =
        for offset_ms <- [-1_000, -5_000, -20_000] do
          ts = DateTime.add(now, offset_ms, :millisecond) |> DateTime.to_iso8601()
          %{bot: "alice", ts: ts}
        end

      :ok = RateLimit.seed_from_history("demo", posts)

      assert {:throttled, :per_room_burst} = RateLimit.acquire("demo", "carol")
    end

    test "ignores posts older than the window" do
      :ok =
        RateLimit.config(
          per_room_max_posts: 1,
          per_room_window_ms: 60_000,
          per_room_concurrency: 100,
          global_concurrency: 100,
          per_bot_cooldown_ms: 0
        )

      now = DateTime.utc_now()

      posts = [
        %{bot: "alice", ts: DateTime.add(now, -3_600_000, :millisecond) |> DateTime.to_iso8601()},
        %{bot: "bob", ts: DateTime.add(now, -7_200_000, :millisecond) |> DateTime.to_iso8601()}
      ]

      :ok = RateLimit.seed_from_history("demo", posts)

      assert :ok = RateLimit.acquire("demo", "carol")
    end

    test "seeds per-bot cooldown from the most recent post" do
      :ok =
        RateLimit.config(
          per_bot_cooldown_ms: 30_000,
          per_room_max_posts: 100,
          per_room_concurrency: 100,
          global_concurrency: 100
        )

      now = DateTime.utc_now()

      posts = [
        %{bot: "alice", ts: DateTime.add(now, -5_000, :millisecond) |> DateTime.to_iso8601()}
      ]

      :ok = RateLimit.seed_from_history("demo", posts)

      assert {:throttled, :per_bot_cooldown} = RateLimit.acquire("demo", "alice")
      assert :ok = RateLimit.acquire("demo", "bob")
    end

    test "skips malformed ISO timestamps silently" do
      :ok =
        RateLimit.config(
          per_room_max_posts: 1,
          per_room_window_ms: 60_000,
          per_room_concurrency: 100,
          global_concurrency: 100,
          per_bot_cooldown_ms: 0
        )

      posts = [%{bot: "alice", ts: "not-a-date"}]
      :ok = RateLimit.seed_from_history("demo", posts)
      assert :ok = RateLimit.acquire("demo", "carol")
    end

    test "empty list is a no-op" do
      :ok = RateLimit.seed_from_history("demo", [])
      snap = RateLimit.snapshot()
      refute Map.has_key?(snap.room_posts, "demo")
    end
  end

  describe "Dispatcher.subscribe_room/3 seed integration" do
    test "subscribing a room with recent bot posts pre-loads RateLimit so the next acquire is throttled" do
      :ok =
        RateLimit.config(
          per_room_max_posts: 3,
          per_room_window_ms: 60_000,
          per_room_concurrency: 100,
          global_concurrency: 100,
          per_bot_cooldown_ms: 0
        )

      root = mint_root()
      demo = Demo.bootstrap(root)

      # Plant 3 bot-authored posts in _messages, just like a prior
      # session would have left behind.
      for _ <- 1..3 do
        {:ok, _} =
          Actions.post_message(demo.messages_uuid, "prior turn",
            room: demo.room,
            signer_id: "bot:alice",
            author_path: "alice.bot"
          )
      end

      # Now boot a fresh dispatcher and subscribe — it should seed
      # from the planted posts.
      restart_dispatcher_with(rate_limit_enabled: true)
      :ok = Dispatcher.subscribe_room(demo.room, demo.room_dir_uuid, demo.messages_uuid)

      # Per-room window now full → next acquire throttles.
      assert {:throttled, :per_room_burst} = RateLimit.acquire(demo.room, "carol")
    end

    test "subscribing a room with only human posts seeds nothing" do
      :ok =
        RateLimit.config(
          per_room_max_posts: 1,
          per_room_window_ms: 60_000,
          per_room_concurrency: 100,
          global_concurrency: 100,
          per_bot_cooldown_ms: 0
        )

      root = mint_root()
      demo = Demo.bootstrap(root)

      for _ <- 1..3 do
        {:ok, _} =
          Actions.post_message(demo.messages_uuid, "human chatter",
            room: demo.room,
            signer_id: "human",
            author_path: "human.usr"
          )
      end

      restart_dispatcher_with(rate_limit_enabled: true)
      :ok = Dispatcher.subscribe_room(demo.room, demo.room_dir_uuid, demo.messages_uuid)

      assert :ok = RateLimit.acquire(demo.room, "carol")
    end

    test "rate_limit_enabled=false skips seeding" do
      :ok =
        RateLimit.config(
          per_room_max_posts: 1,
          per_room_window_ms: 60_000,
          per_room_concurrency: 100,
          global_concurrency: 100,
          per_bot_cooldown_ms: 0
        )

      root = mint_root()
      demo = Demo.bootstrap(root)

      for _ <- 1..2 do
        {:ok, _} =
          Actions.post_message(demo.messages_uuid, "prior",
            room: demo.room,
            signer_id: "bot:alice",
            author_path: "alice.bot"
          )
      end

      restart_dispatcher_with(rate_limit_enabled: false)
      :ok = Dispatcher.subscribe_room(demo.room, demo.room_dir_uuid, demo.messages_uuid)

      # No seeding happened, so RateLimit's room_posts is empty.
      snap = RateLimit.snapshot()
      refute Map.has_key?(snap.room_posts, demo.room)
    end
  end
end
