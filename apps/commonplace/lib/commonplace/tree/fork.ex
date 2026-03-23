defmodule Commonplace.Tree.Fork do
  @moduledoc """
  Deep-copy a directory subtree with new UUIDs.

  Walks the schema tree recursively, creating new UUIDs for every
  document and directory. Tracks the mapping via ForkManifest.
  Filters __processes.json entries for fork safety.
  """

  alias Commonplace.Tree.{Schema, ForkManifest}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Process.Config
  alias Commonplace.Document.ContentType

  @doc """
  Fork a directory subtree, creating new UUIDs for all documents.

  Returns `{new_root_uuid, manifest}`.
  """
  def fork_directory(source_uuid, store \\ CommitStore) do
    manifest = ForkManifest.new(source_uuid)
    {new_uuid, manifest} = fork_node(source_uuid, store, manifest)
    {new_uuid, manifest}
  end

  # Fork a single node (directory or document).
  # For directories: create new schema with forked children.
  # For documents: create new UUID pointing to the same commit.
  defp fork_node(source_uuid, store, manifest) do
    case CommitStore.latest_commit(store, source_uuid) do
      {:ok, commit} ->
        # Check if this is a schema (directory) by trying to parse entries
        schema_doc = Schema.new_schema()

        case Yelixer.Encoding.apply_update(schema_doc, commit.update) do
          {:ok, schema_doc} ->
            entries = Schema.list_entries(schema_doc)

            if length(entries) > 0 do
              # It's a directory — fork all children and rebuild schema
              fork_directory_node(source_uuid, entries, store, manifest, commit)
            else
              # Leaf document — create new UUID with same content
              fork_leaf_node(source_uuid, store, manifest, commit)
            end

          _ ->
            # Can't parse as schema — treat as leaf
            fork_leaf_node(source_uuid, store, manifest, commit)
        end

      :none ->
        # No commits — create empty
        new_uuid = UUID.uuid4()
        {new_uuid, manifest}
    end
  end

  # Fork a directory node: create new UUIDs for all children, rebuild schema.
  defp fork_directory_node(source_uuid, entries, store, manifest, commit) do
    new_uuid = UUID.uuid4()
    manifest = ForkManifest.add_entry(manifest, new_uuid, source_uuid, commit.id)

    # Fork all children and build new schema
    {new_schema, manifest} =
      Enum.reduce(entries, {Schema.new_schema(), manifest}, fn entry, {doc, man} ->
        {new_child_uuid, man} = fork_node(entry.node_id, store, man)

        doc =
          case entry.type do
            :dir -> Schema.add_directory(doc, entry.name, new_child_uuid)
            :doc -> Schema.add_file(doc, entry.name, new_child_uuid)
            _ -> Schema.add_file(doc, entry.name, new_child_uuid)
          end

        {doc, man}
      end)

    # Filter __processes.json if present
    new_schema = maybe_filter_processes(new_schema, entries, store)

    # Write the new schema
    update = Yelixer.Encoding.encode_update(new_schema)
    CommitStore.create_commit(store, new_uuid, update, nil)

    {new_uuid, manifest}
  end

  # Fork a leaf document: create new UUID pointing to same content.
  defp fork_leaf_node(source_uuid, store, manifest, commit) do
    new_uuid = UUID.uuid4()
    CommitStore.create_commit(store, new_uuid, commit.update, nil)
    manifest = ForkManifest.add_entry(manifest, new_uuid, source_uuid, commit.id)
    {new_uuid, manifest}
  end

  # If the schema contains a __processes.json, filter it for fork safety.
  defp maybe_filter_processes(schema_doc, entries, store) do
    proc_entry = Enum.find(entries, &(&1.name == "__processes.json"))

    if proc_entry do
      case CommitStore.latest_commit(store, proc_entry.node_id) do
        {:ok, commit} ->
          doc = Yelixer.Doc.new()

          case Yelixer.Encoding.apply_update(doc, commit.update) do
            {:ok, doc} ->
              content = ContentType.get_content(doc) || "{}"

              case Jason.decode(content) do
                {:ok, json} when is_map(json) ->
                  filtered = Config.filter_json_for_fork(json)

                  if map_size(filtered) < map_size(json) do
                    case Schema.get_entry(schema_doc, "__processes.json") do
                      {:ok, new_proc_entry} ->
                        new_doc = Yelixer.Doc.new()
                        new_doc = ContentType.create(new_doc, :text, "__processes.json")
                        filtered_json = Jason.encode!(filtered)

                        new_doc =
                          if filtered_json != "" do
                            ContentType.insert_text(new_doc, 0, filtered_json)
                          else
                            new_doc
                          end

                        update = Yelixer.Encoding.encode_update(new_doc)
                        CommitStore.create_commit(store, new_proc_entry.node_id, update, nil)
                        schema_doc

                      _ ->
                        schema_doc
                    end
                  else
                    schema_doc
                  end

                _ ->
                  schema_doc
              end

            _ ->
              schema_doc
          end

        _ ->
          schema_doc
      end
    else
      schema_doc
    end
  end
end
