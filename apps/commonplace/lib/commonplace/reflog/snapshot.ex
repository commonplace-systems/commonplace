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

  # CX-71ej: per-reflog-dir idempotency cursor. ETS keyed by reflog_dir_uuid
  # (unique per (root, owner, path) by construction). Holds the schema_cid +
  # entry CIDs + last reflog_commit_id we saw — when nothing has changed, we
  # short-circuit without writing the per-dir reflog schema or snapshot doc.
  # Eliminates ~2k unnecessary create_chained_commit calls per checkpoint on
  # a 1000-dir tree (CX-0nkq queue contention).
  @cursor_table :reflog_checkpoint_cursor

  @doc """
  Reset the per-reflog-dir cursor cache. Tests use this between
  checkpoint/3 invocations to start from a known cold state.
  """
  def clear_cursor do
    ensure_cursor_table()
    :ets.delete_all_objects(@cursor_table)
    :ok
  end

  @doc """
  Create a checkpoint snapshot of the entire tree.

  Walks bottom-up from the root, recording commit_ids for all files
  and child reflog commit_ids for all directories. Returns the root
  reflog commit_id.
  """
  def checkpoint(root_uuid, store \\ CommitStoreClient, owner \\ @default_owner) do
    ensure_cursor_table()

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
    ensure_cursor_table()

    # Load the data directory's schema
    data_schema = load_schema(data_dir_uuid, store)
    entries = Schema.list_entries(data_schema)
              |> Enum.reject(&String.starts_with?(&1.name, "__"))

    # Get the data dir's own schema commit_id
    schema_cid_hex =
      case CommitStoreClient.latest_commit(store, data_dir_uuid) do
        {:ok, commit} -> Base.encode16(commit.id, case: :lower)
        :none -> nil
      end

    # Load the reflog dir's schema (for tracking child reflog dirs).
    # If the data dir gained no new child dirs since the last checkpoint,
    # this schema is unchanged and we'll skip writing it back.
    reflog_schema = load_schema(reflog_dir_uuid, store)

    # Resolve every entry's CID, recursing into child dirs. Bubbling a child's
    # reflog_cid up here is what lets THIS dir's cursor detect deeper changes:
    # if a leaf moved, the recursive return value differs and our entries map
    # mismatches the cursor → we write a new reflog snapshot.
    {entry_cids, reflog_schema_after, child_dir_added?} =
      Enum.reduce(entries, {%{}, reflog_schema, false}, fn entry, {acc_cids, schema, child_added} ->
        case entry.type do
          :doc ->
            case CommitStoreClient.latest_commit(store, entry.node_id) do
              {:ok, commit} ->
                hex = Base.encode16(commit.id, case: :lower)
                {Map.put(acc_cids, entry.name, hex), schema, child_added}

              :none ->
                {acc_cids, schema, child_added}
            end

          :dir ->
            # Ensure child reflog dir exists. The "missing" branch only fires
            # on a first-touch dir — and only when the parent data dir gained
            # a new child dir since the last cursor write, which means the
            # parent's schema_cid_hex also moved → cursor miss → safe to write.
            {child_reflog_uuid, schema, this_added?} =
              case Schema.get_entry(schema, entry.name) do
                {:ok, child_entry} ->
                  {child_entry.node_id, schema, false}

                :error ->
                  uuid = UUID.uuid4()
                  child_schema = Schema.new_schema()
                  update = Yelixer.Encoding.encode_update(child_schema)
                  CommitStoreClient.create_chained_commit(store, uuid, update)
                  schema = Schema.add_directory(schema, entry.name, uuid)
                  {uuid, schema, true}
              end

            case snapshot_dir(entry.node_id, child_reflog_uuid, store) do
              {:ok, child_reflog_cid} ->
                hex = Base.encode16(child_reflog_cid, case: :lower)
                {Map.put(acc_cids, entry.name, hex), schema, child_added or this_added?}

              _ ->
                {acc_cids, schema, child_added or this_added?}
            end
        end
      end)

    case lookup_cursor(reflog_dir_uuid) do
      %{schema_cid: ^schema_cid_hex, entries: ^entry_cids, reflog_commit_id: cached_cid}
      when not child_dir_added? ->
        # Cursor hit — schema CID and every entry CID match, and we didn't
        # mint any new child reflog dirs this round. Skip both writes.
        {:ok, cached_cid}

      _ ->
        # Cursor miss — build and write the reflog snapshot doc + schema.
        reflog_doc = build_reflog_doc(schema_cid_hex, entry_cids)

        schema_update = Yelixer.Encoding.encode_update(reflog_schema_after)
        CommitStoreClient.create_chained_commit(store, reflog_dir_uuid, schema_update)

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

        store_cursor(reflog_dir_uuid, %{
          schema_cid: schema_cid_hex,
          entries: entry_cids,
          reflog_commit_id: commit.id
        })

        {:ok, commit.id}
    end
  end

  defp build_reflog_doc(schema_cid_hex, entry_cids) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :map, "reflog_snapshot")

    doc =
      if schema_cid_hex do
        ContentType.set_key(doc, "__schema_cid", schema_cid_hex)
      else
        doc
      end

    doc =
      ContentType.set_key(
        doc,
        "__timestamp",
        DateTime.utc_now() |> DateTime.to_iso8601()
      )

    Enum.reduce(entry_cids, doc, fn {name, hex}, acc ->
      ContentType.set_key(acc, name, hex)
    end)
  end

  defp ensure_cursor_table do
    case :ets.whereis(@cursor_table) do
      :undefined ->
        :ets.new(@cursor_table, [:named_table, :public, :set, read_concurrency: true])

      _tid ->
        @cursor_table
    end
  end

  defp lookup_cursor(reflog_dir_uuid) do
    case :ets.lookup(@cursor_table, reflog_dir_uuid) do
      [{^reflog_dir_uuid, value}] -> value
      [] -> nil
    end
  end

  defp store_cursor(reflog_dir_uuid, value) do
    :ets.insert(@cursor_table, {reflog_dir_uuid, value})
    :ok
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
