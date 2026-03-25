defmodule Commonplace.Tree.Fork do
  @moduledoc """
  Fork a directory subtree using DAG branches.

  Creates new UUIDs that branch off existing commit chains.
  Schema edit commits remap child node_ids to the new UUIDs.
  Leaf docs get branch-point commits (same content, new UUID).
  No ForkManifest — provenance is in the shared commit DAG.
  """

  alias Commonplace.Tree.{Schema, DocBuilder}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Process.Config
  alias Commonplace.Document.ContentType
  alias Yelixer.{Doc, Encoding}

  @doc """
  Fork a directory subtree using DAG branches.
  Returns the new root UUID.
  """
  def fork_directory(source_uuid, store \\ CommitStoreClient) do
    {new_uuid, _uuid_map} = fork_node(source_uuid, store, %{})
    new_uuid
  end

  # Fork a node, returning {new_uuid, uuid_map} where uuid_map tracks
  # source_uuid => new_uuid for all forked docs (used for schema remapping).
  defp fork_node(source_uuid, store, uuid_map) do
    case CommitStoreClient.latest_commit(store, source_uuid) do
      {:ok, commit} ->
        schema_doc = Schema.new_schema()

        case Encoding.apply_update(schema_doc, commit.update) do
          {:ok, schema_doc} ->
            entries = Schema.list_entries(schema_doc)

            if length(entries) > 0 do
              fork_directory_node(source_uuid, entries, store, uuid_map, commit)
            else
              fork_leaf_node(source_uuid, store, uuid_map, commit)
            end

          _ ->
            fork_leaf_node(source_uuid, store, uuid_map, commit)
        end

      :none ->
        new_uuid = UUID.uuid4()
        {new_uuid, Map.put(uuid_map, source_uuid, new_uuid)}
    end
  end

  defp fork_directory_node(source_uuid, entries, store, uuid_map, commit) do
    new_uuid = UUID.uuid4()
    uuid_map = Map.put(uuid_map, source_uuid, new_uuid)

    # Fork all children first to build the uuid_map
    {uuid_map, _} =
      Enum.reduce(entries, {uuid_map, []}, fn entry, {map, _} ->
        {_child_uuid, map} = fork_node(entry.node_id, store, map)
        {map, []}
      end)

    # Reconstruct source schema and remap node_ids
    case reconstruct_doc(store, source_uuid) do
      {:ok, source_doc} ->
        edited_doc =
          Enum.reduce(entries, source_doc, fn entry, doc ->
            new_child_uuid = Map.fetch!(uuid_map, entry.node_id)
            doc = Schema.remove_entry(doc, entry.name)

            case entry.type do
              :dir -> Schema.add_directory(doc, entry.name, new_child_uuid)
              _ -> Schema.add_file(doc, entry.name, new_child_uuid)
            end
          end)

        # Filter __processes.json if present
        edited_doc = maybe_filter_processes(edited_doc, entries, store, uuid_map)

        # Create the schema edit commit branching off the source's chain
        update = Encoding.encode_update(edited_doc)
        CommitStoreClient.create_commit(store, new_uuid, update, commit.id)

      :none ->
        # Source doc missing — create empty schema commit as branch point
        update = Encoding.encode_update(Schema.new_schema())
        CommitStoreClient.create_commit(store, new_uuid, update, commit.id)
    end

    {new_uuid, uuid_map}
  end

  defp fork_leaf_node(source_uuid, store, uuid_map, commit) do
    new_uuid = UUID.uuid4()
    uuid_map = Map.put(uuid_map, source_uuid, new_uuid)

    # Branch-point commit: same content under new UUID, parent = source's commit
    case reconstruct_doc(store, source_uuid) do
      {:ok, doc} ->
        update = Encoding.encode_update(doc)
        CommitStoreClient.create_commit(store, new_uuid, update, commit.id)

      :none ->
        # Source doc missing — create minimal branch-point commit
        update = Encoding.encode_update(Doc.new())
        CommitStoreClient.create_commit(store, new_uuid, update, commit.id)
    end

    {new_uuid, uuid_map}
  end

  defp reconstruct_doc(store, doc_uuid) do
    DocBuilder.reconstruct_doc(store, doc_uuid)
  end

  defp maybe_filter_processes(schema_doc, entries, store, uuid_map) do
    proc_entry = Enum.find(entries, &(&1.name == "__processes.json"))

    if proc_entry do
      new_proc_uuid = Map.get(uuid_map, proc_entry.node_id)

      case reconstruct_doc(store, proc_entry.node_id) do
        {:ok, proc_doc} ->
          content = ContentType.get_content(proc_doc) || "{}"

          case Jason.decode(content) do
            {:ok, json} when is_map(json) ->
              filtered = Config.filter_json_for_fork(json)

              if map_size(filtered) < map_size(json) and new_proc_uuid do
                case CommitStoreClient.latest_commit(store, new_proc_uuid) do
                  {:ok, branch_commit} ->
                    new_doc = Doc.new()
                    new_doc = ContentType.create(new_doc, :text, "__processes.json")
                    filtered_json = Jason.encode!(filtered)
                    new_doc = if filtered_json != "", do: ContentType.insert_text(new_doc, 0, filtered_json), else: new_doc
                    update = Encoding.encode_update(new_doc)
                    CommitStoreClient.create_commit(store, new_proc_uuid, update, branch_commit.parent_id)

                  :none ->
                    :ok
                end
              end

              schema_doc

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
