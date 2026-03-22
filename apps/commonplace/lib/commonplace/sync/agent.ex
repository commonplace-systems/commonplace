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

  defstruct [:root_uuid, :sync_dir, :store, :lock, :known_paths, :known_hashes]

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
      known_paths: MapSet.new(),
      known_hashes: %{}
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
    # and modifications where disk hasn't actually changed (remote CRDT update)
    sync_outbound_recursive(state.root_uuid, state.sync_dir, state.store, state.known_paths, state.known_hashes)

    # Phase 2: Inbound — CRDT → disk
    Export.export(state.root_uuid, state.sync_dir, state.store)

    # Phase 3: Update known state from current disk
    {known, hashes} = scan_disk_state(state.sync_dir, "")
    %{state | known_paths: known, known_hashes: hashes}
  end

  defp sync_outbound_recursive(root_uuid, dir, store, known_paths, known_hashes) do
    changes = Watcher.detect_changes(root_uuid, dir, store)

    changes =
      Enum.filter(changes, fn change ->
        case change.type do
          :deleted ->
            # Only delete if the path was previously known on disk
            MapSet.member?(known_paths, change.name)

          :modified ->
            # Only apply if disk content actually changed from what we last synced.
            # If disk matches known hash, the CRDT was updated remotely — let
            # inbound export handle it instead of overwriting CRDT with stale disk.
            disk_content = File.read!(change.path)
            disk_hash = :erlang.md5(disk_content)
            Map.get(known_hashes, change.name) != disk_hash

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
          prefix = entry.name <> "/"

          sub_known =
            known_paths
            |> Enum.filter(&String.starts_with?(&1, prefix))
            |> Enum.map(&String.replace_leading(&1, prefix, ""))
            |> MapSet.new()

          sub_hashes =
            known_hashes
            |> Enum.filter(fn {k, _} -> String.starts_with?(k, prefix) end)
            |> Enum.map(fn {k, v} -> {String.replace_leading(k, prefix, ""), v} end)
            |> Map.new()

          sync_outbound_recursive(entry.node_id, sub_dir, store, sub_known, sub_hashes)
        end
      end
    end)
  end

  defp scan_disk_state(dir, prefix) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce(names, {MapSet.new(), %{}}, fn name, {paths, hashes} ->
          rel = if prefix == "", do: name, else: "#{prefix}/#{name}"
          full = Path.join(dir, name)

          paths = MapSet.put(paths, rel)

          if File.dir?(full) do
            {sub_paths, sub_hashes} = scan_disk_state(full, rel)
            {MapSet.union(paths, sub_paths), Map.merge(hashes, sub_hashes)}
          else
            content = File.read!(full)
            hash = :erlang.md5(content)
            {paths, Map.put(hashes, rel, hash)}
          end
        end)

      {:error, _} ->
        {MapSet.new(), %{}}
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
