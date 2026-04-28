defmodule Commonplace.MUD.MoveServer do
  @moduledoc """
  Singleton GenServer that serializes cross-doc moves for the MUD.

  v0 stand-in for the green channel: read-current-parent →
  check-still-there → reparent. Loser of a race gets `{:error, :gone}`.

  Ordering: dest-add FIRST, then source-remove. If we crash between
  the two writes the entry exists in both rooms (recoverable: reaper /
  manual scrub), rather than nowhere (silently lost). See spec §2.4.

  Registered globally as `{:global, __MODULE__}` so every node in the
  cluster sees the same singleton.
  """

  use GenServer

  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Commonplace.MUD.Schemas, as: MudSchemas
  alias Yelixer.Encoding

  @global_name {:global, __MODULE__}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @global_name)
    store = Keyword.get(opts, :store, CommitStoreClient)

    case GenServer.start_link(__MODULE__, store, name: name) do
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

  @doc """
  Move `thing_uuid` (entry named `name`) from `source_dir_uuid` to
  `dest_dir_uuid`. Returns `:ok` on success, `{:error, :gone}` if the
  entry isn't where we think it is at call time, `{:error, reason}`
  otherwise.
  """
  def move(thing_uuid, name, source_dir_uuid, dest_dir_uuid, server \\ @global_name) do
    GenServer.call(server, {:move, thing_uuid, name, source_dir_uuid, dest_dir_uuid}, 10_000)
  end

  ## Server callbacks

  @impl true
  def init(store), do: {:ok, %{store: store}}

  @impl true
  def handle_call({:move, thing_uuid, name, source_dir_uuid, dest_dir_uuid}, _from, %{store: store} = state) do
    result = do_move(thing_uuid, name, source_dir_uuid, dest_dir_uuid, store)
    {:reply, result, state}
  end

  defp do_move(_thing_uuid, _name, source, dest, _store) when source == dest, do: :ok

  defp do_move(thing_uuid, name, source_dir_uuid, dest_dir_uuid, store) do
    with {:ok, source_schema} <- MudSchemas.load_dir_schema(source_dir_uuid, store),
         {:ok, %Schema.Entry{} = entry} <- check_still_there(source_schema, name, thing_uuid),
         {:ok, dest_schema} <- MudSchemas.load_dir_schema(dest_dir_uuid, store),
         :ok <- check_no_collision(dest_schema, name) do
      :ok = add_to_dest(dest_dir_uuid, name, entry, store)
      :ok = remove_from_source(source_dir_uuid, name, store)
      :ok
    else
      {:error, _} = err -> err
      :error -> {:error, :gone}
      :none -> {:error, :gone}
    end
  end

  defp check_still_there(schema, name, thing_uuid) do
    case Schema.get_entry(schema, name) do
      {:ok, %Schema.Entry{node_id: ^thing_uuid} = entry} -> {:ok, entry}
      {:ok, %Schema.Entry{}} -> {:error, :gone}
      :error -> {:error, :gone}
    end
  end

  defp check_no_collision(schema, name) do
    case Schema.get_entry(schema, name) do
      :error -> :ok
      {:ok, _} -> {:error, :collision}
    end
  end

  defp add_to_dest(dest_dir_uuid, name, %Schema.Entry{type: type, node_id: node_id}, store) do
    {:ok, doc} = MudSchemas.load_dir_schema(dest_dir_uuid, store)

    doc =
      case type do
        :dir -> Schema.add_directory(doc, name, node_id)
        _ -> Schema.add_file(doc, name, node_id)
      end

    update = Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(store, dest_dir_uuid, update)
    :ok
  end

  defp remove_from_source(source_dir_uuid, name, store) do
    {:ok, doc} = MudSchemas.load_dir_schema(source_dir_uuid, store)
    doc = Schema.remove_entry(doc, name)
    update = Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(store, source_dir_uuid, update)
    :ok
  end
end
