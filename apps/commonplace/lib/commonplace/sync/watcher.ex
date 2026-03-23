defmodule Commonplace.Sync.Watcher do
  @moduledoc """
  Filesystem watcher — detects changes on disk and syncs them into CRDT documents.

  Phase 2 of filesystem sync. Compares the current state of files on disk
  with the schema tree and CRDT document contents, producing a list of
  changes that need to be synced.
  """

  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore

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
  def detect_changes(root_uuid, dir, store \\ CommitStore) do
    schema_doc = load_schema(root_uuid, store)
    schema_entries = Schema.entries(schema_doc)

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

    # Detect renames: deleted file whose content matches a created file
    {renames, remaining_created, remaining_deleted} =
      detect_renames(created, deleted, schema_entries, store)

    remaining_created ++ remaining_deleted ++ modified ++ renames
  end

  @doc """
  Recursively detect and apply changes for a directory tree.

  Syncs the root directory, then recurses into subdirectories.
  """
  def sync_recursive(root_uuid, dir, store \\ CommitStore) do
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
  def apply_changes(changes, root_uuid, _dir, store \\ CommitStore) do
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
    CommitStore.create_commit(store, sub_uuid, update, nil)

    # Add to parent schema
    root_doc = load_schema(root_uuid, store)
    root_doc = Schema.add_directory(root_doc, change.name, sub_uuid)
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store, root_uuid, update, nil)
  end

  defp apply_create(%Change{is_dir: false} = change, root_uuid, store) do
    content = File.read!(change.path)

    # Create document with envelope
    file_uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, change.name)

    doc =
      if content != "" do
        ContentType.insert_text(doc, 0, content)
      else
        doc
      end

    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, file_uuid, update, nil)

    # Add to parent schema
    root_doc = load_schema(root_uuid, store)
    root_doc = Schema.add_file(root_doc, change.name, file_uuid)
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store, root_uuid, update, nil)
  end

  defp apply_modify(change, root_uuid, store) do
    root_doc = load_schema(root_uuid, store)

    case Schema.get_entry(root_doc, change.name) do
      {:ok, entry} ->
        new_content = File.read!(change.path)

        # Replace the document content entirely
        doc = Yelixer.Doc.new()
        doc = ContentType.create(doc, :text, change.name)

        doc =
          if new_content != "" do
            ContentType.insert_text(doc, 0, new_content)
          else
            doc
          end

        update = Yelixer.Encoding.encode_update(doc)
        CommitStore.create_commit(store, entry.node_id, update, nil)

      :error ->
        :ok
    end
  end

  defp apply_delete(change, root_uuid, store) do
    root_doc = load_schema(root_uuid, store)
    root_doc = Schema.remove_entry(root_doc, change.name)
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store, root_uuid, update, nil)
  end

  defp detect_renames(created, deleted, schema_entries, store) do
    # Only consider non-directory files for rename detection
    created_files = Enum.reject(created, & &1.is_dir)
    deleted_files = Enum.reject(deleted, & &1.is_dir)
    created_dirs = Enum.filter(created, & &1.is_dir)
    deleted_dirs = Enum.filter(deleted, & &1.is_dir)

    # Build content map for deleted files
    deleted_with_content =
      Enum.map(deleted_files, fn change ->
        entry = schema_entries[change.name]
        content = if entry, do: load_content(entry["node_id"], store), else: ""
        {change, content, entry}
      end)

    # Match created files against deleted file contents
    {renames, unmatched_created, used_deleted} =
      Enum.reduce(created_files, {[], [], MapSet.new()}, fn created_change,
                                                            {renames_acc, unmatched_acc, used_acc} ->
        disk_content = File.read!(created_change.path)

        # Find a matching deleted file (same content, not yet matched)
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

    # Remaining deleted files that weren't matched to renames
    remaining_deleted =
      Enum.reject(deleted_files, fn change ->
        MapSet.member?(used_deleted, change.name)
      end)

    {Enum.reverse(renames), Enum.reverse(unmatched_created) ++ created_dirs,
     remaining_deleted ++ deleted_dirs}
  end

  defp apply_rename(change, root_uuid, store) do
    # Remove old entry, add new entry pointing to the same document UUID
    root_doc = load_schema(root_uuid, store)
    root_doc = Schema.remove_entry(root_doc, change.old_name)
    root_doc = Schema.add_file(root_doc, change.name, change.node_id)
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store, root_uuid, update, nil)
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

  defp load_content(uuid, store) do
    case CommitStore.latest_commit(store, uuid) do
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
end
