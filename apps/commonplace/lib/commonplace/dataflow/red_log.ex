defmodule Commonplace.Dataflow.RedLog do
  @moduledoc """
  Persistent red event log — a YArray document that accumulates events.

  The magenta→red onramp subscribes to a magenta topic and appends
  received messages to a YArray, giving persistent auditable history
  of ephemeral commands.
  """

  use GenServer

  alias Commonplace.Dataflow.Magenta
  alias Commonplace.Store.CommitStore

  defstruct [:uuid, :doc, :store]

  @log_type "events"

  @doc "Create a new empty red log."
  def new(uuid, store \\ CommitStore) do
    doc = Yelixer.Doc.new()
    {doc, _} = Yelixer.Doc.get_or_create_type(doc, @log_type, :array)
    %__MODULE__{uuid: uuid, doc: doc, store: store}
  end

  @doc "Load an existing red log from the commit store."
  def load(uuid, store \\ CommitStore) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Yelixer.Doc.new()
        {doc, _} = Yelixer.Doc.get_or_create_type(doc, @log_type, :array)
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        %__MODULE__{uuid: uuid, doc: doc, store: store}

      :none ->
        new(uuid, store)
    end
  end

  @doc "Append a magenta message to the log."
  def append(%__MODULE__{} = log, %Magenta{} = msg) do
    event = Jason.encode!(Magenta.to_map(msg))
    doc = Yelixer.Types.Array.push(log.doc, @log_type, [event])
    %{log | doc: doc}
  end

  @doc "Read all events from the log."
  def read(%__MODULE__{} = log) do
    log.doc
    |> Yelixer.Types.Array.to_list(@log_type)
    |> Enum.map(fn event ->
      case Jason.decode(event) do
        {:ok, decoded} -> decoded
        _ -> %{"raw" => event}
      end
    end)
  end

  @doc "Commit the current log state to the store."
  def commit(%__MODULE__{} = log) do
    update = Yelixer.Encoding.encode_update(log.doc)
    CommitStore.create_commit(log.store, log.uuid, update, nil)
    log
  end

  # --- Onramp GenServer ---

  @doc "Start a magenta→red onramp process that subscribes and persists."
  def start_onramp(log_uuid, magenta_topic, store \\ CommitStore) do
    GenServer.start_link(__MODULE__, %{
      uuid: log_uuid,
      topic: magenta_topic,
      store: store
    })
  end

  @doc "Tell the onramp to commit its current state."
  def commit_onramp(pid) do
    GenServer.call(pid, :commit)
  end

  @impl true
  def init(%{uuid: uuid, topic: topic, store: store}) do
    Magenta.subscribe(topic)
    log = load(uuid, store)
    {:ok, %{log: log, topic: topic}}
  end

  @impl true
  def handle_info({:magenta, _path, %Magenta{} = msg}, state) do
    log = append(state.log, msg)
    {:noreply, %{state | log: log}}
  end

  @impl true
  def handle_call(:commit, _from, state) do
    log = commit(state.log)
    {:reply, :ok, %{state | log: log}}
  end
end
