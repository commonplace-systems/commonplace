defmodule Commonplace.Document.Server do
  @moduledoc """
  GenServer managing a single CRDT document.

  Wraps a Yelixer.Doc, handles edits, publishes changes
  to PubSub, and commits state to the CommitStore.
  """

  use GenServer

  alias Commonplace.Store.CommitStore
  alias Commonplace.Dataflow.PubSub, as: CPPubSub

  defstruct [:uuid, :doc, :parent_commit]

  def start_link(opts) do
    uuid = Keyword.fetch!(opts, :uuid)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Commonplace.Document.Registry, uuid}}
    )
  end

  def get_doc(pid), do: GenServer.call(pid, :get_doc)

  def apply_update(pid, update), do: GenServer.call(pid, {:apply_update, update})

  def commit(pid), do: GenServer.call(pid, :commit)

  @impl true
  def init(opts) do
    uuid = Keyword.fetch!(opts, :uuid)
    client_id = Keyword.get(opts, :client_id, :rand.uniform(1_000_000_000))

    {doc, parent_commit} =
      case CommitStore.latest_commit(uuid) do
        {:ok, commit} ->
          doc = Yelixer.Doc.new(client_id: client_id)
          {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
          {doc, commit.id}

        :none ->
          {Yelixer.Doc.new(client_id: client_id), nil}
      end

    {:ok, %__MODULE__{uuid: uuid, doc: doc, parent_commit: parent_commit}}
  end

  @impl true
  def handle_call(:get_doc, _from, state) do
    {:reply, state.doc, state}
  end

  @impl true
  def handle_call({:apply_update, update}, _from, state) do
    case Yelixer.Encoding.apply_update(state.doc, update) do
      {:ok, doc} ->
        CPPubSub.broadcast_blue(state.uuid, update)
        {:reply, :ok, %{state | doc: doc}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:commit, _from, state) do
    update = Yelixer.Encoding.encode_update(state.doc)
    commit = CommitStore.create_commit(state.uuid, update, state.parent_commit)
    {:reply, {:ok, commit}, %{state | parent_commit: commit.id}}
  end
end
