defmodule Commonplace.MUD.TickBot do
  @moduledoc """
  Singleton tick scheduler for the MUD (P2 of CX-v55j).

  Wakes every `heartbeat_ms` (default 1000), walks the world tree from
  the configured root, and fires per-doc tick handlers for any doc
  whose `tick_interval_ms` has elapsed since its last firing.

  v0 scope (per spec §4): in-memory `last_tick` per doc UUID; if a tick
  overruns the heartbeat we drop the next firing rather than queue.
  Expects dozens of tickers, not thousands.

  Tick handler for v0 is a built-in: if the doc has a `tick_message`
  field, broadcast `%{kind: :custom, text: tick_message}` as a red
  event to the containing room. Rooms broadcast to themselves; objects
  broadcast to their parent room. User-authored `tick.elx` verbs are
  P3 (hot-reloaded via `Commonplace.Code.SourceDoc.compile/2`).

  Globally registered as `{:global, __MODULE__}` so a clustered MUD
  has exactly one ticker.
  """

  use GenServer
  require Logger

  alias Commonplace.MUD.{Schemas, VerbSource, World}
  alias Commonplace.MUD.Schemas.{Object, Room}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema

  @global_name {:global, __MODULE__}
  @default_heartbeat_ms 1000

  defstruct [
    :root_uuid,
    :store,
    :heartbeat_ms,
    :last_tick
  ]

  ## Client

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @global_name)

    case GenServer.start_link(__MODULE__, opts, name: name) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient
    }
  end

  @doc "Force an immediate tick scan (for tests). Synchronous."
  def tick_now(server \\ @global_name), do: GenServer.call(server, :tick_now, 10_000)

  ## Server

  @impl true
  def init(opts) do
    state = %__MODULE__{
      root_uuid: Keyword.get(opts, :root_uuid),
      store: Keyword.get(opts, :store, CommitStoreClient),
      heartbeat_ms: Keyword.get(opts, :heartbeat_ms, @default_heartbeat_ms),
      last_tick: %{}
    }

    if Keyword.get(opts, :auto_start, true) do
      schedule_tick(state.heartbeat_ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    new_state = run_tick(state)
    schedule_tick(state.heartbeat_ms)
    {:noreply, new_state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_call(:tick_now, _from, state) do
    new_state = run_tick(state)
    {:reply, :ok, new_state}
  end

  defp schedule_tick(ms), do: Process.send_after(self(), :tick, ms)

  defp run_tick(%__MODULE__{root_uuid: nil} = state) do
    case Commonplace.Workspace.root_uuid() do
      {:ok, uuid} -> run_tick(%{state | root_uuid: uuid})
      _ -> state
    end
  end

  defp run_tick(%__MODULE__{} = state) do
    now = System.monotonic_time(:millisecond)
    tickers = collect_tickers(state.root_uuid, state.store)

    new_last_tick =
      Enum.reduce(tickers, state.last_tick, fn ticker, acc ->
        case Map.get(acc, ticker.uuid) do
          nil ->
            fire(ticker, state.store)
            Map.put(acc, ticker.uuid, now)

          last when now - last >= ticker.interval_ms ->
            fire(ticker, state.store)
            Map.put(acc, ticker.uuid, now)

          _ ->
            acc
        end
      end)

    %{state | last_tick: new_last_tick}
  end

  defp fire(%{uuid: host_uuid, room_uuid: room_uuid, message: msg}, store) do
    ctx = %{current_room_uuid: room_uuid, store: store, host_uuid: host_uuid}

    case VerbSource.run_verb(host_uuid, "tick", ctx, store) do
      {:ok, _} ->
        :ok

      :not_found ->
        if msg, do: World.broadcast_room(room_uuid, %{kind: :custom, text: msg})
        :ok

      {:error, {:runtime_error, reason}} ->
        World.broadcast_room(room_uuid, %{kind: :verb_error, verb: "tick", reason: reason})
        :ok

      {:error, {:compile_error, reason}} ->
        World.broadcast_room(room_uuid, %{kind: :verb_error, verb: "tick", reason: reason})
        :ok

      _ ->
        if msg, do: World.broadcast_room(room_uuid, %{kind: :custom, text: msg})
        :ok
    end
  rescue
    e ->
      Logger.warning("TickBot fire crashed: #{Exception.message(e)}")
      :ok
  end

  ## Tree walk: collect ticking docs

  defp collect_tickers(root_uuid, store) do
    case Schemas.load_dir_schema(root_uuid, store) do
      {:ok, root_schema} ->
        Schema.list_entries(root_schema)
        |> Enum.filter(&(&1.type == :dir))
        |> Enum.flat_map(fn entry -> collect_room_tickers(entry, store) end)

      _ ->
        []
    end
  end

  defp collect_room_tickers(%Schema.Entry{node_id: room_dir_uuid, name: room_name}, store) do
    case Schemas.load_dir_schema(room_dir_uuid, store) do
      {:ok, schema} ->
        room_meta = load_room_meta(room_dir_uuid, store)

        room_ticker =
          if room_meta && room_meta.tick_interval_ms do
            [
              %{
                uuid: room_dir_uuid,
                interval_ms: room_meta.tick_interval_ms,
                message: room_meta.tick_message,
                room_uuid: room_dir_uuid,
                kind: :room,
                name: room_name
              }
            ]
          else
            []
          end

        object_tickers =
          Schema.list_entries(schema)
          |> Enum.filter(fn e -> e.type == :dir and String.ends_with?(e.name, ".obj") end)
          |> Enum.flat_map(fn obj_entry ->
            case Schemas.load_object(obj_entry.node_id, store) do
              {:ok, %Object{tick_interval_ms: ms, tick_message: msg}} when not is_nil(ms) ->
                [
                  %{
                    uuid: obj_entry.node_id,
                    interval_ms: ms,
                    message: msg,
                    room_uuid: room_dir_uuid,
                    kind: :object,
                    name: obj_entry.name
                  }
                ]

              _ ->
                []
            end
          end)

        room_ticker ++ object_tickers

      _ ->
        []
    end
  end

  defp load_room_meta(uuid, store) do
    case Schemas.load_room(uuid, store) do
      {:ok, %Room{} = r} -> r
      _ -> nil
    end
  end
end
