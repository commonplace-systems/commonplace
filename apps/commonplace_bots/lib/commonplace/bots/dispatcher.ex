defmodule Commonplace.Bots.Dispatcher do
  @moduledoc """
  Singleton GenServer that watches chat events and wakes bots.

  Sibling to `Commonplace.Sync.Agent`. **Not** orchestrator-managed
  (the orchestrator compiles processes from `.exs` source docs in
  the CRDT tree; bot-dispatcher is umbrella infra). Started under
  `Commonplace.Bots.Application`.

  ## Lifecycle

  Two INDEPENDENT concerns (C3d): a bot's autonomous heartbeat (its mind
  ticking) and chat-room subscription (reacting to messages). A bot's mind runs
  whether or not any chat surface has subscribed its rooms — the chatless demo
  is the honest architecture, "a mind running with its doors not yet installed".

    * `Dispatcher.register_autonomous_bot(name, dir_uuid, mud_root, cadence_ms)`
      — schedules room-independent heartbeat ticks and caches the bot's
      `home/agenda` uuid. `unregister_autonomous_bot/1` stops them.
    * `Dispatcher.subscribe_room(room_name, room_dir_uuid, messages_uuid)`
      — wires the chat plumbing only (NO heartbeat scheduling).

  Boot: subscribes to no rooms and registers no autonomous bots by default.

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

  alias Commonplace.Bots.{Activity, Entity, NoteDoc, RateLimit, Trigger}
  alias Commonplace.Bots.Identity, as: BotIdentity
  alias Commonplace.Chat.Messages
  alias Commonplace.Crypto.{NodeIdentity, Signing}
  alias Commonplace.MUD.{Citizenship, World}
  alias Commonplace.Presence
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.DocBuilder

  # The bot's home-agenda note dir carries this filename (C3d note-meta).
  @agenda_dir "agenda"
  @empty_entries ~s({"entries":[]})

  defstruct rooms: %{},
            store: CommitStoreClient,
            worker_hook: nil,
            rate_limit_enabled: true,
            auto: %{},
            node_ctx: nil

  @type room_info :: %{
          required(:dir_uuid) => String.t(),
          required(:messages_uuid) => String.t(),
          required(:activity_uuid) => String.t() | nil,
          required(:opts) => keyword()
        }

  # Per-autonomous-bot registration (keyed by the bot's stripped display name).
  # Independent of chat rooms (C3d design refinement): a bot's mind ticks
  # whether or not any chat surface has subscribed its rooms.
  @type auto_info :: %{
          required(:dir_uuid) => String.t(),
          required(:mud_root) => String.t(),
          required(:cadence) => pos_integer(),
          required(:ref) => reference() | nil,
          required(:home_agenda_uuid) => String.t() | nil,
          required(:opts) => keyword()
        }

  @type t :: %__MODULE__{
          rooms: %{String.t() => room_info()},
          store: module() | atom(),
          worker_hook: (String.t(), Entity.t(), map() -> any()),
          rate_limit_enabled: boolean(),
          auto: %{String.t() => auto_info()},
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

  cp-plan #8833 (the chat-path twin of CX-k87w): `opts` is ALSO reused
  as (most of) the CHAT `Worker.run/4` opts on every wake fired from
  THIS room — at minimum `:root_uuid` (the room's MUD root — WITHOUT
  it, `Commonplace.Bots.Worker.resolve_mud_context/4` falls back to
  `Workspace.root_uuid()`, the WRONG world, and every MUD tool the bot
  tries refuses) and `:cert_cids` (the citizenship set this room's
  writes are authorized under), plus test-only pass-through opts like
  `:client_fn` / `:secret_store`. Stored verbatim in
  `state.rooms[room_name][:opts]`; `invoke_worker_chat/4` merges it into
  the spawned Worker's opts with `:messages_uuid`/`:store` PINNED from
  registration state (never from the chat event map — the same
  registration-state-authoritative discipline `register_autonomous_bot/5`
  uses for `:root_uuid`/`:store` on the autonomous path). Omitting `opts`
  entirely (the 3-arity call) preserves prior behavior byte-for-byte —
  `root_uuid`/`cert_cids` simply don't get threaded, exactly as before
  this fix.
  """
  @spec subscribe_room(String.t(), String.t(), String.t(), keyword()) :: :ok
  def subscribe_room(room_name, room_dir_uuid, messages_uuid, opts \\ [])
      when is_binary(room_name) and is_binary(room_dir_uuid) and is_binary(messages_uuid) and
             is_list(opts) do
    GenServer.call(__MODULE__, {:subscribe_room, room_name, room_dir_uuid, messages_uuid, opts})
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

  @doc """
  Register a bot for AUTONOMOUS heartbeat ticks — a FIRST-CLASS entrypoint
  decoupled from any chat room (C3d design refinement). A bot's mind ticks
  whether or not a chat surface has subscribed its rooms; chat-room
  subscription (see `subscribe_room/3`) is a separate, later concern.

  Resolves the bot's `home/agenda` note-dir uuid ONCE here (via
  `Bots.Identity.resolve_signing_context` → `Citizenship.ensure` →
  `NoteDoc.ensure_zoned_dir`) and CACHES it, then schedules the periodic tick.
  Each tick beats the bot's presence and routes an internally-tagged heartbeat
  event through the same evaluate/dispatch path chat uses; the skip-check reads
  the agenda by the CACHED uuid (cheap), self-healing on a miss. `name` may be
  the suffixed (`"alice.bot"`) or stripped form. `opts` (e.g. `:secret_store`)
  are forwarded to identity resolution. If the home can't be resolved, the
  bot still ticks — the skip-check just self-heals or treats the agenda as
  empty. Re-registration cancels any prior timer first. Idempotent-ish.

  CX-k87w: `opts` is ALSO reused as (most of) the autonomous `Worker.run/4`
  opts on every fired tick — e.g. `:secret_store`, a test's `:client_fn` —
  with `:root_uuid` and `:store` pinned from THIS registration's `mud_root`
  and the dispatcher's own store (registration-state values, not caller
  overrides) so the Worker resolves its signing + MUD context under the
  registered `mud_root`, never the workspace root. See `invoke_worker/4`.

  ## Registration IS liveness (cp-plan #8915, `GhostReaper` P1)

  A registered autonomous bot's `.usr` presence is ALIVE by definition — its
  mind ticks whether or not anything else in the tree has touched it
  recently — but `Commonplace.MUD.GhostReaper` only ever knew about
  session-backed presences (`SessionLimit :live` ∪
  `Commonplace.MUD.PresenceRegistry`). At a long autonomous cadence (e.g.
  jes's live 3600s tick) against the reaper's much shorter default cadence
  (300s), a registered bot's `.usr` looked exactly like an abandoned ghost
  for most of every hour and was reaped out from under a still-registered
  mind — chat wakes then landed bodiless (`nil` mud_ctx: perception/
  scrollback degrade, every MUD tool refuses, the transcript goes unwritten).

  THE FIX: `register_autonomous_bot/5` registers the bot's own presence
  filename (`Commonplace.Presence.filename(name, :usr)`) into the SAME
  `Commonplace.MUD.PresenceRegistry` a live `PlayerSession` registers
  into — under THIS dispatcher process's own pid. `GhostReaper` already
  unions that registry into its live-set (see its moduledoc), so this
  needed NO reaper-side change at all: registering here is sufficient.
  `unregister_autonomous_bot/1` unregisters it explicitly; more importantly,
  because `Registry` entries are owned by the registering PROCESS and
  auto-removed the instant that process exits (crash, kill, clean stop —
  unlike a `terminate/2` callback, which a brutal kill skips entirely),
  the dispatcher process dying is BY ITSELF sufficient to drop every
  autonomous bot's registration-membership — "registration IS liveness"
  cuts both ways: no live dispatcher process, no claim of liveness.

  ## CX-5ikm (future boot-durable registration) — the constraint this fix
  ## must NOT be widened to break

  When autonomous registration becomes boot-durable (survives a dispatcher
  restart by being persisted to a doc, CX-5ikm), reaper-membership must
  continue to derive ONLY from the LIVE, re-registered-THIS-BOOT runtime
  state — i.e. still only from an actual `Registry.register/3` call made by
  a currently-running dispatcher process, same as today. A persisted
  registration DOC that has not yet been re-registered this boot (e.g. the
  node crashed and hasn't finished replaying its registrations yet) must
  NEVER count as alive on its own. The doc is a RESUME HINT for what to
  re-register, not a liveness fact in itself — treating it as one would let
  a dead node's stale doc claim a bot is alive forever, exactly the
  reap-nothing DoS `GhostReaper`'s fail-closed design already refuses to
  create in the other direction. Whoever builds CX-5ikm: re-register into
  `PresenceRegistry` on replay (this same call), don't add a second,
  doc-derived liveness path to the reaper.
  """
  @spec register_autonomous_bot(String.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          :ok
  def register_autonomous_bot(name, dir_uuid, mud_root, cadence_ms, opts \\ [])
      when is_binary(name) and is_binary(dir_uuid) and is_binary(mud_root) and
             is_integer(cadence_ms) and cadence_ms > 0 do
    GenServer.call(
      __MODULE__,
      {:register_autonomous_bot, strip_bot_suffix(name), dir_uuid, mud_root, cadence_ms, opts}
    )
  end

  @doc "Cancel a bot's autonomous ticks and drop its cached home-agenda uuid."
  @spec unregister_autonomous_bot(String.t()) :: :ok
  def unregister_autonomous_bot(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:unregister_autonomous_bot, strip_bot_suffix(name)})
  end

  @doc "Return the currently-registered autonomous bots (for inspection / tests)."
  def registered_autonomous_bots do
    GenServer.call(__MODULE__, :registered_autonomous_bots)
  end

  ## GenServer

  @impl true
  def init(opts) do
    state = %__MODULE__{
      rooms: %{},
      auto: %{},
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
  def handle_call({:subscribe_room, room, dir_uuid, messages_uuid, opts}, _from, state) do
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

    info = %{
      dir_uuid: dir_uuid,
      messages_uuid: messages_uuid,
      activity_uuid: activity_uuid,
      opts: opts
    }

    # CX-q8nk(3): seed RateLimit sliding-window counters from
    # recent bot posts in _messages so a dispatcher restart inside
    # a 60s window doesn't allow an extra burst before counters
    # converge. Concurrency counters stay at zero — no workers run
    # at boot. Skip silently when rate limits are disabled (tests).
    if state.rate_limit_enabled do
      seed_rate_limit(room, messages_uuid, state.store)
    end

    state = %{state | rooms: Map.put(state.rooms, room, info)}

    # C3d: heartbeat scheduling is NO LONGER coupled to chat-room subscription.
    # A bot's autonomous ticks are registered via `register_autonomous_bot/5`
    # (an independent entrypoint) so its mind runs with or without any chat
    # surface. subscribe_room now only wires the chat plumbing.
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unsubscribe_room, room}, _from, state) do
    if Map.has_key?(state.rooms, room) do
      Phoenix.PubSub.unsubscribe(Commonplace.PubSub, "magenta:chat:#{room}:events")
    end

    state = %{state | rooms: Map.delete(state.rooms, room)}

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:registered_rooms, _from, state) do
    {:reply, state.rooms, state}
  end

  @impl true
  def handle_call(:registered_autonomous_bots, _from, state) do
    {:reply, state.auto, state}
  end

  @impl true
  def handle_call(
        {:register_autonomous_bot, name, dir_uuid, mud_root, cadence, opts},
        _from,
        state
      ) do
    # Re-registration cancels any prior timer first.
    state = cancel_auto_timer(state, name)

    # cp-plan #8915: registration IS liveness — unregister-then-register is
    # idempotent (safe no-op unregister on a first-ever registration; a
    # RE-registration doesn't stack duplicate PresenceRegistry entries under
    # this dispatcher's own pid). See moduledoc "Registration IS liveness".
    unregister_autonomous_presence(name)
    register_autonomous_presence(name)

    # (C) cache-at-register: resolve the home-agenda uuid ONCE. Best-effort —
    # if unresolvable now, the tick's skip-check self-heals later.
    home_agenda_uuid = resolve_home_agenda(name, mud_root, state.store, opts)

    ref = Process.send_after(self(), {:autonomous_tick, name}, cadence)

    entry = %{
      dir_uuid: dir_uuid,
      mud_root: mud_root,
      cadence: cadence,
      ref: ref,
      home_agenda_uuid: home_agenda_uuid,
      opts: opts
    }

    {:reply, :ok, %{state | auto: Map.put(state.auto, name, entry)}}
  end

  @impl true
  def handle_call({:unregister_autonomous_bot, name}, _from, state) do
    state = cancel_auto_timer(state, name)
    unregister_autonomous_presence(name)
    {:reply, :ok, %{state | auto: Map.delete(state.auto, name)}}
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

  # C3d AUTONOMOUS heartbeat tick — room-independent. The `"kind" =>
  # "heartbeat"` tag is set HERE, internally, so this path is the ONLY way a
  # heartbeat event comes into being (unspoofable by chat). Ordering is
  # load-bearing: the bot's presence is beaten on EVERY tick, BEFORE the
  # skip/wake decision, so a resting (:skip) bot still stays alive for the
  # reaper.
  @impl true
  def handle_info({:autonomous_tick, name}, state) do
    case Map.get(state.auto, name) do
      %{dir_uuid: dir_uuid, mud_root: mud_root, cadence: cadence} ->
        # 1. ALWAYS beat presence first — a :skip tick still keeps the bot
        #    alive (skip = no LLM call, NEVER no keep-alive).
        beat_autonomous_presence(name, mud_root, state)

        # 2-3. Construct the internally-tagged heartbeat event (agenda read by
        #      the CACHED uuid, self-healing on a miss) and route it through the
        #      SAME evaluate_and_dispatch path chat uses.
        state = maybe_dispatch_autonomous(name, dir_uuid, state)

        # 4. Reschedule the next tick so the heartbeat is periodic.
        ref = Process.send_after(self(), {:autonomous_tick, name}, cadence)
        {:noreply, refresh_auto_ref(state, name, ref)}

      _ ->
        # Unregistered; a queued tick may still arrive. Drop it.
        {:noreply, state}
    end
  end

  # Build + dispatch the heartbeat event. Returns the (possibly self-healed)
  # state so the refreshed home-agenda cache survives to the next tick.
  defp maybe_dispatch_autonomous(name, dir_uuid, state) do
    case Entity.load(state.store, dir_uuid, name) do
      {:ok, entity} ->
        {agenda_empty, state} = autonomous_agenda_empty(name, state)

        # The "kind" is stamped HERE, internally — the unspoofable property.
        # No chat room, so the thread is trivially quiet.
        event = %{
          "verb" => "heartbeat",
          "kind" => "heartbeat",
          "room" => name,
          "agenda_empty" => agenda_empty,
          "thread_quiet" => true
        }

        evaluate_and_dispatch(name, entity, event, state)
        state

      _ ->
        state
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

    with text when is_binary(text) <-
           load_message_text(state.store, info.messages_uuid, message_id),
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

  # CX-k87w: the autonomous path must thread the REGISTERED mud_root (as
  # `:root_uuid`) + the registered `opts` into the Worker, not fall through to
  # the chat-room opts (which have no root at all and would leave the Worker
  # to default to the workspace root — the wrong world). Keyed off the
  # dispatcher-internal `"kind" => "heartbeat"` tag (unspoofable by chat, see
  # `handle_info({:autonomous_tick, ...})` above) AND the presence of a
  # matching `state.auto` entry for `room` (the autonomous path uses the
  # bot's stripped name as `room`). root_uuid/store come from the REGISTERED
  # entry — operator-provided server state set at `register_autonomous_bot/5`
  # — never from the event map, which is model/chat-adjacent data.
  defp invoke_worker(state, room, entity, %{"kind" => "heartbeat"} = event) do
    case Map.get(state.auto, room) do
      %{} = auto_entry ->
        opts =
          Keyword.merge(Map.get(auto_entry, :opts, []),
            root_uuid: Map.get(auto_entry, :mud_root),
            store: state.store
          )

        __MODULE__.spawn_worker(room, entity, event, opts)

      _ ->
        invoke_worker_chat(state, room, entity, event)
    end
  end

  defp invoke_worker(state, room, entity, event) do
    invoke_worker_chat(state, room, entity, event)
  end

  # cp-plan #8833 (chat-path twin of CX-k87w): thread the ROOM-REGISTERED
  # opts (`:root_uuid`, `:cert_cids`, test pass-throughs — see
  # `subscribe_room/4`'s @doc) into the Worker, with `:messages_uuid` and
  # `:store` PINNED from registration state (`Keyword.merge/2`,
  # registration wins over anything a stored `opts` might redundantly
  # carry) — NEVER read from `event` (chat/model-adjacent data, never a
  # trust boundary). A room registered via the old 3-arity `subscribe_room/3`
  # has `opts: []` here, so `root_uuid`/`cert_cids` are simply absent —
  # byte-identical to pre-fix behavior for that caller.
  defp invoke_worker_chat(state, room, entity, event) do
    info = Map.get(state.rooms, room, %{})
    messages_uuid = Map.get(info, :messages_uuid)
    room_opts = Map.get(info, :opts, [])

    opts = Keyword.merge(room_opts, messages_uuid: messages_uuid, store: state.store)

    __MODULE__.spawn_worker(room, entity, event, opts)
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
            |> Enum.map(fn e ->
              %{bot: bot_name(Map.get(e, "author_path", "")), ts: Map.get(e, "ts")}
            end)

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

  ## Autonomous heartbeat source (Camillo C3d)

  # Cancel a bot's autonomous timer (if any). Returns state unchanged except
  # the timer is dead; the caller drops/refreshes the auto entry.
  defp cancel_auto_timer(state, name) do
    case get_in(state.auto, [name, :ref]) do
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end

    state
  end

  defp refresh_auto_ref(state, name, ref) do
    case Map.get(state.auto, name) do
      %{} = entry -> %{state | auto: Map.put(state.auto, name, Map.put(entry, :ref, ref))}
      _ -> state
    end
  end

  # (C) resolve the bot's home-agenda note-dir uuid ONCE (at register /
  # self-heal). Best-effort — a nil here means the skip-check treats the agenda
  # as empty / self-heals next tick. Assembled ONLY from the resolved signing
  # context + Citizenship certs + the MUD root (the C1/C3a discipline).
  defp resolve_home_agenda(name, mud_root, store, opts) do
    try do
      with {:ok, sc} <- BotIdentity.resolve_signing_context(name, mud_root, store, opts),
           {:ok, %{home_room_uuid: home, cert_cids: cert_cids}} <-
             Citizenship.ensure(sc.identity_uuid, sc.public_key, name, mud_root, store) do
        ctx = %{
          store: store,
          home_room_uuid: home,
          signing_context: sc,
          cert_cids: cert_cids,
          signer_id: Signing.signer_id(sc.identity_uuid, sc.public_key)
        }

        case NoteDoc.ensure_zoned_dir(home, @agenda_dir, @empty_entries, ctx) do
          {:ok, uuid} -> uuid
          _ -> nil
        end
      else
        _ -> nil
      end
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  # The skip-check read: the agenda's `entries` by the CACHED uuid (cheap).
  # SELF-HEALING: a `:gone` on the cached uuid (rare re-provision) re-resolves
  # ONCE and refreshes the cache, then reads again. Returns {empty?, state}.
  defp autonomous_agenda_empty(name, state) do
    entry = Map.get(state.auto, name) || %{}

    case read_cached_agenda(Map.get(entry, :home_agenda_uuid), state.store) do
      {:ok, entries} ->
        {entries == [], state}

      :gone ->
        new_uuid =
          resolve_home_agenda(
            name,
            Map.get(entry, :mud_root),
            state.store,
            Map.get(entry, :opts, [])
          )

        state = %{
          state
          | auto: Map.put(state.auto, name, Map.put(entry, :home_agenda_uuid, new_uuid))
        }

        case read_cached_agenda(new_uuid, state.store) do
          {:ok, entries} -> {entries == [], state}
          :gone -> {true, state}
        end
    end
  end

  defp read_cached_agenda(uuid, store) when is_binary(uuid) do
    case World.get_meta_map(uuid, NoteDoc.note_filename(), store) do
      {:ok, %{"entries" => list}} when is_list(list) -> {:ok, list}
      {:ok, _} -> {:ok, []}
      _ -> :gone
    end
  rescue
    _ -> :gone
  catch
    _, _ -> :gone
  end

  defp read_cached_agenda(_uuid, _store), do: :gone

  # Beat the bot's `.usr` presence, best-effort, found via the MUD root (the
  # autonomous path has no room dir to scan). NEVER gates behavior — a failed
  # beat is observability noise.
  #
  # Attribution split (cp-plan #8716, the SIGNS binding = "sign what you did"):
  # the keep-alive beat is a RUNTIME FACT, not a Camillo turn — a `:skip` tick
  # performs no cognition — so it is NODE-signed. `state.node_ctx` is resolved
  # once at init; under enforce a node-signed presence write lands.
  defp beat_autonomous_presence(name, mud_root, state) when is_binary(mud_root) do
    fname = Presence.filename(name, :usr)

    try do
      case World.find_presence(mud_root, fname, state.store) do
        {:ok, _room_uuid, presence_uuid} ->
          Presence.heartbeat(presence_uuid, state.store, signing_context: state.node_ctx)
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

  defp beat_autonomous_presence(_name, _mud_root, _state), do: :ok

  # cp-plan #8915 — registration IS liveness. Register the bot's `.usr`
  # presence filename into the SAME `Commonplace.MUD.PresenceRegistry` a
  # live `PlayerSession` registers into (see `Commonplace.MUD.PlayerSession`
  # `init/1`), under THIS dispatcher process's own pid — `GhostReaper`
  # already unions that registry into its live-set, so no reaper-side
  # change was needed; registering here is sufficient (see moduledoc
  # "Registration IS liveness"). Guarded exactly like `PlayerSession`'s own
  # registration (a missing registry — e.g. a test that boots the
  # Dispatcher without the full app — never crashes registration) and
  # rescue/catch-wrapped so a Registry hiccup can never take a bot's
  # autonomous registration down.
  defp register_autonomous_presence(name) do
    fname = Presence.filename(name, :usr)

    if Process.whereis(Commonplace.MUD.PresenceRegistry) do
      Registry.register(Commonplace.MUD.PresenceRegistry, fname, nil)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # The mirror unregister — called explicitly on `unregister_autonomous_bot/1`
  # (re-registration also calls this first, so it never stacks duplicate
  # entries for the same name under this dispatcher's pid). Process DEATH
  # drops every registration automatically (Registry's own guarantee, not
  # this function) — see moduledoc "Registration IS liveness" for why that
  # or-death path is the one that actually matters for the invariant.
  defp unregister_autonomous_presence(name) do
    fname = Presence.filename(name, :usr)

    if Process.whereis(Commonplace.MUD.PresenceRegistry) do
      Registry.unregister(Commonplace.MUD.PresenceRegistry, fname)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
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
