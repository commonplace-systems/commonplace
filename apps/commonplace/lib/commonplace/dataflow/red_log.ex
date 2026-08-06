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

  @type t :: %__MODULE__{uuid: String.t(), doc: term(), store: GenServer.server()}

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

  @doc """
  Commit the current log state to the store, with optional gold attestation.

  `opts` are forwarded verbatim to
  `CommitStoreClient.create_chained_commit/5` — notably
  `:signing_context` (CX-t3xv). A red log whose writer has no ambient
  identity (the trust audit log is the motivating case: it is written
  from a telemetry handler, on behalf of the SYSTEM, not a user) must
  pass an explicit node `%SigningContext{}` or the resulting commit is
  unsigned and the local write gate refuses it under
  `accept_unsigned: false` — i.e. the log silently stops recording
  exactly when enforcement turns on.

  Returns `{:ok, log}` / `{:error, reason}` from `commit/2`; the legacy
  `commit/1` head keeps returning the log itself so existing callers are
  unchanged.
  """
  def commit(%__MODULE__{} = log) do
    _ = do_commit(log, [])
    log
  end

  @doc """
  As `commit/1`, but forwards `opts` to the write and REPORTS the
  outcome instead of discarding it.

  `commit/1` throws the store's return value away, which is the right
  shape for a fire-and-forget onramp and the wrong shape for an audit
  writer: a refused audit write that reports `:ok` is a silent
  underreport in the one subsystem whose whole job is not to
  underreport. Callers that must know use this head.
  """
  @spec commit(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def commit(%__MODULE__{} = log, opts) when is_list(opts) do
    case do_commit(log, opts) do
      {:error, reason} -> {:error, reason}
      _ -> {:ok, log}
    end
  end

  defp do_commit(%__MODULE__{} = log, opts) do
    update = Yelixer.Encoding.encode_update(log.doc)
    result = CommitStoreClient.create_chained_commit(log.store, log.uuid, update, %{}, opts)

    case result do
      {:error, _} = error ->
        error

      other ->
        # Gold attestation: create tamper-evident chain entry. Only for
        # writes that actually landed — attesting a refused write would
        # chain over content the store does not have.
        maybe_attest(log.uuid, log.store)
        other
    end
  end

  defp maybe_attest(uuid, store) do
    case Commonplace.Gold.Chain.attest(uuid, store) do
      {:ok, _att} -> :ok
      {:error, _} -> :ok
    end
  end

  # --- Onramp GenServer ---

  # CX-j99d: debounce window for auto-commit. Without auto-commit,
  # incoming magenta messages accumulate in the onramp's in-memory
  # YArray and stay invisible to tail_red (which reads from the
  # commit store). Per-message commits are wasteful under burst
  # load. The debounce gives bursts time to coalesce into one
  # commit while still flushing visibly within human time.
  @auto_commit_debounce_ms 250

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
    {:ok, %{log: log, topic: topic, commit_ref: nil}}
  end

  @impl true
  def handle_info({:magenta, _path, %Magenta{} = msg}, state) do
    log = append(state.log, msg)
    state = %{state | log: log}
    {:noreply, schedule_auto_commit(state)}
  end

  def handle_info(:auto_commit, state) do
    case safe_commit(state.log) do
      {:ok, log} ->
        {:noreply, %{state | log: log, commit_ref: nil}}

      # The store GenServer is gone (e.g. a supervised CommitStore torn down
      # in tests while this debounced onramp still holds a pending flush, or
      # a store shutting down under it). An onramp with no store to persist
      # to is orphaned — stop cleanly rather than crash on the dead-store
      # GenServer.call, which would spew a crash report and (linked into a
      # neighbor's tree) contaminate later tests → seed-dependent CI red
      # (CX-6hxa).
      :store_gone ->
        {:stop, :normal, %{state | commit_ref: nil}}
    end
  end

  @impl true
  def handle_call(:commit, _from, state) do
    case safe_commit(state.log) do
      {:ok, log} ->
        state = cancel_auto_commit(%{state | log: log})
        {:reply, :ok, state}

      :store_gone ->
        {:stop, :normal, {:error, :store_unavailable}, cancel_auto_commit(state)}
    end
  end

  # Commit, tolerating a store whose GenServer has already stopped: a
  # persistence attempt against a dead store raises an `:exit` from the
  # underlying `GenServer.call` (CubDB `{:snapshot, …}`), not an `{:error,
  # …}` tuple. Distinguish that (`:store_gone`) from a normal commit so the
  # onramp can stop cleanly instead of propagating the crash.
  defp safe_commit(log) do
    {:ok, commit(log)}
  catch
    :exit, _ -> :store_gone
  end

  defp schedule_auto_commit(%{commit_ref: ref} = state) when is_reference(ref) do
    # Already scheduled — let it fire on its own cadence so a sustained
    # burst still gets one commit per debounce window rather than
    # repeatedly resetting the timer (which could starve persistence).
    state
  end

  defp schedule_auto_commit(state) do
    ref = Process.send_after(self(), :auto_commit, @auto_commit_debounce_ms)
    %{state | commit_ref: ref}
  end

  defp cancel_auto_commit(%{commit_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | commit_ref: nil}
  end

  defp cancel_auto_commit(state), do: state
end
