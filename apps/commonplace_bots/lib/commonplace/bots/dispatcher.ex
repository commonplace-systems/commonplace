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

  alias Commonplace.Bots.{Activity, Entity, RateLimit, Trigger}
  alias Commonplace.Chat.Messages
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.DocBuilder

  defstruct rooms: %{}, store: CommitStoreClient, worker_hook: nil, rate_limit_enabled: true

  @type room_info :: %{
          required(:dir_uuid) => String.t(),
          required(:messages_uuid) => String.t(),
          required(:activity_uuid) => String.t() | nil
        }

  @type t :: %__MODULE__{
          rooms: %{String.t() => room_info()},
          store: module() | atom(),
          worker_hook: (String.t(), Entity.t(), map() -> any()),
          rate_limit_enabled: boolean()
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
      rate_limit_enabled: Keyword.get(opts, :rate_limit_enabled, true)
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

    {:reply, :ok, %{state | rooms: Map.put(state.rooms, room, info)}}
  end

  @impl true
  def handle_call({:unsubscribe_room, room}, _from, state) do
    if Map.has_key?(state.rooms, room) do
      Phoenix.PubSub.unsubscribe(Commonplace.PubSub, "magenta:chat:#{room}:events")
    end

    {:reply, :ok, %{state | rooms: Map.delete(state.rooms, room)}}
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
