defmodule Commonplace.Dataflow.RedLog do
  @moduledoc """
  Persistent red event log — a YArray document that accumulates events.

  The magenta→red onramp subscribes to a magenta topic and appends
  received messages to a YArray, giving persistent auditable history
  of ephemeral commands.
  """

  use GenServer

  alias Commonplace.Dataflow.Magenta
  alias Commonplace.Store.CommitStoreClient

  defstruct [:uuid, :doc, :store]

  @log_type "events"

  @doc "Create a new empty red log."
  def new(uuid, store \\ CommitStoreClient) do
    doc = Yelixer.Doc.new(client_id: stable_client_id(uuid))
    {doc, _} = Yelixer.Doc.get_or_create_type(doc, @log_type, :array)
    %__MODULE__{uuid: uuid, doc: doc, store: store}
  end

  @doc "Load an existing red log from the commit store."
  def load(uuid, store \\ CommitStoreClient) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Yelixer.Doc.new(client_id: stable_client_id(uuid))
        {doc, _} = Yelixer.Doc.get_or_create_type(doc, @log_type, :array)
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        %__MODULE__{uuid: uuid, doc: doc, store: store}

      :none ->
        new(uuid, store)
    end
  end

  # CX-pyi: derive a stable client_id from the log uuid so repeated
  # load → append → commit cycles share one slot in the state vector.
  # Same pattern CX-6g6 used for Presence/Identity. Without this, every
  # cycle minted a fresh random client_id and persisted it via
  # encode_update, accumulating one entry per write.
  defp stable_client_id(uuid) when is_binary(uuid) do
    :erlang.phash2(uuid, 0xFFFF_FFFF)
  end

  @doc "Append a magenta message to the log."
  def append(%__MODULE__{} = log, %Magenta{} = msg) do
    event = Jason.encode!(Magenta.to_map(msg))
    doc = Yelixer.Types.Array.push(log.doc, @log_type, [event])
    %{log | doc: doc}
  end

  @doc "Append a raw event map to the log (JSON-encoded)."
  def append_raw(%__MODULE__{} = log, %{} = event_map) do
    event = Jason.encode!(event_map)
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

  @doc "Commit the current log state to the store, with optional gold attestation."
  def commit(%__MODULE__{} = log) do
    update = Yelixer.Encoding.encode_update(log.doc)
    CommitStoreClient.create_chained_commit(log.store, log.uuid, update)

    # Gold attestation: create tamper-evident chain entry
    maybe_attest(log.uuid, log.store)

    log
  end

  defp maybe_attest(uuid, store) do
    case Commonplace.Gold.Chain.attest(uuid, store) do
      {:ok, _att} -> :ok
      {:error, _} -> :ok
    end
  end

  # --- Onramp GenServer ---

  @doc "Start a magenta→red onramp process that subscribes and persists."
  def start_onramp(log_uuid, magenta_topic, store \\ CommitStoreClient) do
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
