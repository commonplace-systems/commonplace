defmodule Commonplace.Document.Server do
  @moduledoc """
  GenServer owning the live, in-RAM copy of a single CRDT document.

  Every document in Commonplace has two representations. The durable one
  is a *chain of commits* in the CommitStore: an append-only,
  content-addressed log where each commit holds a Yjs binary update and
  points at its parent. The ephemeral one is a `Yelixer.Doc` — the
  decoded, editable CRDT held in this process's memory. This server is
  the bridge: it loads the latest committed state into a `Yelixer.Doc`
  at startup, applies edits to that in-RAM doc, broadcasts them to peers,
  and writes new commits back to the chain.

  `parent_commit` is the hinge between the two. It names the commit our
  in-RAM doc currently descends from — the point a new `commit` chains
  onto, and the baseline a rebase reconstructs from. Keeping it accurate
  as state changes (locally and remotely) is most of what this module
  worries about.

  ## Two sources of change

  A document mutates from two directions, and they are handled
  differently. (Commonplace names its PubSub topics by color — a
  convention owned by `Dataflow.PubSub`; here, *blue* carries live local
  edits between servers for the same UUID, *sync* carries durable remote
  commits between nodes.)

  - **Local edits** (`insert_text`, `set_key`, `apply_update`, …) mutate
    the in-RAM `Yelixer.Doc` and are not durable until `commit` writes a
    new commit to the chain and advances `parent_commit` to it. Local
    edits broadcast on the *blue* channel so other live servers for the
    same UUID see them immediately.
  - **Remote commits** arrive over the *sync* channel from other BEAM
    nodes (see `handle_info({:remote_commit, ...})`). These are already
    durable elsewhere; the job here is to fold them into local state
    correctly without losing in-flight local edits.

  ## Namespace tracking (`current_namespace`) — CX-ch5

  A *namespace* is the identity space a document's CRDT items live in.
  Most commits inherit their parent's namespace; a *snapshot* commit
  starts a fresh one by re-encoding the whole visible document under new
  item IDs (a new *epoch*). A namespace is identified by the id (hash) of
  the snapshot commit that rooted it — its `snapshot_parent`.
  `current_namespace` is this server's record of which namespace its
  in-RAM doc currently belongs to: that hash, which other subsystems
  (rebase, cross-epoch merge) consult to decide whether an incoming edit
  speaks the same identity dialect. (Why snapshots exist and how their
  payloads are built is the Snapshotter's story, not this module's.)

  It is derived from the loaded latest commit at init and advanced
  whenever state moves to a new namespace: on a local `commit`, on a
  remote incremental apply, and (resetting to a brand-new root) on a
  snapshot arrival. Pre-umbrella documents whose latest commit carries
  legacy `metadata = %{}` have no namespace; the tracker stays `nil` for
  them, and `advance_namespace/2` is careful never to regress a real
  namespace back to `nil`.

  ## Applying a remote commit

  Two cases, distinguished by `metadata.kind`:

  - **Incremental** (regular/merge): apply the commit's update on top of
    the current doc. On success we advance *both* `parent_commit` *and*
    the store's `:latest` pointer (CX-bgq). Both must move together: if
    only the in-RAM `parent_commit` advanced, a later snapshot rebase
    would reconstruct its baseline from a `:latest` the commit-log walk
    can't reach, diff against a stale doc, and double-apply content the
    snapshot already contains.
  - **Snapshot** (CX-u7p + CX-dqn): a snapshot re-encodes the full doc
    under fresh IDs, so it is applied to a *fresh* `Yelixer.Doc` rather
    than layered onto the current one. Layering would be wrong precisely
    because the IDs are fresh: the current doc still holds the *old*
    identities for the same content, so a CRDT merge of the two
    identity-sets duplicates that content, and content whose old identity
    was a tombstone (deleted) reappears under its new, undeleted identity.
    Any local dirty edits not yet in the snapshot are then positionally
    rebased onto the fresh doc. This is
    all-or-nothing: if the rebase fails, the whole snapshot application
    is aborted and state is left untouched — the snapshot commit is
    already safe in the CommitStore and can be retried later.

  Commits this node originated (`source_node == Node.self()`) are ignored
  here; their effects were already applied when they were authored.

  Mechanism lives elsewhere: CRDT encode/decode in `Yelixer.Encoding`,
  baseline reconstruction in `Tree.DocBuilder`, positional rebase in
  `Document.Rebase`, namespace derivation in `Store.Namespace`.
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
