defmodule Commonplace.Sync.DirAgent do
  @moduledoc """
  Per-directory schema watcher.

  Manages a directory in the sparse sync tree: watches the corresponding
  schema document and maintains child EntryAgents (one per file) and child
  DirAgents (one per subdirectory).

  On each sync cycle (`sync_once/1`):
  1. Scans the disk directory for new/deleted files and reconciles with the schema
  2. Reloads the schema and reconciles with running child agents
  3. Delegates to each child EntryAgent's `sync_once/1`

  Part of the sparse sync system — one DirAgent per checked-out directory.
  """

  use GenServer

  alias Commonplace.Sync.{EntryAgent, SchemaCoordinator}
  alias Commonplace.Tree.{Schema, DocBuilder}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore

  @ignored_prefixes [".commonplace"]

  defstruct [
    :schema_uuid,
    :dir_path,
    :store,
    :supervisor,
    children: %{}
  ]

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Run one sync cycle: disk scan, CRDT reconciliation, child sync."
  def sync_once(pid) do
    GenServer.call(pid, :sync_once, 60_000)
  end

  @doc "Graceful shutdown — stops all child agents."
  def stop(pid) do
    GenServer.stop(pid, :normal)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    schema_uuid = Keyword.fetch!(opts, :schema_uuid)
    dir_path = Keyword.fetch!(opts, :dir_path)
    store = Keyword.get(opts, :store, CommitStore)

    # Ensure directory exists
    File.mkdir_p!(dir_path)

    # Start a DynamicSupervisor for child processes
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    state = %__MODULE__{
      schema_uuid: schema_uuid,
      dir_path: dir_path,
      store: store,
      supervisor: supervisor,
      children: %{}
    }

    # Load schema, spawn initial children, and run an initial child sync
    # so that CRDT content gets written to disk before the first disk scan
    state = spawn_from_schema(state)
    sync_children(state)

    {:ok, state}
  end

  @impl true
  def handle_call(:sync_once, _from, state) do
    state =
      state
      |> sync_disk()
      |> sync_crdt()
      |> sync_children()

    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    # DynamicSupervisor will handle stopping children
    if state.supervisor && Process.alive?(state.supervisor) do
      DynamicSupervisor.stop(state.supervisor)
    end

    :ok
  end

  # --- Init helpers ---

  defp spawn_from_schema(state) do
    case DocBuilder.reconstruct_doc(state.store, state.schema_uuid) do
      {:ok, doc} ->
        entries = Schema.list_entries(doc)

        children =
          entries
          |> Enum.reject(&(&1.sync == false))
          |> Enum.reduce(%{}, fn entry, acc ->
            case start_child(state, entry) do
              {:ok, pid} -> Map.put(acc, entry.name, pid)
              _ -> acc
            end
          end)

        %{state | children: children}

      :none ->
        state
    end
  end

  # --- Sync: disk scan ---

  defp sync_disk(state) do
    disk_entries = scan_directory(state.dir_path)

    # Reload schema to get current entries
    schema_entries = load_schema_entries(state)
    schema_names = MapSet.new(Map.keys(schema_entries))

    # New files on disk not in schema
    new_on_disk = MapSet.difference(disk_entries, schema_names)

    state =
      Enum.reduce(new_on_disk, state, fn name, acc ->
        path = Path.join(acc.dir_path, name)

        if File.dir?(path) do
          add_directory_to_schema(acc, name, path)
        else
          add_file_to_schema(acc, name, path)
        end
      end)

    # Files deleted from disk but in schema — only consider entries that
    # have a running child agent. Entries in the schema without a child
    # are new remote entries that haven't been synced to disk yet; the
    # CRDT reconciliation phase will spawn agents for them.
    child_names = MapSet.new(Map.keys(state.children))
    managed_schema_names = MapSet.intersection(schema_names, child_names)
    deleted_from_disk = MapSet.difference(managed_schema_names, disk_entries)

    state =
      Enum.reduce(deleted_from_disk, state, fn name, acc ->
        remove_from_schema(acc, name)
      end)

    state
  end

  defp scan_directory(dir_path) do
    case File.ls(dir_path) do
      {:ok, names} ->
        names
        |> Enum.reject(&ignored?/1)
        |> MapSet.new()

      {:error, _} ->
        MapSet.new()
    end
  end

  defp ignored?(name) do
    Enum.any?(@ignored_prefixes, &String.starts_with?(name, &1))
  end

  defp add_file_to_schema(state, name, path) do
    content = File.read!(path)
    file_uuid = UUID.uuid4()

    # Create the CRDT document
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)

    doc =
      if content != "" do
        ContentType.insert_text(doc, 0, content)
      else
        doc
      end

    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(state.store, file_uuid, update, nil)

    # Add to schema via coordinator
    SchemaCoordinator.mutate(state.schema_uuid, state.store, fn schema_doc ->
      schema_doc = Schema.add_file(schema_doc, name, file_uuid)
      {schema_doc, :ok}
    end)

    # Spawn EntryAgent
    entry = %Schema.Entry{name: name, type: :doc, node_id: file_uuid, sync: true}

    case start_child(state, entry) do
      {:ok, pid} ->
        %{state | children: Map.put(state.children, name, pid)}

      _ ->
        state
    end
  end

  defp add_directory_to_schema(state, name, _path) do
    sub_uuid = UUID.uuid4()

    # Create empty schema doc for the subdirectory
    sub_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(sub_doc)
    CommitStore.create_commit(state.store, sub_uuid, update, nil)

    # Add to parent schema via coordinator
    SchemaCoordinator.mutate(state.schema_uuid, state.store, fn schema_doc ->
      schema_doc = Schema.add_directory(schema_doc, name, sub_uuid)
      {schema_doc, :ok}
    end)

    # Spawn child DirAgent
    entry = %Schema.Entry{name: name, type: :dir, node_id: sub_uuid, sync: true}

    case start_child(state, entry) do
      {:ok, pid} ->
        %{state | children: Map.put(state.children, name, pid)}

      _ ->
        state
    end
  end

  defp remove_from_schema(state, name) do
    # Remove from schema via coordinator
    SchemaCoordinator.mutate(state.schema_uuid, state.store, fn schema_doc ->
      schema_doc = Schema.remove_entry(schema_doc, name)
      {schema_doc, :ok}
    end)

    # Stop child agent if running
    state = stop_child(state, name)
    state
  end

  # --- Sync: CRDT reconciliation ---

  defp sync_crdt(state) do
    schema_entries = load_schema_entries_as_structs(state)
    schema_names = MapSet.new(Enum.map(schema_entries, & &1.name))
    child_names = MapSet.new(Map.keys(state.children))

    # New entries in schema not in children (and sync != false)
    new_in_schema =
      schema_entries
      |> Enum.filter(fn entry ->
        entry.sync != false and not MapSet.member?(child_names, entry.name)
      end)

    state =
      Enum.reduce(new_in_schema, state, fn entry, acc ->
        case start_child(acc, entry) do
          {:ok, pid} -> %{acc | children: Map.put(acc.children, entry.name, pid)}
          _ -> acc
        end
      end)

    # Entries removed from schema but still in children
    removed_from_schema = MapSet.difference(child_names, schema_names)

    state =
      Enum.reduce(removed_from_schema, state, fn name, acc ->
        stop_child(acc, name)
      end)

    state
  end

  # --- Sync: children ---

  defp sync_children(state) do
    # Only sync EntryAgents — child DirAgents manage their own sync
    Enum.each(state.children, fn {_name, pid} ->
      if Process.alive?(pid) do
        try do
          # Try EntryAgent.sync_once — it will work for EntryAgents
          # and fail for DirAgents (different handle_call pattern, but both support :sync_once)
          GenServer.call(pid, :sync_once, 30_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    # Clean up dead children
    children =
      Map.filter(state.children, fn {_name, pid} ->
        Process.alive?(pid)
      end)

    %{state | children: children}
  end

  # --- Child management ---

  defp start_child(state, %Schema.Entry{type: :doc} = entry) do
    DynamicSupervisor.start_child(state.supervisor, {
      EntryAgent,
      doc_uuid: entry.node_id,
      file_path: Path.join(state.dir_path, entry.name),
      store: state.store
    })
  end

  defp start_child(state, %Schema.Entry{type: :dir} = entry) do
    DynamicSupervisor.start_child(state.supervisor, {
      __MODULE__,
      schema_uuid: entry.node_id,
      dir_path: Path.join(state.dir_path, entry.name),
      store: state.store
    })
  end

  defp start_child(_state, _entry), do: {:error, :unknown_type}

  defp stop_child(state, name) do
    case Map.get(state.children, name) do
      nil ->
        state

      pid ->
        if Process.alive?(pid) do
          DynamicSupervisor.terminate_child(state.supervisor, pid)
        end

        %{state | children: Map.delete(state.children, name)}
    end
  end

  # --- Schema helpers ---

  defp load_schema_entries(state) do
    case DocBuilder.reconstruct_doc(state.store, state.schema_uuid) do
      {:ok, doc} -> Schema.entries(doc)
      :none -> %{}
    end
  end

  defp load_schema_entries_as_structs(state) do
    case DocBuilder.reconstruct_doc(state.store, state.schema_uuid) do
      {:ok, doc} -> Schema.list_entries(doc)
      :none -> []
    end
  end
end
