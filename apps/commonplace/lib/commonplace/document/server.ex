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
  alias Commonplace.Tree.DocBuilder

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

    CPPubSub.subscribe_sync(uuid)

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

  @impl true
  def handle_info({:remote_commit, commit, source_node}, state) do
    if source_node != Node.self() do
      CommitStoreClient.import_commit(state.commit_store, commit)

      cond do
        # CX-u7p r2: If a remote snapshot arrives that is chained directly
        # on top of the commit we already consider canonical
        # (`state.parent_commit`), the snapshot is by construction a
        # compaction of state we already have. In that case `state.doc`
        # already reflects the snapshot's logical content (possibly plus
        # uncommitted local edits), so neither reset nor apply is needed —
        # resetting here would drop the local edits that the user is
        # actively making. Import the commit and advance both
        # `parent_commit` (r4) and the store's `:latest` (r5) to the
        # snapshot so subsequent local commits chain onto it and the
        # `commit_log` walk (which starts from `:latest`) reaches the
        # snapshot — without advancing `:latest`, a later
        # `snapshot_is_noop?` call would run `reconstruct_doc_at` against
        # a chain that can no longer reach the new head, fall back to the
        # reset path, and drop dirty local edits.
        snapshot_commit?(commit) and snapshot_is_noop?(commit, state) ->
          CommitStoreClient.set_latest(state.commit_store, state.uuid, commit.id)
          {:noreply, %{state | parent_commit: commit.id}}

        # CX-u7p: snapshot commits are self-contained re-encodings of the
        # full visible doc state under fresh item IDs. Applying them on top
        # of an already-populated in-memory doc would duplicate content and
        # resurrect tombstoned items. Reset to a fresh Doc.new() before
        # applying a snapshot's update; normal commits still apply
        # incrementally as before.
        snapshot_commit?(commit) ->
          apply_with_base(commit, Yelixer.Doc.new(client_id: state.doc.client_id), state)

        true ->
          apply_with_base(commit, state.doc, state)
      end
    else
      {:noreply, state}
    end
  end

  # Apply `commit` on top of `base_doc` and advance the tracked head.
  #
  # CX-u7p round 3 P1: `state.parent_commit` must reflect what has
  # actually been incorporated into `state.doc`, regardless of whether
  # the commit originated locally or remotely. Without this, the
  # `snapshot_is_noop?/2` check (which compares `commit.parent_id`
  # against `state.parent_commit`) would misclassify a compaction
  # snapshot as divergent after any remote delta had advanced
  # `state.doc` but left `state.parent_commit` pointing at the
  # previous (local) head — causing the reset path to silently drop
  # dirty in-memory edits.
  defp apply_with_base(commit, base_doc, state) do
    case Yelixer.Encoding.apply_update(base_doc, commit.update) do
      {:ok, doc} ->
        {:noreply, %{state | doc: doc, parent_commit: commit.id}}

      {:error, _} ->
        {:noreply, state}
    end
  end

  # A snapshot is a "no-op" from the perspective of this server when:
  #
  #   1. It is chained directly on top of `state.parent_commit` (the
  #      commit we already treat as our canonical head), AND
  #   2. Its materialized content equals the rebuild of the committed
  #      chain up to `parent_commit` — i.e. it is an honest compaction of
  #      the same state we already know, not a divergent rewrite.
  #
  # In that case `state.doc` already materializes the snapshot's logical
  # content (possibly plus uncommitted local edits), so resetting would
  # drop those local edits for no benefit. Preserving `state.doc` keeps
  # user-in-progress edits alive when a remote compaction snapshot
  # arrives (CX-u7p round-2 P1). A snapshot with novel or divergent
  # content still triggers the reset path below.
  defp snapshot_is_noop?(commit, %__MODULE__{parent_commit: parent_commit} = state)
       when not is_nil(parent_commit) do
    if commit.parent_id == parent_commit do
      with {:ok, committed} <-
             DocBuilder.reconstruct_doc_at(state.commit_store, state.uuid, parent_commit),
           {:ok, snap_doc} <-
             Yelixer.Encoding.apply_update(Yelixer.Doc.new(), commit.update) do
        ContentType.get_content(committed) == ContentType.get_content(snap_doc)
      else
        _ -> false
      end
    else
      false
    end
  end

  defp snapshot_is_noop?(_commit, _state), do: false

  defp snapshot_commit?(commit) do
    case Map.get(commit, :metadata) do
      %{kind: :snapshot} -> true
      _ -> false
    end
  end
end
