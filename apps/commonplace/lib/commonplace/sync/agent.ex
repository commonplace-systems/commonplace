defmodule Commonplace.Sync.Agent do
  @moduledoc """
  Bidirectional sync agent — bridges CRDT documents with files on disk.

  Sync cycle:
  1. Outbound (disk → CRDT): detect disk changes, sync to CRDT
     - Only treats files as "deleted" if they were previously synced
  2. Inbound (CRDT → disk): export CRDT state to disk

  Tracks which paths were last seen on disk to distinguish
  "CRDT-only file not yet exported" from "file deleted on disk".
  """

  use GenServer

  alias Commonplace.Sync.{Watcher, Export}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  defstruct [:root_uuid, :sync_dir, :store, :lock, :known_paths]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Run one sync cycle: outbound (disk → CRDT), then inbound (CRDT → disk)."
  def sync_once(pid) do
    GenServer.call(pid, :sync_once, 30_000)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      root_uuid: Keyword.fetch!(opts, :root_uuid),
      sync_dir: Keyword.fetch!(opts, :sync_dir),
      store: Keyword.get(opts, :store, CommitStore),
      lock: Keyword.get(opts, :lock, Commonplace.Sync.FileLock),
      known_paths: MapSet.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:sync_once, _from, state) do
    state = do_sync(state)
    {:reply, :ok, state}
  end

  defp do_sync(state) do
    # Phase 1: Outbound — disk → CRDT
    # Use detect_changes but filter out deletions for paths we haven't seen
    sync_outbound_recursive(state.root_uuid, state.sync_dir, state.store, state.known_paths)

    # Phase 2: Inbound — CRDT → disk
    Export.export(state.root_uuid, state.sync_dir, state.store)

    # Phase 3: Update known paths from current disk state
    known = scan_disk_paths(state.sync_dir, "")
    %{state | known_paths: known}
  end

  defp sync_outbound_recursive(root_uuid, dir, store, known_paths) do
    changes = Watcher.detect_changes(root_uuid, dir, store)

    # Filter deletions: only delete if the path was previously known on disk
    changes =
      Enum.filter(changes, fn change ->
        case change.type do
          :deleted ->
            relative = change.name
            MapSet.member?(known_paths, relative)

          _ ->
            true
        end
      end)

    if changes != [] do
      Watcher.apply_changes(changes, root_uuid, dir, store)
    end

    # Recurse into subdirectories
    schema_doc = load_schema(root_uuid, store)

    Schema.list_entries(schema_doc)
    |> Enum.each(fn entry ->
      if entry.type == :dir do
        sub_dir = Path.join(dir, entry.name)

        if File.dir?(sub_dir) do
          sub_known =
            known_paths
            |> Enum.filter(&String.starts_with?(&1, entry.name <> "/"))
            |> Enum.map(&String.replace_leading(&1, entry.name <> "/", ""))
            |> MapSet.new()

          sync_outbound_recursive(entry.node_id, sub_dir, store, sub_known)
        end
      end
    end)
  end

  defp scan_disk_paths(dir, prefix) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce(names, MapSet.new(), fn name, acc ->
          path = if prefix == "", do: name, else: "#{prefix}/#{name}"
          full = Path.join(dir, name)

          acc = MapSet.put(acc, path)

          if File.dir?(full) do
            MapSet.union(acc, scan_disk_paths(full, path))
          else
            acc
          end
        end)

      {:error, _} ->
        MapSet.new()
    end
  end

  defp load_schema(uuid, store) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end
end
