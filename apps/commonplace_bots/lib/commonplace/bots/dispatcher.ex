defmodule Commonplace.Bots.Dispatcher do
  @moduledoc """
  Singleton GenServer that watches chat events and wakes bots.

  Sibling to `Commonplace.Sync.Agent`. **Not** orchestrator-managed
  (the orchestrator compiles processes from `.exs` source docs in
  the CRDT tree; bot-dispatcher is umbrella infra). Started under
  `Commonplace.Bots.Application`.

  ## Lifecycle

  Boot: subscribes to no rooms by default. Callers (demo
  bootstrap, future auto-discovery) register rooms via:

      Dispatcher.subscribe_room(room_name, room_dir_uuid, messages_uuid)

  Each `subscribe_room/3` call:

    * Subscribes the dispatcher process to the room's
      `magenta:chat:<room>:events` topic.
    * Stores the `(room_dir_uuid, messages_uuid)` pair so events
      arriving on that topic can be enriched with the message text
      and the bot enumeration target.

  Messages arrive as `{:magenta, _topic, %Magenta{}}`. For each
  `"post"` (and only `"post"` in v0) verb whose `"author_path"`
  does **not** end in `.bot`, the dispatcher:

    1. Loads the message body from the `_messages` doc.
    2. Enumerates `*.bot/` entries under the room directory.
    3. For each such entity (a `.bot/` directory loaded into a struct —
       persona, memory, trigger rules; see `Commonplace.Bots.Entity`),
       calls `Trigger.evaluate/3` with the enriched event.
    4. On a wake decision (`:wake` or a wake tuple), acquires a
       rate-limit slot (see below) and, if granted, hands off to
       `:worker_hook`. The production default spawns the real
       `Commonplace.Bots.Worker` as a supervised Task
       (`spawn_worker/4`); tests pass a 3-arity hook (e.g.
       `&log_wake/3`) to observe the wake without running a worker.

  Bot→bot loop prevention runs *before* the steps above: any event
  whose `author_path` is bot-authored — it ends in `.bot`, or carries
  the `.bot:` session form (e.g. `alice.bot:3f2a`) — is dropped before
  bots are even enumerated. This is the loop-prevention contract agreed
  with commonplace-plan ("controlled by rate limits, not by
  bots-ignore-bots" — except for the strict no-bot-replies-to-bot edge,
  which is here).

  ## Rate limiting and activity logging

  A wake that passes loop-prevention and trigger eval still has to
  acquire a slot from `Commonplace.Bots.RateLimit` (per-room sliding
  window + per-bot cooldown + concurrency caps) before a worker runs;
  `spawn_worker/4` releases the slot whether the worker exits cleanly,
  crashes, or hits a cap. On `subscribe_room/3` the dispatcher re-seeds
  those sliding-window counters from recent bot posts in the room's
  `_messages` doc (CX-q8nk), so a restart mid-window can't grant an
  extra burst before the counters reconverge.

  Decisions are also mirrored into the room's `__bot_activity` substrate
  doc — an append-only audit log of bot activity, owned by
  `Commonplace.Bots.Activity`. Two kinds of entry land there: the trigger
  outcome at dispatch time (`fired` when a rate-limit slot is granted,
  `suppressed` when throttled), and — fanned out from a
  `[:commonplace, :bots, :worker, :finished]` telemetry handler
  (CX-gptu) — the *worker* outcome once it ends (`completed` / `cap_hit`
  / `error`). (A `:skip` trigger decision emits telemetry only, not an
  activity entry.) The worker stays substrate-pure; the dispatcher owns
  this fan-out so the audit doc reflects the full lifecycle, not just the
  trigger decision. Activity writes are best-effort (failures are
  observability noise, not behavior bugs).
  """

  use GenServer
  require Logger

  alias Commonplace.Bots.{Activity, Agenda, Entity, RateLimit, Trigger}
  alias Commonplace.Chat.Messages
  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Presence
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.DocBuilder

  # Recency window for the heartbeat "thread quiet" check: a room whose
  # newest message is older than this (or has no messages) counts as
  # quiet. Cheap proxy for "no new message since the bot last acted".
  @thread_quiet_window_ms 60_000

  defstruct rooms: %{},
            store: CommitStoreClient,
            worker_hook: nil,
            rate_limit_enabled: true,
            timers: %{},
            node_ctx: nil

  @type room_info :: %{
          required(:dir_uuid) => String.t(),
          required(:messages_uuid) => String.t(),
          required(:activity_uuid) => String.t() | nil
        }

  @type t :: %__MODULE__{
          rooms: %{String.t() => room_info()},
          store: module() | atom(),
          worker_hook: (String.t(), Entity.t(), map() -> any()),
          rate_limit_enabled: boolean(),
          timers: %{{String.t(), String.t()} => reference()},
          node_ctx: term() | nil
        }

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a chat room. The dispatcher subscribes to its event
  topic and remembers the room's directory + messages-doc UUIDs.
  Idempotent — re-registering with the same UUIDs is a no-op;
  with different UUIDs updates the entry in place.
  """
  @spec subscribe_room(String.t(), String.t(), String.t()) :: :ok
  def subscribe_room(room_name, room_dir_uuid, messages_uuid)
      when is_binary(room_name) and is_binary(room_dir_uuid) and is_binary(messages_uuid) do
    GenServer.call(__MODULE__, {:subscribe_room, room_name, room_dir_uuid, messages_uuid})
  end

  @doc "Unsubscribe from a room and forget its registration."
  @spec unsubscribe_room(String.t()) :: :ok
  def unsubscribe_room(room_name) when is_binary(room_name) do
    GenServer.call(__MODULE__, {:unsubscribe_room, room_name})
  end

  @doc "Return the currently-registered rooms (for inspection / tests)."
  def registered_rooms do
    GenServer.call(__MODULE__, :registered_rooms)
  end

  ## GenServer

  @impl true
  def init(opts) do
    state = %__MODULE__{
      rooms: %{},
      store: Keyword.get(opts, :store, CommitStoreClient),
      # When nil, the dispatcher defaults to production mode:
      # `Dispatcher.spawn_worker/4` supervised under WorkerSupervisor,
      # with the real Anthropic client and the registered room's
      # messages_uuid. Tests pass a 3-arity function to intercept the
      # wake without spawning a worker.
      worker_hook: Keyword.get(opts, :worker_hook),
      rate_limit_enabled: Keyword.get(opts, :rate_limit_enabled, true),
      # Resolve the node's signing context ONCE here (not per tick): it
      # signs the presence keep-alive beat (see `beat_presence/4`). A test
      # may inject one via `opts[:node_ctx]`.
      node_ctx: resolve_node_ctx(opts)
    }

    # CX-gptu: surface worker outcomes (end_turn / cap_hit / error)
    # into __bot_activity so the substrate reflects the full
    # lifecycle, not just the trigger decision. Telemetry → activity
    # fan-out lives here in the dispatcher (the activity-logging
    # owner); the worker stays substrate-pure.
    handler_id = "bots-dispatcher-worker-finished-#{:erlang.unique_integer([:positive])}"
    dispatcher_pid = self()

    :telemetry.attach(
      handler_id,
      [:commonplace, :bots, :worker, :finished],
      fn _event, _measurements, meta, _config ->
        send(dispatcher_pid, {:worker_finished, meta})
      end,
      nil
    )

    Process.put(:telemetry_handler_id, handler_id)

    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    case Process.get(:telemetry_handler_id) do
      nil -> :ok
      id -> :telemetry.detach(id)
    end
  end

  @impl true
  def handle_call({:subscribe_room, room, dir_uuid, messages_uuid}, _from, state) do
    case Map.get(state.rooms, room) do
      nil ->
        Phoenix.PubSub.subscribe(Commonplace.PubSub, "magenta:chat:#{room}:events")

      _existing ->
        :ok
    end

    activity_uuid =
      case Activity.ensure_doc(dir_uuid, state.store) do
        {:ok, uuid} -> uuid
        _ -> nil
      end

    info = %{dir_uuid: dir_uuid, messages_uuid: messages_uuid, activity_uuid: activity_uuid}

    # CX-q8nk(3): seed RateLimit sliding-window counters from
    # recent bot posts in _messages so a dispatcher restart inside
    # a 60s window doesn't allow an extra burst before counters
    # converge. Concurrency counters stay at zero — no workers run
    # at boot. Skip silently when rate limits are disabled (tests).
    if state.rate_limit_enabled do
      seed_rate_limit(room, messages_uuid, state.store)
    end

    state = %{state | rooms: Map.put(state.rooms, room, info)}

    # Camillo C3b: opt-in heartbeat source. For each bot in the room whose
    # bot.json declares a positive "heartbeat_ms", schedule the first
    # self-tick. Bots without the knob get no timer (existing bots
    # unchanged). Re-registration cancels any prior timers first.
    state = schedule_heartbeats(room, info, state)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unsubscribe_room, room}, _from, state) do
    if Map.has_key?(state.rooms, room) do
      Phoenix.PubSub.unsubscribe(Commonplace.PubSub, "magenta:chat:#{room}:events")
    end

    state = %{state | rooms: Map.delete(state.rooms, room)}
    state = cancel_room_timers(state, room)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:registered_rooms, _from, state) do
    {:reply, state.rooms, state}
  end

  @impl true
  def handle_info({:magenta, _path, msg}, state) do
    handle_chat_event(msg, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:worker_finished, meta}, state) do
    log_outcome(state, meta)
    {:noreply, state}
  end

  # Camillo C3b heartbeat tick. The `"kind" => "heartbeat"` tag is set
  # HERE, internally — it is NEVER read from any chat payload — so this
  # path is the ONLY way a heartbeat event comes into being (unspoofable
  # by chat). Ordering is load-bearing: the bot's presence is beaten on
  # EVERY tick, BEFORE the skip/wake decision, so a resting (:skip) bot
  # still stays alive for the reaper.
  @impl true
  def handle_info({:heartbeat, room, dir_uuid, name, cadence}, state) do
    if Map.has_key?(state.rooms, room) do
      # 1. ALWAYS beat presence first — a :skip tick still keeps the bot
      #    alive (skip = no LLM call, NEVER no keep-alive).
      beat_presence(room, dir_uuid, name, state)

      # 2-3. Construct the internally-tagged heartbeat event and route it
      #      through the SAME evaluate_and_dispatch path chat uses.
      maybe_dispatch_heartbeat(room, dir_uuid, name, state)

      # 4. Reschedule the next tick so the heartbeat is periodic.
      ref = Process.send_after(self(), {:heartbeat, room, dir_uuid, name, cadence}, cadence)
      {:noreply, put_timer(state, room, name, ref)}
    else
      # Room was unsubscribed; a queued tick may still arrive. Drop it
      # (no beat, no reschedule).
      {:noreply, state}
    end
  end

  defp maybe_dispatch_heartbeat(room, dir_uuid, name, state) do
    case Entity.load(state.store, dir_uuid, name) do
      {:ok, entity} ->
        # The "kind" is stamped HERE, internally — the unspoofable
        # property. A chat post can NEVER produce this shape.
        event = %{
          "verb" => "heartbeat",
          "kind" => "heartbeat",
          "room" => room,
          "agenda_empty" => agenda_empty?(entity, state),
          "thread_quiet" => thread_quiet?(room, state)
        }

        evaluate_and_dispatch(room, entity, event, state)

      _ ->
        :ok
    end
  end

  ## Event routing

  defp handle_chat_event(%{type: "post", payload: payload}, state) do
    room = Map.get(payload, "room") || infer_room(payload, state)
    author = Map.get(payload, "author_path", "")

    cond do
      room == nil ->
        :ok

      bot_authored?(author) ->
        :telemetry.execute(
          [:commonplace, :bots, :dispatcher, :bot_authored_skip],
          %{system_time: System.system_time()},
          %{author_path: author}
        )

      true ->
        case Map.get(state.rooms, room) do
          nil -> :ok
          info -> route_post(room, info, payload, state)
        end
    end
  end

  defp handle_chat_event(_msg, _state), do: :ok

  defp route_post(room, info, payload, state) do
    message_id = Map.get(payload, "message_id")

    with text when is_binary(text) <- load_message_text(state.store, info.messages_uuid, message_id),
         {:ok, bots} <- Entity.list_in_room(state.store, info.dir_uuid) do
      event =
        payload
        # C3b unspoofable-by-chat: a chat payload must NEVER carry a
        # "kind" into the event — the heartbeat kind is dispatcher-tagged
        # only (see handle_info/2). Strip any "kind" a crafted payload
        # smuggled in so this path can only ever yield verb "post".
        |> Map.delete("kind")
        |> Map.put("verb", "post")
        |> Map.put("room", room)
        |> Map.put("text", text)

      Enum.each(bots, fn %{name: suffixed_name, dir_uuid: dir_uuid} ->
        case Entity.load(state.store, dir_uuid, suffixed_name) do
          {:ok, entity} ->
            evaluate_and_dispatch(room, entity, event, state)

          {:error, reason} ->
            :telemetry.execute(
              [:commonplace, :bots, :dispatcher, :entity_load_failed],
              %{system_time: System.system_time()},
              %{room: room, bot: suffixed_name, reason: reason}
            )
        end
      end)
    else
      _ -> :ok
    end
  end

  defp evaluate_and_dispatch(room, entity, event, state) do
    case Trigger.evaluate(entity.trigger_kind, event, entity) do
      :skip ->
        :telemetry.execute(
          [:commonplace, :bots, :dispatcher, :trigger_skipped],
          %{system_time: System.system_time()},
          %{room: room, bot: entity.name}
        )

      decision when decision == :wake or is_tuple(decision) ->
        case maybe_acquire(state, room, entity.name) do
          :ok ->
            :telemetry.execute(
              [:commonplace, :bots, :dispatcher, :trigger_fired],
              %{system_time: System.system_time()},
              %{room: room, bot: entity.name}
            )

            log_activity(state, room, %{
              "room" => room,
              "bot" => entity.name,
              "decision" => "fired",
              "message_id" => Map.get(event, "message_id")
            })

            invoke_worker(state, room, entity, event)

          {:throttled, reason} ->
            :telemetry.execute(
              [:commonplace, :bots, :dispatcher, :trigger_suppressed],
              %{system_time: System.system_time()},
              %{room: room, bot: entity.name, reason: reason}
            )

            log_activity(state, room, %{
              "room" => room,
              "bot" => entity.name,
              "decision" => "suppressed",
              "reason" => to_string(reason),
              "message_id" => Map.get(event, "message_id")
            })
        end
    end
  end

  defp maybe_acquire(%{rate_limit_enabled: false}, _room, _bot), do: :ok

  defp maybe_acquire(_state, room, bot) do
    RateLimit.acquire(room, bot)
  end

  defp invoke_worker(%{worker_hook: hook} = _state, room, entity, event)
       when is_function(hook, 3) do
    hook.(room, entity, event)
  end

  defp invoke_worker(state, room, entity, event) do
    messages_uuid = get_in(state.rooms, [room, :messages_uuid])

    __MODULE__.spawn_worker(room, entity, event,
      messages_uuid: messages_uuid,
      store: state.store
    )
  end

  # CX-q8nk(3): on subscribe, walk the room's _messages doc for
  # bot-authored posts and hand them to RateLimit. Best-effort —
  # failures here surface only as telemetry; the room still
  # subscribes either way.
  defp seed_rate_limit(room, messages_uuid, store) do
    try do
      case DocBuilder.reconstruct_snapshot(store, messages_uuid) do
        {:ok, doc} ->
          posts =
            doc
            |> Messages.materialize()
            |> Enum.filter(fn e -> bot_authored?(Map.get(e, "author_path", "")) end)
            |> Enum.map(fn e -> %{bot: bot_name(Map.get(e, "author_path", "")), ts: Map.get(e, "ts")} end)

          if posts != [] do
            RateLimit.seed_from_history(room, posts)

            :telemetry.execute(
              [:commonplace, :bots, :dispatcher, :rate_limit_seeded],
              %{system_time: System.system_time()},
              %{room: room, post_count: length(posts)}
            )
          end

        _ ->
          :ok
      end
    rescue
      e ->
        :telemetry.execute(
          [:commonplace, :bots, :dispatcher, :rate_limit_seed_failed],
          %{system_time: System.system_time()},
          %{room: room, reason: Exception.message(e)}
        )
    catch
      kind, reason ->
        :telemetry.execute(
          [:commonplace, :bots, :dispatcher, :rate_limit_seed_failed],
          %{system_time: System.system_time()},
          %{room: room, reason: "#{kind}: #{inspect(reason)}"}
        )
    end
  end

  defp bot_name(author_path) when is_binary(author_path) do
    case Regex.run(~r/^(.+?)\.bot(?::.+)?$/, author_path) do
      [_, name] -> name
      _ -> author_path
    end
  end

  defp log_activity(state, room, entry) do
    case Map.get(state.rooms, room) do
      %{activity_uuid: uuid} when is_binary(uuid) ->
        # Best-effort; failures are observability noise, not behavior bugs.
        Task.start(fn -> Activity.append(uuid, entry, state.store) end)
        :ok

      _ ->
        :ok
    end
  end

  # CX-gptu: translate a worker_finished telemetry meta into an
  # __bot_activity entry. Outcomes map to the schema's reserved
  # decisions:
  #
  #   {:ok, :end_turn}        → "completed"
  #   {:cap_hit, :calls|...}  → "cap_hit"  + reason
  #   {:error, _}             → "error"    + reason
  defp log_outcome(state, %{room: room, bot: bot, outcome: outcome} = _meta) do
    entry = outcome_entry(room, bot, outcome)
    log_activity(state, room, entry)
  end

  defp log_outcome(_state, _meta), do: :ok

  defp outcome_entry(room, bot, {:ok, :end_turn}) do
    %{"room" => room, "bot" => bot, "decision" => "completed"}
  end

  defp outcome_entry(room, bot, {:cap_hit, which}) do
    %{
      "room" => room,
      "bot" => bot,
      "decision" => "cap_hit",
      "reason" => to_string(which)
    }
  end

  defp outcome_entry(room, bot, {:error, reason}) do
    %{
      "room" => room,
      "bot" => bot,
      "decision" => "error",
      "reason" => inspect(reason)
    }
  end

  defp outcome_entry(room, bot, other) do
    %{
      "room" => room,
      "bot" => bot,
      "decision" => "error",
      "reason" => "unexpected outcome: #{inspect(other)}"
    }
  end

  defp bot_authored?(author_path) when is_binary(author_path) do
    String.ends_with?(author_path, ".bot") or String.contains?(author_path, ".bot:")
  end

  defp bot_authored?(_), do: false

  ## Heartbeat source (Camillo C3b)

  # Cancel any timers for this room, then schedule the first tick for
  # each bot whose bot.json declares a positive "heartbeat_ms".
  defp schedule_heartbeats(room, info, state) do
    state = cancel_room_timers(state, room)

    bots =
      case Entity.list_in_room(state.store, info.dir_uuid) do
        {:ok, bs} -> bs
        _ -> []
      end

    Enum.reduce(bots, state, fn %{name: name, dir_uuid: bot_dir}, acc ->
      case Entity.load(state.store, bot_dir, name) do
        {:ok, entity} ->
          case heartbeat_ms(entity.bot_config) do
            ms when is_integer(ms) and ms > 0 ->
              ref = Process.send_after(self(), {:heartbeat, room, bot_dir, name, ms}, ms)
              put_timer(acc, room, name, ref)

            _ ->
              acc
          end

        _ ->
          acc
      end
    end)
  end

  defp heartbeat_ms(%{} = cfg) do
    case Map.get(cfg, "heartbeat_ms") do
      ms when is_integer(ms) -> ms
      _ -> nil
    end
  end

  defp heartbeat_ms(_), do: nil

  defp put_timer(state, room, name, ref) do
    key = {room, name}

    case Map.get(state.timers, key) do
      old when is_reference(old) -> Process.cancel_timer(old)
      _ -> :ok
    end

    %{state | timers: Map.put(state.timers, key, ref)}
  end

  defp cancel_room_timers(state, room) do
    timers =
      Enum.reduce(state.timers, %{}, fn {{r, _} = key, ref}, acc ->
        if r == room do
          if is_reference(ref), do: Process.cancel_timer(ref)
          acc
        else
          Map.put(acc, key, ref)
        end
      end)

    %{state | timers: timers}
  end

  # Beat the bot's `.usr` presence, best-effort. Discovers by name in the
  # room dir first, then the bot's own dir; graceful (no-op) if none.
  # NEVER gates behavior — a failed beat is observability noise.
  #
  # Attribution split (cp-plan #8716, the SIGNS binding = "sign what you
  # did"): the keep-alive beat is a RUNTIME FACT, not a Camillo turn — a
  # `:skip` tick performs no cognition — so it is NODE-signed (every tick,
  # every bot on the general runtime). Only status/MODE changes
  # (resting/musing/attending) are the bot's OWN assertions and are
  # BOT-signed during its actual turns (the C2 pattern). This keeps the
  # presence @-shadow an honest attention audit: it attributes cognition
  # only to real turns, never to rest. A node-warmed beat also makes a
  # bot's liveness == its runtime's liveness — if the dispatcher dies,
  # beats stop and the reaper takes the residents. `state.node_ctx` is
  # resolved once at init; under enforce a node-signed presence write
  # lands (node broadly trusted, bypasses the `{:presence}` carve).
  defp beat_presence(room, bot_dir_uuid, name, state) do
    stripped = strip_bot_suffix(name)

    dirs =
      [get_in(state.rooms, [room, :dir_uuid]), bot_dir_uuid]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    try do
      case Enum.find_value(dirs, fn d -> find_usr_presence(d, stripped, state.store) end) do
        uuid when is_binary(uuid) ->
          Presence.heartbeat(uuid, state.store, signing_context: state.node_ctx)
          :ok

        _ ->
          :ok
      end
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp find_usr_presence(dir_uuid, stripped_name, store) do
    case DocBuilder.reconstruct_snapshot(store, dir_uuid) do
      {:ok, doc} ->
        doc
        |> Presence.discover(:usr)
        |> Enum.find_value(fn entry ->
          case Presence.parse_honorific(entry.name) do
            {:ok, n, :usr} -> if n == stripped_name, do: entry.node_id, else: nil
            _ -> nil
          end
        end)

      _ ->
        nil
    end
  end

  defp strip_bot_suffix(name) do
    if String.ends_with?(name, ".bot") do
      String.replace_suffix(name, ".bot", "")
    else
      name
    end
  end

  # The node signing context that signs the presence keep-alive beat.
  # Resolved ONCE at init (cp-plan #8716: not per tick). A test may inject
  # one via `opts[:node_ctx]`; otherwise the node's own context, or `nil`
  # when unavailable (beat then unsigned — harmless on a permissive node,
  # matching the `.exe` presence-flicker default).
  defp resolve_node_ctx(opts) do
    case Keyword.get(opts, :node_ctx) do
      %Commonplace.Crypto.SigningContext{} = ctx ->
        ctx

      _ ->
        case NodeIdentity.signing_context() do
          {:ok, ctx} -> ctx
          _ -> nil
        end
    end
  end

  defp agenda_empty?(entity, state) do
    try do
      Agenda.read(entity, state.store) == []
    rescue
      _ -> true
    catch
      _, _ -> true
    end
  end

  # "Thread quiet" — no new message in the room since the bot last acted,
  # approximated cheaply as: the room's newest message ts is older than
  # @thread_quiet_window_ms (or there are no messages at all).
  defp thread_quiet?(room, state) do
    case Map.get(state.rooms, room) do
      %{messages_uuid: muid} when is_binary(muid) ->
        case DocBuilder.reconstruct_snapshot(state.store, muid) do
          {:ok, doc} ->
            doc
            |> Messages.list()
            |> newest_ts()
            |> quiet_by_ts?()

          _ ->
            true
        end

      _ ->
        true
    end
  end

  defp newest_ts(entries) do
    tss =
      entries
      |> Enum.map(&Map.get(&1, "ts"))
      |> Enum.filter(&is_binary/1)

    case tss do
      [] -> nil
      _ -> Enum.max(tss)
    end
  end

  defp quiet_by_ts?(nil), do: true

  defp quiet_by_ts?(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} ->
        DateTime.diff(DateTime.utc_now(), dt, :millisecond) > @thread_quiet_window_ms

      _ ->
        true
    end
  end

  defp quiet_by_ts?(_), do: true

  defp infer_room(_payload, state) do
    # When only one room is registered, route the event to it.
    # Phase 3 helper for tests; phase 6 will read the room name
    # from the magenta topic when chat broadcasts include it.
    case Map.keys(state.rooms) do
      [only] -> only
      _ -> nil
    end
  end

  defp load_message_text(store, messages_uuid, message_id) do
    case DocBuilder.reconstruct_snapshot(store, messages_uuid) do
      {:ok, doc} ->
        doc
        |> Messages.list()
        |> Enum.find_value(fn entry ->
          if Map.get(entry, "id") == message_id, do: Map.get(entry, "text")
        end)

      _ ->
        nil
    end
  end

  @doc """
  Logging-only worker_hook for tests / development. Pass as
  `worker_hook: &Dispatcher.log_wake/3` to inspect dispatch
  decisions without spawning a worker.
  """
  def log_wake(room, entity, event) do
    Logger.info(
      "[bots.dispatcher] wake bot=#{entity.name} room=#{room} msg=#{Map.get(event, "message_id")}"
    )

    :ok
  end

  @doc """
  Default production worker_hook: spawn the Worker as a
  supervised Task and ensure `RateLimit.release/2` runs whether
  the worker exits cleanly, crashes, or hits a cap.

  Tests pass their own `worker_hook` and are responsible for
  calling `release/2` themselves (or disabling rate limits via
  `rate_limit_enabled: false`).
  """
  def spawn_worker(room, entity, event, opts \\ []) do
    bot = entity.name

    Task.Supervisor.start_child(Commonplace.Bots.WorkerSupervisor, fn ->
      try do
        Commonplace.Bots.Worker.run(room, entity, event, opts)
      after
        RateLimit.release(room, bot)
      end
    end)
  end
end
