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
    defstruct [:type, :name, :path, :is_dir]

    @type t :: %__MODULE__{
            type: :created | :modified | :deleted,
            name: String.t(),
            path: String.t(),
            is_dir: boolean()
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

    # Get files/dirs on disk
    disk_entries =
      case File.ls(dir) do
        {:ok, names} -> MapSet.new(names)
        {:error, _} -> MapSet.new()
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

    created ++ deleted ++ modified
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
