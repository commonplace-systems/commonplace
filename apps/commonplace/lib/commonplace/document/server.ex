defmodule Commonplace.Document.Server do
  @moduledoc """
  GenServer managing a single CRDT document.

  Wraps a Yelixer.Doc, handles edits, publishes changes
  to PubSub, and commits state to the CommitStoreClient.
  """

  use GenServer

  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Store.Namespace
  alias Commonplace.Document.ContentType
  alias Commonplace.Document.Rebase
  alias Commonplace.Tree.DocBuilder
  alias Commonplace.Dataflow.PubSub, as: CPPubSub

  # CX-ch5: :current_namespace tracks the snapshot_parent hash of the
  # namespace this server is currently bound to. Advances on snapshot
  # arrival (new trust root) and on epoch-join (a remote commit declaring
  # a different snapshot_parent). Derived from the loaded latest commit
  # at init; `nil` for pre-umbrella docs whose latest commit has legacy
  # `metadata = %{}`.
  defstruct [:uuid, :doc, :parent_commit, :commit_store, :current_namespace]

  def start_link(opts) do
    uuid = Keyword.fetch!(opts, :uuid)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Commonplace.Document.Registry, uuid}}
    )
  end

  def get_doc(pid), do: GenServer.call(pid, :get_doc)

  @doc """
  Current namespace (snapshot_parent hash) this server is bound to.

  Returns a binary hash or `nil` (for pre-umbrella docs whose latest
  commit carries legacy `metadata = %{}`). Advances on snapshot arrival
  and epoch-join — see `handle_info(:remote_commit, ...)`.
  """
  def current_namespace(pid), do: GenServer.call(pid, :current_namespace)

  def apply_update(pid, update), do: GenServer.call(pid, {:apply_update, update})

  def commit(pid), do: GenServer.call(pid, :commit)

  @doc "Initialize the document envelope with a content type and name."
  def create(pid, type, name), do: GenServer.call(pid, {:create, type, name})

  @doc "Insert text at an index (for text documents)."
  def insert_text(pid, index, text), do: GenServer.call(pid, {:insert_text, index, text})

  @doc "Set a key in the content map (for map documents)."
  def set_key(pid, key, value), do: GenServer.call(pid, {:set_key, key, value})

  @doc "Delete a key from the content map (for map documents)."
  def delete_key(pid, key), do: GenServer.call(pid, {:delete_key, key})

  @doc "Push items to the end of the content array (for array documents)."
  def push_items(pid, values), do: GenServer.call(pid, {:push_items, values})

  @doc "Insert items at an index in the content array (for array documents)."
  def insert_items(pid, index, values),
    do: GenServer.call(pid, {:insert_items, index, values})

  @doc "Delete items from the content array (for array documents)."
  def delete_items(pid, index, length),
    do: GenServer.call(pid, {:delete_items, index, length})

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

    {doc, parent_commit, current_namespace} =
      case CommitStoreClient.latest_commit(commit_store, uuid) do
        {:ok, commit} ->
          doc = Yelixer.Doc.new(client_id: client_id)
          {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
          {doc, commit.id, Namespace.current_namespace(commit)}

        :none ->
          {Yelixer.Doc.new(client_id: client_id), nil, nil}
      end

    CPPubSub.subscribe_sync(uuid)

    {:ok,
     %__MODULE__{
       uuid: uuid,
       doc: doc,
       parent_commit: parent_commit,
       commit_store: commit_store,
       current_namespace: current_namespace
     }}
  end

  @impl true
  def handle_call(:get_doc, _from, state) do
    {:reply, state.doc, state}
  end

  @impl true
  def handle_call(:current_namespace, _from, state) do
    {:reply, state.current_namespace, state}
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

    # CX-ch5: tag as :regular so CommitStore auto-stamps
    # `metadata.snapshot_parent` from the parent's namespace. Without the
    # `:kind` tag, the store treats the write as pre-umbrella legacy and
    # leaves metadata empty, defeating namespace tracking.
    commit =
      CommitStoreClient.create_commit(
        state.commit_store,
        state.uuid,
        update,
        state.parent_commit,
        %{kind: :regular}
      )

    {:reply, {:ok, commit},
     %{
       state
       | parent_commit: commit.id,
         current_namespace: advance_namespace(state.current_namespace, commit)
     }}
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
  def handle_call({:delete_key, key}, _from, state) do
    doc = ContentType.delete_key(state.doc, key)
    {:reply, :ok, %{state | doc: doc}}
  end

  @impl true
  def handle_call({:push_items, values}, _from, state) do
    doc = ContentType.push_items(state.doc, values)
    {:reply, :ok, %{state | doc: doc}}
  end

  @impl true
  def handle_call({:insert_items, index, values}, _from, state) do
    doc = ContentType.insert_items(state.doc, index, values)
    {:reply, :ok, %{state | doc: doc}}
  end

  @impl true
  def handle_call({:delete_items, index, length}, _from, state) do
    doc = ContentType.delete_items(state.doc, index, length)
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

      if snapshot_commit?(commit) do
        handle_snapshot_commit(commit, state)
      else
        # CX-bgq: on successful remote-incremental apply, advance both
        # state.parent_commit (so rebase reconstructs the baseline at the
        # right point) and the store's :latest (so reconstruct_doc_at's
        # commit_log walk can reach it). Otherwise a subsequent snapshot
        # rebase diffs from a stale baseline and double-applies content
        # that the snapshot already contains.
        case Yelixer.Encoding.apply_update(state.doc, commit.update) do
          {:ok, doc} ->
            CommitStoreClient.set_latest(state.commit_store, state.uuid, commit.id)

            {:noreply,
             %{
               state
               | doc: doc,
                 parent_commit: commit.id,
                 current_namespace: advance_namespace(state.current_namespace, commit)
             }}

          {:error, _} ->
            {:noreply, state}
        end
      end
    else
      {:noreply, state}
    end
  end

  # CX-u7p + CX-dqn: snapshot commits re-encode the full visible doc under
  # fresh item IDs. Apply to a fresh Doc (avoid duplication/tombstone
  # resurrection), then positionally rebase any local dirty edits onto the
  # fresh doc (CX-dqn phase 1 — YText only). All-or-nothing: on rebase
  # error, abort the snapshot application entirely and leave state
  # untouched. The commit is still in the CommitStore for later.
  defp handle_snapshot_commit(commit, state) do
    fresh = Yelixer.Doc.new(client_id: state.doc.client_id)

    with {:ok, new_doc} <- Yelixer.Encoding.apply_update(fresh, commit.update),
         {:ok, final_doc} <- rebase_onto_snapshot(state, new_doc) do
      # CX-ch5: a snapshot is its own namespace root — advance the
      # tracker to the snapshot's id.
      {:noreply, %{state | doc: final_doc, current_namespace: commit.id}}
    else
      {:error, {:rebase, reason}} ->
        :telemetry.execute(
          [:commonplace, :document, :snapshot_rebase_aborted],
          %{count: 1},
          %{uuid: state.uuid, reason: reason}
        )

        {:noreply, state}

      {:error, _} ->
        {:noreply, state}
    end
  end

  defp rebase_onto_snapshot(%__MODULE__{parent_commit: nil}, new_doc), do: {:ok, new_doc}

  defp rebase_onto_snapshot(
         %__MODULE__{parent_commit: parent_id, commit_store: store, uuid: uuid, doc: dirty_doc} =
           state,
         new_doc
       ) do
    case DocBuilder.reconstruct_doc_at(store, uuid, parent_id) do
      {:ok, old_doc} ->
        case Rebase.rebase(old_doc, dirty_doc, new_doc) do
          {:ok, rebased} ->
            :telemetry.execute(
              [:commonplace, :document, :snapshot_rebased],
              %{count: 1},
              %{uuid: state.uuid}
            )

            {:ok, rebased}

          {:error, reason} ->
            {:error, {:rebase, reason}}
        end

      :none ->
        {:ok, new_doc}
    end
  end

  defp snapshot_commit?(commit) do
    case Map.get(commit, :metadata) do
      %{kind: :snapshot} -> true
      _ -> false
    end
  end

  # CX-ch5: derive the new tracker value. Snapshot and genesis kinds are
  # their own namespace root; regular/merge kinds inherit their declared
  # `snapshot_parent`. Legacy `%{}` metadata returns nil — preserve the
  # existing tracker in that case to avoid regressing pre-umbrella state.
  defp advance_namespace(current, commit) do
    case Namespace.current_namespace(commit) do
      nil -> current
      ns -> ns
    end
  end
end
