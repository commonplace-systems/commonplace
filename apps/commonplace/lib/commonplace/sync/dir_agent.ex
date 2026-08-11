defmodule Commonplace.Sync.DirAgent do
  @moduledoc """
  Per-directory schema watcher — one node of the sparse-sync tree.

  A DirAgent owns the two-way reconciliation between one on-disk
  directory and the **schema document** that describes it (a schema is
  the CRDT directory listing: each entry maps a name to a child UUID and
  a type, `:doc` for a file or `:dir` for a subdirectory). Every
  checked-out directory has exactly one DirAgent, and together they form
  a supervision tree mirroring the directory tree: each DirAgent runs a
  `DynamicSupervisor` under which it starts one `EntryAgent` per file and
  a child `DirAgent` per subdirectory (this module is its own child
  spec, so the structure recurses).

  ## What "sparse" means

  Not every entry in the schema is necessarily materialized on this peer.
  Each schema entry carries a `sync` flag; entries with `sync == false`
  are skipped entirely — no child agent, no file on disk. A DirAgent only
  manages the slice of the tree that is actually checked out here.

  ## The sync cycle (`sync_once/1`)

  The schema document is loaded **once** per cycle and threaded through
  both reconciliation phases. Reloading it between phases would open a
  window where a remote schema mutation landing mid-cycle is seen by one
  phase but not the other; the single load closes that race. The phases:

  1. **Disk → schema** (`sync_disk`): scan the directory; files present
     on disk but absent from the schema are added (new local creations),
     and schema entries that have vanished from disk are removed (subject
     to the distinction below).
  2. **Schema → agents** (`sync_crdt`): schema entries with no running
     child get one spawned — content authored elsewhere (e.g. pulled
     from a remote peer) being materialized here; children whose entry
     was removed from the schema are stopped.
  3. **Recurse** (`sync_children`): call `sync_once` on every live child,
     so each `EntryAgent` flushes its file ↔ CRDT diff and each child
     `DirAgent` runs its own cycle, descending the tree.

  ## Local-delete vs remote-add: the load-bearing distinction

  A name that is in the schema but *not* on disk is ambiguous: it could
  be a file the user just **deleted locally** (→ drop it from the schema)
  or an entry a **remote peer just added** that hasn't been written to
  disk yet (→ keep it; phase 2 spawns its agent and materializes it).
  DirAgent disambiguates by **child-agent presence**: phase 1 only
  deletes entries that already have a running child here — i.e. ones this
  peer had materialized and the user then removed. An entry with no child
  is treated as a pending remote add, never as a local delete. Getting
  this wrong would let an incoming remote creation be misread as a delete
  and erased.

  All schema mutations go through `Commonplace.Sync.SchemaCoordinator`,
  which serializes concurrent writes to a single schema document so two
  agents racing to mutate the same schema don't clobber each other.

  Part of the sparse-sync system — see the sparse-sync design doc for the
  per-entry-agent architecture this is one piece of.
  """

  use GenServer

  alias Commonplace.Sync.{EntryAgent, SchemaCoordinator}
  alias Commonplace.Tree.{Schema, DocBuilder}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{ArtifactStore, CommitStoreClient}
  alias Commonplace.Sync.BinaryClassifier

  @ignored_prefixes [".commonplace"]

  defstruct [
    :schema_uuid,
    :dir_path,
    :store,
    :artifact_store,
    :binary_extensions,
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
    store = Keyword.get(opts, :store, CommitStoreClient)
    artifact_store = Keyword.get(opts, :artifact_store, default_artifact_store())

    # Ensure directory exists
    case File.mkdir_p(dir_path) do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("DirAgent: failed to create #{dir_path}: #{inspect(reason)}")
    end

    # Start a DynamicSupervisor for child processes
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    state = %__MODULE__{
      schema_uuid: schema_uuid,
      dir_path: dir_path,
      store: store,
      artifact_store: artifact_store,
      binary_extensions:
        Keyword.get(opts, :binary_extensions, BinaryClassifier.declared_extensions()),
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
    # Load schema once to avoid race between disk scan and CRDT reconciliation.
    # A remote mutation arriving between two separate loads could be missed.
    schema_doc = load_schema_doc(state)

    state =
      state
      |> sync_disk(schema_doc)
      |> sync_crdt(schema_doc)
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

  defp sync_disk(state, schema_doc) do
    disk_entries = scan_directory(state.dir_path)

    schema_entries = schema_entries_from_doc(schema_doc)
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
    file_uuid = UUID.uuid4()

    case build_file_doc(state, file_uuid, name, path) do
      {:ok, doc} ->
        update = Yelixer.Encoding.encode_update(doc)
        CommitStoreClient.create_commit(state.store, file_uuid, update, nil)

        SchemaCoordinator.mutate(state.schema_uuid, state.store, fn schema_doc ->
          schema_doc = Schema.add_file(schema_doc, name, file_uuid)
          {schema_doc, :ok}
        end)

        entry = %Schema.Entry{name: name, type: :doc, node_id: file_uuid, sync: true}

        case start_child(state, entry) do
          {:ok, pid} -> %{state | children: Map.put(state.children, name, pid)}
          _ -> state
        end

      {:error, reason} ->
        require Logger
        Logger.warning("DirAgent: skipping #{path} (#{inspect(reason)}; excluded-binary floor)")
        state
    end
  end

  defp build_file_doc(state, file_uuid, name, path) do
    base = Yelixer.Doc.new(client_id: stable_client_id(file_uuid))

    case BinaryClassifier.classify(path, binary_extensions: state.binary_extensions) do
      :text ->
        with {:ok, content} <- File.read(path) do
          doc = ContentType.create(base, :text, name)
          {:ok, if(content == "", do: doc, else: ContentType.insert_text(doc, 0, content))}
        end

      {:binary, classified_by} ->
        with {:ok, stat} <- File.stat(path),
             {:ok, cid} <-
               ArtifactStore.put(state.artifact_store, File.stream!(path, [], 64 * 1024)) do
          envelope = %{
            cid: cid,
            size: stat.size,
            mode: Bitwise.band(stat.mode, 0o7777),
            classified_by: classified_by
          }

          {:ok,
           base |> ContentType.create(:binary, name) |> ContentType.put_binary_envelope(envelope)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp add_directory_to_schema(state, name, _path) do
    sub_uuid = UUID.uuid4()

    # Create empty schema doc for the subdirectory
    sub_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(sub_doc)
    CommitStoreClient.create_commit(state.store, sub_uuid, update, nil)

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

  defp sync_crdt(state, schema_doc) do
    schema_entries = schema_structs_from_doc(schema_doc)
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
    # Sync every live child: EntryAgents flush their file<->CRDT diff,
    # and child DirAgents run their own cycle (recursing down the tree).
    # Both EntryAgent and DirAgent implement the :sync_once call.
    Enum.each(state.children, fn {_name, pid} ->
      if Process.alive?(pid) do
        try do
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
      store: state.store,
      artifact_store: state.artifact_store,
      binary_extensions: state.binary_extensions
    })
  end

  defp start_child(state, %Schema.Entry{type: :dir} = entry) do
    DynamicSupervisor.start_child(state.supervisor, {
      __MODULE__,
      schema_uuid: entry.node_id,
      dir_path: Path.join(state.dir_path, entry.name),
      store: state.store,
      artifact_store: state.artifact_store,
      binary_extensions: state.binary_extensions
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

  defp load_schema_doc(state) do
    case DocBuilder.reconstruct_doc(state.store, state.schema_uuid) do
      {:ok, doc} -> doc
      :none -> nil
    end
  end

  defp schema_entries_from_doc(nil), do: %{}
  defp schema_entries_from_doc(doc), do: Schema.entries(doc)

  defp schema_structs_from_doc(nil), do: []
  defp schema_structs_from_doc(doc), do: Schema.list_entries(doc)

  # CX-pyi: stable client_id keeps the SV at one slot per file_uuid
  # across writers of the same logical doc.
  defp stable_client_id(uuid) when is_binary(uuid) do
    :erlang.phash2(uuid, 0xFFFF_FFFF)
  end

  defp default_artifact_store do
    Application.get_env(:commonplace, :data_dir, "data") |> ArtifactStore.new()
  end
end
