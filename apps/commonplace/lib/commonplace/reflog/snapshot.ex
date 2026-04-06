defmodule Commonplace.Reflog.Snapshot do
  @moduledoc """
  Recursive checkpoint snapshots of the document tree.

  Walks the data tree bottom-up, creating reflog entries that record
  the commit_id of every file and child directory at checkpoint time.
  The root reflog commit unambiguously captures the entire tree state.
  """

  alias Commonplace.Tree.{Schema, DocBuilder}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Document.ContentType

  require Logger

  @reflog_branch "__reflog"
  @default_owner "server"

  @doc """
  Create a checkpoint snapshot of the entire tree.

  Walks bottom-up from the root, recording commit_ids for all files
  and child reflog commit_ids for all directories. Returns the root
  reflog commit_id.
  """
  def checkpoint(root_uuid, store \\ CommitStoreClient, owner \\ @default_owner) do
    # Ensure __reflog branch exists
    {:ok, reflog_root} = ensure_reflog_branch(root_uuid, owner, store)

    # Walk the data tree and create reflog entries recursively
    {:ok, reflog_commit_id} = snapshot_dir(root_uuid, reflog_root, store)

    Logger.info(
      "Reflog checkpoint: #{Base.encode16(reflog_commit_id, case: :lower) |> binary_part(0, 12)}..."
    )

    {:ok, reflog_commit_id}
  end

  @doc """
  Snapshot a single directory, recursing into children.

  Returns {:ok, reflog_commit_id} — the commit_id of this dir's reflog entry.
  """
  def snapshot_dir(data_dir_uuid, reflog_dir_uuid, store) do
    # Load the data directory's schema
    data_schema = load_schema(data_dir_uuid, store)
    entries = Schema.list_entries(data_schema)

    # Get the data dir's own schema commit_id
    schema_cid =
      case CommitStoreClient.latest_commit(store, data_dir_uuid) do
        {:ok, commit} -> commit.id
        :none -> nil
      end

    # Load the reflog dir's schema (for tracking child reflog dirs)
    reflog_schema = load_schema(reflog_dir_uuid, store)

    # Build the snapshot document
    reflog_doc = Yelixer.Doc.new()
    reflog_doc = ContentType.create(reflog_doc, :map, "reflog_snapshot")

    # Record schema CID
    reflog_doc =
      if schema_cid do
        ContentType.set_key(
          reflog_doc,
          "__schema_cid",
          Base.encode16(schema_cid, case: :lower)
        )
      else
        reflog_doc
      end

    # Record timestamp
    reflog_doc =
      ContentType.set_key(
        reflog_doc,
        "__timestamp",
        DateTime.utc_now() |> DateTime.to_iso8601()
      )

    # Process each entry
    {reflog_doc, reflog_schema} =
      Enum.reduce(entries, {reflog_doc, reflog_schema}, fn entry, {doc, schema} ->
        case entry.type do
          :doc ->
            # Record the file's latest commit_id
            case CommitStoreClient.latest_commit(store, entry.node_id) do
              {:ok, commit} ->
                doc =
                  ContentType.set_key(
                    doc,
                    entry.name,
                    Base.encode16(commit.id, case: :lower)
                  )

                {doc, schema}

              :none ->
                {doc, schema}
            end

          :dir ->
            # Ensure child reflog dir exists
            {child_reflog_uuid, schema} =
              case Schema.get_entry(schema, entry.name) do
                {:ok, child_entry} ->
                  {child_entry.node_id, schema}

                :error ->
                  uuid = UUID.uuid4()
                  child_schema = Schema.new_schema()
                  update = Yelixer.Encoding.encode_update(child_schema)
                  CommitStoreClient.create_chained_commit(store, uuid, update)
                  schema = Schema.add_directory(schema, entry.name, uuid)
                  {uuid, schema}
              end

            # Recurse: snapshot the child directory
            case snapshot_dir(entry.node_id, child_reflog_uuid, store) do
              {:ok, child_reflog_cid} ->
                doc =
                  ContentType.set_key(
                    doc,
                    entry.name,
                    Base.encode16(child_reflog_cid, case: :lower)
                  )

                {doc, schema}

              _ ->
                {doc, schema}
            end
        end
      end)

    # Commit the reflog schema if it changed
    schema_update = Yelixer.Encoding.encode_update(reflog_schema)
    CommitStoreClient.create_chained_commit(store, reflog_dir_uuid, schema_update)

    # Find or create the snapshot document UUID
    snapshot_uuid =
      case get_snapshot_doc_uuid(reflog_dir_uuid, store) do
        {:ok, uuid} ->
          uuid

        :none ->
          uuid = UUID.uuid4()
          # Reload reflog dir schema (we just committed an update above)
          updated_schema = load_schema(reflog_dir_uuid, store)
          updated_schema = Schema.add_file(updated_schema, "__snapshot", uuid)
          update = Yelixer.Encoding.encode_update(updated_schema)
          CommitStoreClient.create_chained_commit(store, reflog_dir_uuid, update)
          uuid
      end

    update = Yelixer.Encoding.encode_update(reflog_doc)
    commit = CommitStoreClient.create_chained_commit(store, snapshot_uuid, update)

    {:ok, commit.id}
  end

  @doc "Ensure the __reflog branch and owner subdirectory exist."
  def ensure_reflog_branch(root_uuid, owner, store) do
    root_schema = load_schema(root_uuid, store)

    # Ensure __reflog dir exists
    reflog_dir_uuid =
      case Schema.get_entry(root_schema, @reflog_branch) do
        {:ok, entry} ->
          entry.node_id

        :error ->
          uuid = UUID.uuid4()
          dir_schema = Schema.new_schema()
          update = Yelixer.Encoding.encode_update(dir_schema)
          CommitStoreClient.create_chained_commit(store, uuid, update)

          # Reload root schema (latest) and add the entry
          root_schema = load_schema(root_uuid, store)
          root_schema = Schema.add_directory(root_schema, @reflog_branch, uuid)
          update = Yelixer.Encoding.encode_update(root_schema)
          CommitStoreClient.create_chained_commit(store, root_uuid, update)
          uuid
      end

    # Ensure owner subdir exists
    reflog_schema = load_schema(reflog_dir_uuid, store)

    owner_uuid =
      case Schema.get_entry(reflog_schema, owner) do
        {:ok, entry} ->
          entry.node_id

        :error ->
          uuid = UUID.uuid4()
          owner_schema = Schema.new_schema()
          update = Yelixer.Encoding.encode_update(owner_schema)
          CommitStoreClient.create_chained_commit(store, uuid, update)

          reflog_schema = load_schema(reflog_dir_uuid, store)
          reflog_schema = Schema.add_directory(reflog_schema, owner, uuid)
          update = Yelixer.Encoding.encode_update(reflog_schema)
          CommitStoreClient.create_chained_commit(store, reflog_dir_uuid, update)
          uuid
      end

    {:ok, owner_uuid}
  end

  @doc "Read a reflog snapshot and return the file->commit_id map."
  def read_snapshot(snapshot_uuid, store \\ CommitStoreClient) do
    case DocBuilder.reconstruct_snapshot(store, snapshot_uuid) do
      {:ok, doc} -> ContentType.get_content(doc)
      :none -> nil
    end
  end

  defp load_schema(uuid, store) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end

  defp get_snapshot_doc_uuid(reflog_dir_uuid, store) do
    schema = load_schema(reflog_dir_uuid, store)

    case Schema.get_entry(schema, "__snapshot") do
      {:ok, entry} -> {:ok, entry.node_id}
      :error -> :none
    end
  end
end
