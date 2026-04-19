defmodule Commonplace.Sync.Watcher do
  @moduledoc """
  Filesystem watcher — detects changes on disk and syncs them into CRDT documents.

  Phase 2 of filesystem sync. Compares the current state of files on disk
  with the schema tree and CRDT document contents, producing a list of
  changes that need to be synced.
  """

  alias Commonplace.Tree.Schema
  alias Commonplace.Document.{ContentType, Diff}
  alias Commonplace.Store.CommitStoreClient

  defmodule Change do
    @moduledoc "A detected filesystem change."
    defstruct [:type, :name, :path, :is_dir, :old_name, :node_id]

    @type t :: %__MODULE__{
            type: :created | :modified | :deleted | :renamed,
            name: String.t(),
            path: String.t(),
            is_dir: boolean(),
            old_name: String.t() | nil,
            node_id: String.t() | nil
          }
  end

  @doc """
  Detect changes between the filesystem and the CRDT document tree.

  Compares files on disk at `dir` with the schema at `root_uuid`.
  Returns a list of `Change` structs.
  """
  def detect_changes(root_uuid, dir, store \\ CommitStoreClient, opts \\ []) do
    schema_doc = load_schema(root_uuid, store)
    schema_entries = Schema.entries(schema_doc)
    inode_registry = Keyword.get(opts, :inode_registry)

    # Get files/dirs on disk (exclude system dirs)
    disk_entries =
      case File.ls(dir) do
        {:ok, names} ->
          names
          |> Enum.reject(&String.starts_with?(&1, ".commonplace"))
          |> MapSet.new()

        {:error, _} ->
          MapSet.new()
      end

    schema_names = MapSet.new(Map.keys(schema_entries))

    # New files (on disk but not in schema)
    created =
      MapSet.difference(disk_entries, schema_names)
      |> Enum.map(fn name ->
        path = Path.join(dir, name)

        %Change{
          type: :created,
          name: name,
          path: path,
          is_dir: File.dir?(path)
        }
      end)

    # Deleted files (in schema but not on disk)
    deleted =
      MapSet.difference(schema_names, disk_entries)
      |> Enum.map(fn name ->
        %Change{
          type: :deleted,
          name: name,
          path: Path.join(dir, name),
          is_dir: schema_entries[name]["type"] == "dir"
        }
      end)

    # Modified files (on disk and in schema, but content differs)
    modified =
      MapSet.intersection(disk_entries, schema_names)
      |> Enum.flat_map(fn name ->
        path = Path.join(dir, name)
        entry = schema_entries[name]

        if entry["type"] == "doc" and File.regular?(path) do
          disk_content = File.read!(path)
          crdt_content = load_content(entry["node_id"], store)

          if disk_content != crdt_content do
            [%Change{type: :modified, name: name, path: path, is_dir: false}]
          else
            []
          end
        else
          []
        end
      end)

    # Detect renames: match by inode (if registry available) then by content
    {renames, remaining_created, remaining_deleted} =
      detect_renames(created, deleted, schema_entries, dir, store, inode_registry)

    remaining_created ++ remaining_deleted ++ modified ++ renames
  end

  @doc """
  Recursively detect and apply changes for a directory tree.

  Syncs the root directory, then recurses into subdirectories.
  """
  def sync_recursive(root_uuid, dir, store \\ CommitStoreClient) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:commonplace, :sync, :start],
      %{system_time: System.system_time()},
      %{root_uuid: root_uuid, dir: dir}
    )

    changes = detect_changes(root_uuid, dir, store)
    apply_changes(changes, root_uuid, dir, store)

    :telemetry.execute(
      [:commonplace, :sync, :stop],
      %{duration: System.monotonic_time() - start_time, changes: length(changes)},
      %{root_uuid: root_uuid, dir: dir}
    )

    # Recurse into subdirectories
    schema_doc = load_schema(root_uuid, store)

    Schema.list_entries(schema_doc)
    |> Enum.each(fn entry ->
      if entry.type == :dir do
        sub_dir = Path.join(dir, entry.name)

        if File.dir?(sub_dir) do
          sync_recursive(entry.node_id, sub_dir, store)
        end
      end
    end)
  end

  @doc """
  Apply detected changes to the CRDT document tree.

  Creates/updates documents and updates the schema for each change.
  """
  def apply_changes(changes, root_uuid, _dir, store \\ CommitStoreClient) do
    Enum.each(changes, fn change ->
      case change.type do
        :created ->
          apply_create(change, root_uuid, store)

        :modified ->
          apply_modify(change, root_uuid, store)

        :deleted ->
          apply_delete(change, root_uuid, store)

        :renamed ->
          apply_rename(change, root_uuid, store)
      end
    end)
  end

  defp apply_create(%Change{is_dir: true} = change, root_uuid, store) do
    # Create empty schema doc for new directory
    sub_uuid = UUID.uuid4()
    sub_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(sub_doc)
    CommitStoreClient.create_commit(store, sub_uuid, update, nil)

    # Add to parent schema
    root_doc = load_schema(root_uuid, store)
    root_doc = Schema.add_directory(root_doc, change.name, sub_uuid)
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStoreClient.create_chained_commit(store, root_uuid, update)
  end

  defp apply_create(%Change{is_dir: false} = change, root_uuid, store) do
    content = File.read!(change.path)

    # Create document with envelope.
    # CX-pyi: stable client_id so subsequent apply_modify writes (which
    # also use this id) share one slot in the state vector instead of
    # minting a fresh client per write.
    file_uuid = UUID.uuid4()
    doc = Yelixer.Doc.new(client_id: stable_client_id(file_uuid))
    doc = ContentType.create(doc, :text, change.name)

    doc =
      if content != "" do
        ContentType.insert_text(doc, 0, content)
      else
        doc
      end

    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_commit(store, file_uuid, update, nil)

    # Add to parent schema
    root_doc = load_schema(root_uuid, store)
    root_doc = Schema.add_file(root_doc, change.name, file_uuid)
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStoreClient.create_chained_commit(store, root_uuid, update)
  end

  defp apply_modify(change, root_uuid, store) do
    root_doc = load_schema(root_uuid, store)

    case Schema.get_entry(root_doc, change.name) do
      {:ok, entry} ->
        new_content = File.read!(change.path)

        # CX-pyi: load + mutate pattern. Reconstruct the existing doc
        # under a stable client_id, compute the text diff between the
        # previous content and the disk content, and apply it as
        # incremental Yjs ops. This keeps the state vector at one slot
        # per file regardless of how many edits land — the older
        # "fresh Doc.new() + ContentType.create + insert" pattern
        # both bloated the SV (one client_id per write) and would
        # silently drop new content if naively switched to a stable id
        # (Yjs identity collision at (cid, clock=0..N)).
        doc =
          case CommitStoreClient.latest_commit(store, entry.node_id) do
            {:ok, commit} ->
              d = Yelixer.Doc.new(client_id: stable_client_id(entry.node_id))
              {:ok, d} = Yelixer.Encoding.apply_update(d, commit.update)
              d

            :none ->
              d = Yelixer.Doc.new(client_id: stable_client_id(entry.node_id))
              ContentType.create(d, :text, change.name)
          end

        old_content = ContentType.get_content(doc) || ""
        doc = Diff.apply_diff(doc, old_content, new_content)

        update = Yelixer.Encoding.encode_update(doc)
        CommitStoreClient.create_chained_commit(store, entry.node_id, update)

      :error ->
        :ok
    end
  end

  defp apply_delete(change, root_uuid, store) do
    root_doc = load_schema(root_uuid, store)
    root_doc = Schema.remove_entry(root_doc, change.name)
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStoreClient.create_chained_commit(store, root_uuid, update)
  end

  defp detect_renames(created, deleted, schema_entries, dir, store, inode_registry) do
    # Only consider non-directory files for rename detection
    created_files = Enum.reject(created, & &1.is_dir)
    deleted_files = Enum.reject(deleted, & &1.is_dir)
    created_dirs = Enum.filter(created, & &1.is_dir)
    deleted_dirs = Enum.filter(deleted, & &1.is_dir)

    # Phase 1: Try inode-based matching (fast, works for empty files and rename+edit)
    {inode_renames, remaining_created_1, used_deleted_1} =
      if inode_registry do
        match_by_inode(created_files, deleted_files, schema_entries, dir, inode_registry)
      else
        {[], created_files, MapSet.new()}
      end

    remaining_deleted_1 = Enum.reject(deleted_files, fn change ->
      MapSet.member?(used_deleted_1, change.name)
    end)

    # Phase 2: Content-based matching on remaining unmatched pairs
    {content_renames, remaining_created_2, used_deleted_2} =
      match_by_content(remaining_created_1, remaining_deleted_1, schema_entries, store)

    remaining_deleted_2 = Enum.reject(remaining_deleted_1, fn change ->
      MapSet.member?(used_deleted_2, change.name)
    end)

    all_renames = inode_renames ++ content_renames

    {all_renames, remaining_created_2 ++ created_dirs,
     remaining_deleted_2 ++ deleted_dirs}
  end

  # Match renames by inode: a created file whose inode is tracked in the registry
  # as belonging to a deleted entry's doc_uuid.
  defp match_by_inode(created_files, deleted_files, schema_entries, _dir, registry) do
    alias Commonplace.Sync.InodeTracker

    # Build lookup: doc_uuid → deleted change name
    deleted_by_uuid = Map.new(deleted_files, fn change ->
      entry = schema_entries[change.name]
      uuid = if entry, do: entry["node_id"]
      {uuid, change}
    end)

    {renames, unmatched, used} =
      Enum.reduce(created_files, {[], [], MapSet.new()}, fn created_change,
                                                            {renames_acc, unmatched_acc, used_acc} ->
        inode_match = try do
          inode_key = InodeTracker.inode_key(created_change.path)
          case InodeTracker.Registry.lookup(registry, inode_key) do
            {:ok, mapping} -> mapping
            :error -> nil
          end
        rescue
          _ -> nil
        end

        del_change = if inode_match, do: Map.get(deleted_by_uuid, inode_match.doc_uuid)

        if del_change && not MapSet.member?(used_acc, del_change.name) do
          entry = schema_entries[del_change.name]
          rename = %Change{
            type: :renamed,
            name: created_change.name,
            path: created_change.path,
            is_dir: false,
            old_name: del_change.name,
            node_id: entry["node_id"]
          }
          {[rename | renames_acc], unmatched_acc, MapSet.put(used_acc, del_change.name)}
        else
          {renames_acc, [created_change | unmatched_acc], used_acc}
        end
      end)

    {Enum.reverse(renames), Enum.reverse(unmatched), used}
  end

  # Match renames by content: a created file whose disk content matches
  # a deleted entry's CRDT content (skips empty files).
  defp match_by_content(created_files, deleted_files, schema_entries, store) do
    deleted_with_content =
      Enum.map(deleted_files, fn change ->
        entry = schema_entries[change.name]
        content = if entry, do: load_content(entry["node_id"], store), else: ""
        {change, content, entry}
      end)

    {renames, unmatched_created, used_deleted} =
      Enum.reduce(created_files, {[], [], MapSet.new()}, fn created_change,
                                                            {renames_acc, unmatched_acc, used_acc} ->
        disk_content = File.read!(created_change.path)

        match =
          Enum.find(deleted_with_content, fn {del_change, del_content, _entry} ->
            del_content == disk_content and
              disk_content != "" and
              not MapSet.member?(used_acc, del_change.name)
          end)

        case match do
          {del_change, _content, entry} ->
            rename = %Change{
              type: :renamed,
              name: created_change.name,
              path: created_change.path,
              is_dir: false,
              old_name: del_change.name,
              node_id: entry["node_id"]
            }

            {[rename | renames_acc], unmatched_acc, MapSet.put(used_acc, del_change.name)}

          nil ->
            {renames_acc, [created_change | unmatched_acc], used_acc}
        end
      end)

    {Enum.reverse(renames), Enum.reverse(unmatched_created), used_deleted}
  end

  defp apply_rename(change, root_uuid, store) do
    # Remove old entry, add new entry pointing to the same document UUID
    root_doc = load_schema(root_uuid, store)
    root_doc = Schema.remove_entry(root_doc, change.old_name)
    root_doc = Schema.add_file(root_doc, change.name, change.node_id)
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStoreClient.create_chained_commit(store, root_uuid, update)
  end

  defp load_schema(uuid, store) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end

  defp load_content(uuid, store) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Yelixer.Doc.new()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)

        case ContentType.get_type(doc) do
          :text -> ContentType.get_content(doc) || ""
          _ -> ""
        end

      :none ->
        ""
    end
  end

  # CX-pyi: stable client_id for writers — repeated load+mutate cycles
  # share one slot in the state vector. Reading paths use plain
  # Doc.new() because they never re-encode (no bloat possible).
  defp stable_client_id(uuid) when is_binary(uuid) do
    :erlang.phash2(uuid, 0xFFFF_FFFF)
  end
end
