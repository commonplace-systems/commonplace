defmodule Commonplace.Bots.RateLimit do
  @moduledoc """
  RAM-resident rate-limit state for the bot dispatcher.

  Holds three classes of bookkeeping per (room, bot):

    * Per-room sliding-window post counter (default: 3 posts per
      60 seconds). Counts every successfully-posted message
      whose author_path ends in `.bot`. Pruned lazily on each
      check.
    * Per-bot cooldown (default: 10s after the last post
      completion). A bot whose last post was less than the
      cooldown ago is throttled regardless of room budget.
    * Per-room and global concurrency caps (defaults: 2 per
      room, 3 global). Counted by `acquire` / `release` calls
      bracketing the worker task's lifetime.

  ## Why RAM, not a substrate doc

  Per the converged design with commonplace-plan: live counters
  written every post would thrash the commit DAG. Audit /
  observability lives in `__bot_activity` (append-only YArray of
  JSON); live counters live here.

  ## Restart semantics

  Counters are RAM-only, so the GenServer boots with empty state.
  The base failure mode is *more-permissive-at-boot* (empty
  counters → a sliding window could briefly allow up to one extra
  burst before it re-converges), which is the safe direction to
  fail.

  That gap is closed by `seed_from_history/2` (CX-q8nk(3)): the
  dispatcher calls it from `subscribe_room/3`, rebuilding a room's
  sliding-window + per-bot-cooldown counters from the recent
  bot-authored posts in the room's `_messages` doc — so a restart
  mid-window can't grant an extra burst. (Note the source is
  `_messages`, the durable chat log, not `__bot_activity`.)
  Concurrency counters are NOT seeded — no workers run at boot —
  and posts older than the window/cooldown are dropped so replaying
  ancient history can't over-count.

  ## Public API

      RateLimit.acquire(room, bot)
        :: :ok | {:throttled, reason}

      RateLimit.release(room, bot)
        :: :ok        # always — never raises on unknown bot

      RateLimit.record_post(room, bot)
        :: :ok        # called by Worker on successful post_message

      RateLimit.config(opts)
        :: :ok        # set process-wide limits (used by tests)

      RateLimit.seed_from_history(room, posts)
        :: :ok        # re-seed window/cooldown counters on restart
                      # (called by Dispatcher.subscribe_room/3) —
                      # see "Restart semantics" above

  `reason` ∈ {:per_room_burst, :per_bot_cooldown, :room_concurrency, :global_concurrency}.
  """

  use GenServer

  @default_per_room_window_ms 60_000
  @default_per_room_max_posts 3
  @default_per_bot_cooldown_ms 10_000
  @default_per_room_concurrency 2
  @default_global_concurrency 3

  defstruct config: nil,
            room_posts: %{},
            last_post_at: %{},
            room_concurrency: %{},
            global_concurrency: 0

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec acquire(String.t(), String.t()) :: :ok | {:throttled, atom()}
  def acquire(room, bot), do: GenServer.call(__MODULE__, {:acquire, room, bot})

  @spec release(String.t(), String.t()) :: :ok
  def release(room, bot), do: GenServer.call(__MODULE__, {:release, room, bot})

  @spec record_post(String.t(), String.t()) :: :ok
  def record_post(room, bot), do: GenServer.call(__MODULE__, {:record_post, room, bot})

  @spec config(keyword()) :: :ok
  def config(opts), do: GenServer.call(__MODULE__, {:config, opts})

  @spec snapshot() :: map()
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @typedoc """
  A historical bot post used to seed sliding-window counters on
  dispatcher boot. `ts` is an ISO-8601 timestamp; RateLimit
  converts to monotonic-equivalent internally via
  `now_monotonic - DateTime.diff(now_utc, ts)`.
  """
  @type historical_post :: %{required(:bot) => String.t(), required(:ts) => String.t()}

  @doc """
  CX-q8nk(3): seed sliding-window counters for `room` from recent
  bot-authored posts. Used by `Dispatcher.subscribe_room/3` to
  rebuild rate-limit state from the room's `_messages` doc after
  a dispatcher restart — without this, the dispatcher boots with
  empty counters (more-permissive-at-boot) and would allow up to
  one extra burst before the sliding window converges.

  Only posts within `per_room_window_ms` of now are kept;
  anything older is dropped on the floor (replaying ancient
  history would over-count). Per-bot cooldowns are seeded from
  the most-recent post per bot within `per_bot_cooldown_ms`.

  Concurrency counters are NOT seeded — no workers are running at
  boot.
  """
  @spec seed_from_history(String.t(), [historical_post()]) :: :ok
  def seed_from_history(room, posts) when is_binary(room) and is_list(posts) do
    GenServer.call(__MODULE__, {:seed_from_history, room, posts})
  end

  ## GenServer

  @impl true
  def init(opts) do
    {:ok, %__MODULE__{config: build_config(opts)}}
  end

  defp build_config(opts) do
    %{
      per_room_window_ms: Keyword.get(opts, :per_room_window_ms, @default_per_room_window_ms),
      per_room_max_posts: Keyword.get(opts, :per_room_max_posts, @default_per_room_max_posts),
      per_bot_cooldown_ms: Keyword.get(opts, :per_bot_cooldown_ms, @default_per_bot_cooldown_ms),
      per_room_concurrency:
        Keyword.get(opts, :per_room_concurrency, @default_per_room_concurrency),
      global_concurrency: Keyword.get(opts, :global_concurrency, @default_global_concurrency)
    }
  end

  @impl true
  def handle_call({:acquire, room, bot}, _from, state) do
    now = System.monotonic_time(:millisecond)
    state = prune_room(state, room, now)

    cond do
      cooldown_active?(state, room, bot, now) ->
        {:reply, {:throttled, :per_bot_cooldown}, state}

      length(Map.get(state.room_posts, room, [])) >= state.config.per_room_max_posts ->
        {:reply, {:throttled, :per_room_burst}, state}

      Map.get(state.room_concurrency, room, 0) >= state.config.per_room_concurrency ->
        {:reply, {:throttled, :room_concurrency}, state}

      state.global_concurrency >= state.config.global_concurrency ->
        {:reply, {:throttled, :global_concurrency}, state}

      true ->
        state = %{
          state
          | room_concurrency: Map.update(state.room_concurrency, room, 1, &(&1 + 1)),
            global_concurrency: state.global_concurrency + 1
        }

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:release, room, _bot}, _from, state) do
    new_room =
      case Map.get(state.room_concurrency, room, 0) do
        n when n <= 1 -> Map.delete(state.room_concurrency, room)
        n -> Map.put(state.room_concurrency, room, n - 1)
      end

    state = %{
      state
      | room_concurrency: new_room,
        global_concurrency: max(state.global_concurrency - 1, 0)
    }

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:record_post, room, bot}, _from, state) do
    now = System.monotonic_time(:millisecond)

    state = %{
      state
      | room_posts: Map.update(state.room_posts, room, [now], fn ts -> [now | ts] end),
        last_post_at: Map.put(state.last_post_at, {room, bot}, now)
    }

    {:reply, :ok, prune_room(state, room, now)}
  end

  @impl true
  def handle_call({:config, opts}, _from, state) do
    {:reply, :ok, %{state | config: build_config(opts)}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, Map.from_struct(state), state}
  end

  @impl true
  def handle_call({:seed_from_history, room, posts}, _from, state) do
    now_mono = System.monotonic_time(:millisecond)
    now_utc = DateTime.utc_now()
    window_ms = state.config.per_room_window_ms
    cooldown_ms = state.config.per_bot_cooldown_ms

    {room_ts, latest_per_bot} =
      posts
      |> Enum.reduce({[], %{}}, fn %{bot: bot, ts: ts_iso}, {ts_acc, bot_acc} ->
        case parse_iso(ts_iso) do
          {:ok, dt} ->
            delta_ms = DateTime.diff(now_utc, dt, :millisecond)

            cond do
              delta_ms < 0 ->
                # Future ts in the log (clock skew or test artifact);
                # treat as "now" for safety so it counts as recent.
                {[now_mono | ts_acc], maybe_update_latest(bot_acc, bot, now_mono, cooldown_ms)}

              delta_ms <= window_ms ->
                mono_eq = now_mono - delta_ms
                {[mono_eq | ts_acc], maybe_update_latest(bot_acc, bot, mono_eq, cooldown_ms)}

              true ->
                # Outside the post-burst window — skip from room_posts.
                # Still consider it for cooldown if recent enough.
                if delta_ms <= cooldown_ms do
                  mono_eq = now_mono - delta_ms
                  {ts_acc, maybe_update_latest(bot_acc, bot, mono_eq, cooldown_ms)}
                else
                  {ts_acc, bot_acc}
                end
            end

          :error ->
            {ts_acc, bot_acc}
        end
      end)

    room_posts =
      if room_ts == [] do
        Map.delete(state.room_posts, room)
      else
        Map.put(state.room_posts, room, Enum.sort(room_ts, :desc))
      end

    last_post_at =
      Enum.reduce(latest_per_bot, state.last_post_at, fn {bot, ts}, acc ->
        Map.put(acc, {room, bot}, ts)
      end)

    {:reply, :ok, %{state | room_posts: room_posts, last_post_at: last_post_at}}
  end

  defp maybe_update_latest(acc, bot, mono_eq, cooldown_ms) do
    # Only track per-bot latest if it's within the cooldown window.
    if mono_eq + cooldown_ms < System.monotonic_time(:millisecond) do
      acc
    else
      Map.update(acc, bot, mono_eq, fn prior -> max(prior, mono_eq) end)
    end
  end

  defp parse_iso(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_iso(_), do: :error

  defp prune_room(state, room, now) do
    cutoff = now - state.config.per_room_window_ms

    case Map.get(state.room_posts, room) do
      nil ->
        state

      list ->
        kept = Enum.filter(list, fn ts -> ts >= cutoff end)

        new_room_posts =
          if kept == [],
            do: Map.delete(state.room_posts, room),
            else: Map.put(state.room_posts, room, kept)

        %{state | room_posts: new_room_posts}
    end
  end

  defp cooldown_active?(state, room, bot, now) do
    case Map.get(state.last_post_at, {room, bot}) do
      nil -> false
      then -> now - then < state.config.per_bot_cooldown_ms
    end
  end
end
