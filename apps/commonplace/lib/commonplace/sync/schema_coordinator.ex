defmodule Commonplace.Sync.SchemaCoordinator do
  @moduledoc """
  Serializes schema mutations for a given UUID.

  When multiple DirAgents modify the same schema concurrently (overlapping
  checkouts), mutations must be serialized to avoid CRDT state corruption.
  Each schema UUID gets a coordinating GenServer process on-demand.

  Serialization is just the GenServer's single mailbox: every mutation
  for a given UUID routes to the one process registered under it (via
  `Registry`), so the full read-modify-write cycle below — reconstruct,
  apply the mutation fn, commit — runs atomically with respect to other
  mutations of the *same* schema. Distinct UUIDs get independent
  coordinators and proceed in parallel. "Atomic" here means
  no-interleaving, not rollback: a `mutation_fn` that raises commits
  nothing (the crash aborts before the commit) and takes the coordinator
  down with it — it is simply restarted on the next `mutate/3`.

  Usage:

      SchemaCoordinator.mutate(schema_uuid, store, fn doc ->
        doc = Schema.add_file(doc, "notes.txt", new_uuid)
        {doc, :ok}
      end)

  The coordinator:
  1. Loads the current schema doc via `DocBuilder.reconstruct_doc/2`
  2. Applies the mutation function to get a modified doc
  3. Encodes the result as a Yjs update
  4. Creates a chained commit
  5. Returns `{:ok, result}` or `{:error, reason}`
  """

  use GenServer

  alias Commonplace.Tree.DocBuilder
  alias Commonplace.Store.CommitStoreClient

  # --- Public API ---

  @doc """
  Apply a serialized mutation to the schema identified by `schema_uuid`.

  The `mutation_fn` receives the reconstructed doc and must return
  `{modified_doc, result}`. The result is passed back as `{:ok, result}`.

  Returns `{:ok, result}` on success, or `{:error, reason}` on failure.
  """
  def mutate(schema_uuid, store, mutation_fn) do
    pid = ensure_started(schema_uuid)
    GenServer.call(pid, {:mutate, store, mutation_fn}, 10_000)
  end

  defp ensure_started(schema_uuid) do
    case Registry.lookup(Commonplace.SchemaCoordinator.Registry, schema_uuid) do
      [{pid, _}] ->
        pid

      [] ->
        case DynamicSupervisor.start_child(
               Commonplace.SchemaCoordinator.Supervisor,
               {__MODULE__, schema_uuid: schema_uuid}
             ) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  # --- GenServer callbacks ---

  def start_link(opts) do
    schema_uuid = Keyword.fetch!(opts, :schema_uuid)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Commonplace.SchemaCoordinator.Registry, schema_uuid}}
    )
  end

  @impl true
  def init(opts) do
    {:ok, %{schema_uuid: Keyword.fetch!(opts, :schema_uuid)}}
  end

  @impl true
  def handle_call({:mutate, store, mutation_fn}, _from, state) do
    result = do_mutate(state.schema_uuid, store, mutation_fn)
    {:reply, result, state}
  end

  defp do_mutate(schema_uuid, store, mutation_fn) do
    case DocBuilder.reconstruct_doc(store, schema_uuid) do
      {:ok, doc} ->
        {modified_doc, result} = mutation_fn.(doc)
        update = Yelixer.Encoding.encode_update(modified_doc)
        CommitStoreClient.create_chained_commit(store, schema_uuid, update)
        {:ok, result}

      :none ->
        {:error, :no_schema}
    end
  end
end
