defmodule Commonplace.Document.Server do
  @moduledoc """
  GenServer managing a single CRDT document.

  Wraps a Yelixer.Doc, handles edits, publishes changes
  to PubSub, and commits state to the CommitStoreClient.
  """

  use GenServer

  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Document.ContentType
  alias Commonplace.Dataflow.PubSub, as: CPPubSub

  defstruct [:uuid, :doc, :parent_commit, :commit_store]

  def start_link(opts) do
    uuid = Keyword.fetch!(opts, :uuid)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Commonplace.Document.Registry, uuid}}
    )
  end

  def get_doc(pid), do: GenServer.call(pid, :get_doc)

  def apply_update(pid, update), do: GenServer.call(pid, {:apply_update, update})

  def commit(pid), do: GenServer.call(pid, :commit)

  @doc "Initialize the document envelope with a content type and name."
  def create(pid, type, name), do: GenServer.call(pid, {:create, type, name})

  @doc "Insert text at an index (for text documents)."
  def insert_text(pid, index, text), do: GenServer.call(pid, {:insert_text, index, text})

  @doc "Set a key in the content map (for map documents)."
  def set_key(pid, key, value), do: GenServer.call(pid, {:set_key, key, value})

  @doc "Get the current content value."
  def get_content(pid), do: GenServer.call(pid, :get_content)

  @doc "Get the content type atom (:text, :map, :array, :xml)."
  def get_content_type(pid), do: GenServer.call(pid, :get_content_type)

  @doc "Get a metadata value from the envelope."
  def get_meta(pid, key), do: GenServer.call(pid, {:get_meta, key})

  @impl true
  def init(opts) do
    uuid = Keyword.fetch!(opts, :uuid)
    client_id = Keyword.get(opts, :client_id, :rand.uniform(1_000_000_000))
    commit_store = Keyword.get(opts, :commit_store, CommitStoreClient)

    {doc, parent_commit} =
      case CommitStoreClient.latest_commit(commit_store, uuid) do
        {:ok, commit} ->
          doc = Yelixer.Doc.new(client_id: client_id)
          {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
          {doc, commit.id}

        :none ->
          {Yelixer.Doc.new(client_id: client_id), nil}
      end

    {:ok,
     %__MODULE__{uuid: uuid, doc: doc, parent_commit: parent_commit, commit_store: commit_store}}
  end

  @impl true
  def handle_call(:get_doc, _from, state) do
    {:reply, state.doc, state}
  end

  @impl true
  def handle_call({:apply_update, update}, _from, state) do
    {:ok, doc} = Yelixer.Encoding.apply_update(state.doc, update)
    CPPubSub.broadcast_blue(state.uuid, update)
    {:reply, :ok, %{state | doc: doc}}
  end

  @impl true
  def handle_call(:commit, _from, state) do
    update = Yelixer.Encoding.encode_update(state.doc)

    commit =
      CommitStoreClient.create_commit(state.commit_store, state.uuid, update, state.parent_commit)

    {:reply, {:ok, commit}, %{state | parent_commit: commit.id}}
  end

  @impl true
  def handle_call({:create, type, name}, _from, state) do
    doc = ContentType.create(state.doc, type, name)
    {:reply, :ok, %{state | doc: doc}}
  end

  @impl true
  def handle_call({:insert_text, index, text}, _from, state) do
    doc = ContentType.insert_text(state.doc, index, text)
    {:reply, :ok, %{state | doc: doc}}
  end

  @impl true
  def handle_call({:set_key, key, value}, _from, state) do
    doc = ContentType.set_key(state.doc, key, value)
    {:reply, :ok, %{state | doc: doc}}
  end

  @impl true
  def handle_call(:get_content, _from, state) do
    {:reply, ContentType.get_content(state.doc), state}
  end

  @impl true
  def handle_call(:get_content_type, _from, state) do
    {:reply, ContentType.get_type(state.doc), state}
  end

  @impl true
  def handle_call({:get_meta, key}, _from, state) do
    {:reply, ContentType.get_meta(state.doc, key), state}
  end
end
