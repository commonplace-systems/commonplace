defmodule Yelixer.DocServer do
  @moduledoc """
  GenServer wrapper around a Yelixer Doc for concurrent access.
  Supports subscribing to updates for sync.
  """
  use GenServer

  alias Yelixer.{Doc, Types.Text, Encoding, BlockStore, StateVector}

  # Client API

  def start_link(opts \\ []) do
    {gen_opts, doc_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, doc_opts, gen_opts)
  end

  def insert_text(server, type_name, index, text) do
    GenServer.call(server, {:insert_text, type_name, index, text})
  end

  def delete_text(server, type_name, index, len) do
    GenServer.call(server, {:delete_text, type_name, index, len})
  end

  def get_text(server, type_name) do
    GenServer.call(server, {:get_text, type_name})
  end

  def encode_update(server) do
    GenServer.call(server, :encode_update)
  end

  def encode_diff(server, %StateVector{} = remote_sv) do
    GenServer.call(server, {:encode_diff, remote_sv})
  end

  def apply_update(server, update) when is_binary(update) do
    GenServer.call(server, {:apply_update, update})
  end

  def state_vector(server) do
    GenServer.call(server, :state_vector)
  end

  def subscribe(server) do
    GenServer.call(server, {:subscribe, self()})
  end

  def unsubscribe(server) do
    GenServer.call(server, {:unsubscribe, self()})
  end

  # Server callbacks

  @impl true
  def init(opts) do
    client_id = Keyword.get(opts, :client_id, :rand.uniform(1_000_000_000))
    doc = Doc.new(client_id: client_id)
    {:ok, %{doc: doc, subscribers: MapSet.new()}}
  end

  @impl true
  def handle_call({:insert_text, type_name, index, text}, _from, state) do
    {doc, _} = Doc.get_or_create_type(state.doc, type_name, :text)
    sv_before = BlockStore.state_vector(doc.store)
    doc = Text.insert(doc, type_name, index, text)
    state = %{state | doc: doc}
    broadcast_diff(state, sv_before)
    {:reply, :ok, state}
  end

  def handle_call({:delete_text, type_name, index, len}, _from, state) do
    {doc, _} = Doc.get_or_create_type(state.doc, type_name, :text)
    sv_before = BlockStore.state_vector(doc.store)
    doc = Text.delete(doc, type_name, index, len)
    state = %{state | doc: doc}
    broadcast_diff(state, sv_before)
    {:reply, :ok, state}
  end

  def handle_call({:get_text, type_name}, _from, state) do
    {doc, _} = Doc.get_or_create_type(state.doc, type_name, :text)
    text = Text.to_string(doc, type_name)
    {:reply, text, %{state | doc: doc}}
  end

  def handle_call(:encode_update, _from, state) do
    update = Encoding.encode_update(state.doc)
    {:reply, update, state}
  end

  def handle_call({:encode_diff, remote_sv}, _from, state) do
    diff = Encoding.encode_diff(state.doc, remote_sv)
    {:reply, diff, state}
  end

  def handle_call({:apply_update, update}, _from, state) do
    {:ok, doc} = Encoding.apply_update(state.doc, update)
    {:reply, :ok, %{state | doc: doc}}
  end

  def handle_call(:state_vector, _from, state) do
    sv = BlockStore.state_vector(state.doc.store)
    {:reply, sv, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  defp broadcast_diff(state, sv_before) do
    if MapSet.size(state.subscribers) > 0 do
      diff = Encoding.encode_diff(state.doc, sv_before)

      Enum.each(state.subscribers, fn pid ->
        send(pid, {:yelixer_update, diff})
      end)
    end
  end
end
