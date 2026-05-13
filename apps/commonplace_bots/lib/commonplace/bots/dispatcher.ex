defmodule Commonplace.Bots.Dispatcher do
  @moduledoc """
  Singleton GenServer that watches chat events and wakes bots.

  Sibling to `Commonplace.Sync.Agent`. **Not** orchestrator-managed
  (the orchestrator compiles processes from `.exs` source docs in
  the CRDT tree; bot-dispatcher is umbrella infra). Started under
  `Commonplace.Bots.Application` from phase 3 onward.

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
    3. For each entity, loads it via `Entity.load/3` and calls
       `Trigger.evaluate/3` with the enriched event.
    4. On `:wake`, hands off to `:worker_hook` (default
       `Bots.Worker.spawn/3` — phase 4 wires the real worker;
       phase 3 ships a logging stub so the subscription pipeline
       is testable on its own).

  Bot→bot loop prevention is enforced at step 1: events whose
  `author_path` ends in `.bot` are dropped before bot enumeration.
  This is the loop-prevention contract agreed with commonplace-plan
  ("controlled by rate limits, not by bots-ignore-bots" — except
  for the strict no-bot-replies-to-bot edge, which is here).

  ## v0 scope

  Phase 3 (this commit) wires the subscription + trigger eval
  pipeline with a logging worker hook. Phase 4 swaps the hook for
  the real cave-diver worker. Phase 6 adds:

    * RAM rate-limit counter (per-room sliding window + per-bot
      cooldown + concurrency caps)
    * `__bot_activity` substrate-doc emission for trigger
      decisions
    * `.exe` presence flicker during worker lifetime
  """

  use GenServer
  require Logger

  alias Commonplace.Bots.{Entity, Trigger}
  alias Commonplace.Chat.Messages
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.DocBuilder

  defstruct rooms: %{}, store: CommitStoreClient, worker_hook: nil

  @type room_info :: %{
          required(:dir_uuid) => String.t(),
          required(:messages_uuid) => String.t()
        }

  @type t :: %__MODULE__{
          rooms: %{String.t() => room_info()},
          store: module() | atom(),
          worker_hook: (String.t(), Entity.t(), map() -> any())
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
      worker_hook: Keyword.get(opts, :worker_hook, &__MODULE__.log_wake/3)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe_room, room, dir_uuid, messages_uuid}, _from, state) do
    case Map.get(state.rooms, room) do
      nil ->
        Phoenix.PubSub.subscribe(Commonplace.PubSub, "magenta:chat:#{room}:events")

      _existing ->
        :ok
    end

    info = %{dir_uuid: dir_uuid, messages_uuid: messages_uuid}
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
        :telemetry.execute(
          [:commonplace, :bots, :dispatcher, :trigger_fired],
          %{system_time: System.system_time()},
          %{room: room, bot: entity.name}
        )

        state.worker_hook.(room, entity, event)
    end
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

  @doc false
  def log_wake(room, entity, event) do
    Logger.info(
      "[bots.dispatcher] wake bot=#{entity.name} room=#{room} msg=#{Map.get(event, "message_id")}"
    )

    :ok
  end
end
