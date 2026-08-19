defmodule Commonplace.Chat.OnrampSupervisor do
  @moduledoc """
  CX-9zpb (R1 of CX-p2qp): per-room red-onramp supervision.

  A `DynamicSupervisor` that owns one `Commonplace.Dataflow.RedLog`
  magenta→red onramp process per chat room. Each onramp subscribes to
  `chat:{room}:events` magenta and appends every received message to
  the room's `_messages.log` red doc. RedLog handles its own commit
  debounce (250ms) so bursts of post/edit/delete activity coalesce into
  one chained commit.

  ## Lifecycle: lazy

  Per the discussion in commonplace-plan msg #3042, MVP uses lazy
  onramp-start: rooms get an onramp on FIRST activity (the first
  post/edit/delete action), not eagerly. `Commonplace.Chat.Actions`
  calls `ensure_started/3` from its shared `commit_entry` helper, so
  all three action verbs trigger onramp-start uniformly.

  ## Idempotence

  `ensure_started/3` is the only public entry point besides `stop/1`.
  Concurrent first-actions for the same room dedup safely — second
  caller sees the existing entry in the room→pid table and returns the
  same pid.

  Production deployments may want eager onramp-start (a `/chat/*`
  schema watcher) to catch rooms created and never posted-into; that's
  a substrate enhancement filed when a use case demands it.
  """

  use DynamicSupervisor

  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Store.CommitStoreClient

  @table :chat_onramp_room_index

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    ensure_room_index_table()
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Ensure a magenta→red onramp is running for `room` writing to
  `log_uuid`. If one exists for `room`, return its pid; else start a
  new one under the supervisor and track it.

  Idempotent. Safe to call from action handlers' hot paths.

  Optional opts:
    * `:store` — CommitStore name to write the red log to (defaults to
      `CommitStoreClient`)
  """
  def ensure_started(room, log_uuid, opts \\ [])
      when is_binary(room) and is_binary(log_uuid) and is_list(opts) do
    ensure_room_index_table()

    case lookup_pid(room) do
      {:ok, pid} ->
        {:ok, pid}

      :none ->
        store = Keyword.get(opts, :store, CommitStoreClient)
        topic = "chat:#{room}:events"

        case DynamicSupervisor.start_child(__MODULE__, %{
               id: {:onramp, room},
               start: {RedLog, :start_onramp, [log_uuid, topic, store]},
               restart: :temporary
             }) do
          {:ok, pid} ->
            register_room_pid(room, pid)
            {:ok, pid}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Stop the onramp for `room`. No-op if no onramp is running for that
  room. Used for room-teardown flows and tests.
  """
  def stop(room) when is_binary(room) do
    ensure_room_index_table()

    case lookup_pid(room) do
      {:ok, pid} ->
        unregister_room(room)
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        :ok

      :none ->
        :ok
    end
  end

  @doc """
  Test helper: stop all running onramps and clear the room→pid table.
  Leaves the supervisor process itself alive (so the production
  Application supervisor tree stays intact). Each test calls this in
  setup to start from a known-empty state.
  """
  def reset do
    ensure_room_index_table()

    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      _pid ->
        for {_id, child_pid, _type, _modules} <- DynamicSupervisor.which_children(__MODULE__),
            is_pid(child_pid) do
          DynamicSupervisor.terminate_child(__MODULE__, child_pid)
        end
    end

    :ets.delete_all_objects(@table)
    :ok
  end

  # --- Private ---

  defp ensure_room_index_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _tid ->
        @table
    end
  end

  defp lookup_pid(room) do
    case :ets.lookup(@table, room) do
      [{^room, pid}] ->
        if Process.alive?(pid),
          do: {:ok, pid},
          else:
            (
              unregister_room(room)
              :none
            )

      [] ->
        :none
    end
  end

  defp register_room_pid(room, pid) do
    :ets.insert(@table, {room, pid})
    :ok
  end

  defp unregister_room(room) do
    :ets.delete(@table, room)
    :ok
  end
end
