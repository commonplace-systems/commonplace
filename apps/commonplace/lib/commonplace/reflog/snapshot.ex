defmodule Commonplace.Reflog.Snapshot do
  @moduledoc """
  Recursive checkpoint snapshots of the document tree — a git-reflog-style
  record of "what was every doc's head commit at time T."

  ## What a checkpoint is, and why

  A checkpoint walks the data tree and records the latest `commit_id` of
  every file and directory into a *parallel* reflog tree — one whose shape
  mirrors the data tree — rooted at `__reflog/{owner}/…`. For each data
  directory there is a matching reflog directory holding a `__snapshot`
  doc: a `name → commit_id` map where files map to their own commit_id and
  child directories map to *that child directory's own reflog commit_id*. Because each directory's reflog commit folds
  in its children's, the single root reflog commit_id transitively pins
  the entire tree's state: one handle from which the whole "what every doc
  pointed at" snapshot can be recovered. (`__`-prefixed entries — the
  reflog itself, `__snapshot`, `__bursar.log`, … — are meta-docs and are
  skipped by the walk.)

  Checkpoints are written by `Commonplace.Sync.Agent` after each sync (for
  crash-durability of the synced tree) and periodically by
  `Commonplace.Reflog.CheckpointTimer`.

  ## The cost problem and the two-layer amortization

  A naive checkpoint re-reads and re-writes the *entire* tree every time —
  on a 1000-directory tree that is ~2k `create_chained_commit` calls, and
  the sync loop fires every second. That floods the `CommitStore` mailbox.
  Two independent ETS-backed short-circuits cut the two different costs;
  this module IS the "change-aware cursor" that `Sync.Agent`'s rate-limit
  comment names as the proper follow-up:

    * **Idempotency cursor (CX-71ej)** — cuts WRITES. Per reflog directory
      (`@cursor_table`) we remember `{schema_cid, entry CIDs, last
      reflog_commit_id}`. If the data dir's schema commit and every
      entry's commit_id still match the cursor *and* we minted no new
      child reflog dir this round, both writes (the reflog schema and the
      snapshot doc) are skipped and the cached commit_id is returned.

    * **Dirty-set (CX-o8tx)** — cuts READS. A telemetry handler on
      `[:commonplace, :commit, :create]` (`handle_commit_event/4` →
      `mark_dirty/1`) marks each committed doc dirty and propagates the
      mark *up* to every known ancestor through a lazily-built
      `@parent_index` (child_uuid → set of parent dir uuids). A directory
      absent from `@dirty_table` therefore means no commit landed on it or
      any descendant since the last checkpoint, so the whole subtree is
      skipped without even reading below it.

  The cursor alone still has to *read* a clean dir's CIDs to discover it's
  unchanged; the dirty-set is what lets a clean subtree avoid that read
  entirely. Together, an unchanged tree costs almost nothing.

  ## Two correctness properties worth knowing

    * **Change bubbles up.** Each directory's reflog commit_id is derived
      recursively from its children's returned commit_ids. A single leaf
      edit therefore changes the commit_id all the way up the path to the
      root: every ancestor's cursor mismatches and writes a fresh
      snapshot — but *only* along the changed path, nowhere else.

    * **Dirty bit cleared before work, not after.** `do_snapshot_dir`
      clears a directory's dirty bit *before* walking it, so a commit that
      lands mid-walk re-marks the dir and triggers a re-checkpoint next
      round. Clearing after the work would lose a concurrently-set mark.
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

  # CX-o8tx: amortization state — fed by telemetry on commit creates so
  # only changed subtrees are walked at checkpoint time.
  #
  # @parent_index_table maps child_uuid → MapSet of data_dir_uuids that
  # currently list it as an entry. Populated lazily during walks. Read by
  # mark_dirty/1 to propagate dirtiness up to ancestors.
  #
  # @dirty_table holds {data_dir_uuid, true} entries marked by mark_dirty/1.
  # snapshot_dir consults it to decide whether to short-circuit a clean
  # subtree.
  @parent_index_table :reflog_parent_index
  @dirty_table :reflog_dirty_set

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
  Reset the amortization-state ETS tables (parent_index + dirty_set).
  Tests call this to start from cold-start semantics.
  """
  def clear_amortization_state do
    ensure_parent_index_table()
    ensure_dirty_table()
    :ets.delete_all_objects(@parent_index_table)
    :ets.delete_all_objects(@dirty_table)
    :ok
  end

  @doc """
  Reset only the dirty bits. Used between warm-up and the measured
  checkpoint in tests so accumulated setup-time dirty bits don't pollute
  the measurement.
  """
  def clear_dirty_set do
    ensure_dirty_table()
    :ets.delete_all_objects(@dirty_table)
    :ok
  end

  @doc """
  Mark a doc_uuid as dirty for the next checkpoint, propagating dirtiness
  up to all known ancestors via the parent_index. Called from a telemetry
  handler attached to [:commonplace, :commit, :create] (see
  handle_commit_event/4).
  """
  def mark_dirty(uuid) when is_binary(uuid) do
    ensure_parent_index_table()
    ensure_dirty_table()
    propagate_dirty([uuid], MapSet.new())
    :ok
  end

  defp propagate_dirty([], _seen), do: :ok

  defp propagate_dirty([uuid | rest], seen) do
    if MapSet.member?(seen, uuid) do
      propagate_dirty(rest, seen)
    else
      :ets.insert(@dirty_table, {uuid, true})
      seen = MapSet.put(seen, uuid)

      parents =
        case :ets.lookup(@parent_index_table, uuid) do
          [{^uuid, set}] -> MapSet.to_list(set)
          [] -> []
        end

      propagate_dirty(parents ++ rest, seen)
    end
  end

  @doc """
  Telemetry handler for [:commonplace, :commit, :create]. Attached at
  Application.start so every commit on the local CommitStore feeds the
  dirty-set. Inline marking is cheap (parent chains are typically <10
  deep); if profiles ever show a hot spot, route through a GenServer.cast
  to a DirtyTracker.
  """
  def handle_commit_event(_event_name, _measurements, %{doc_uuid: doc_uuid}, _config)
      when is_binary(doc_uuid) do
    mark_dirty(doc_uuid)
  end

  def handle_commit_event(_event_name, _measurements, _metadata, _config), do: :ok

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
    ensure_parent_index_table()
    ensure_dirty_table()

    # CX-o8tx amortization fast-path: if this data_dir is NOT marked dirty
    # AND we have a cursor that mirrors it, return the cached
    # reflog_commit_id without reading anything below.
    #
    # The dirty bit is set by mark_dirty/1 (driven by commit telemetry) and
    # propagates up through parent_index, so a clean subtree means: no
    # commit landed on this dir or any of its descendants since last
    # checkpoint. Writes were already short-circuited by CX-71ej; this cuts
    # the reads as well.
    case fast_path_lookup(data_dir_uuid, reflog_dir_uuid) do
      {:hit, cached_cid} ->
        {:ok, cached_cid}

      :miss ->
        do_snapshot_dir(data_dir_uuid, reflog_dir_uuid, store)
    end
  end

  defp fast_path_lookup(data_dir_uuid, reflog_dir_uuid) do
    cond do
      :ets.member(@dirty_table, data_dir_uuid) ->
        :miss

      true ->
        case lookup_cursor(reflog_dir_uuid) do
          %{data_dir_uuid: ^data_dir_uuid, reflog_commit_id: cached_cid} ->
            {:hit, cached_cid}

          _ ->
            :miss
        end
    end
  end

  defp do_snapshot_dir(data_dir_uuid, reflog_dir_uuid, store) do
    # Clear the dirty bit BEFORE doing the work. Any commit landing on this
    # dir or a descendant during our walk will re-mark it dirty and trigger
    # a re-checkpoint next round; clearing first avoids the alternate race
    # where we clear AFTER work and lose a concurrent dirty mark.
    :ets.delete(@dirty_table, data_dir_uuid)

    # Load the data directory's schema
    data_schema = load_schema(data_dir_uuid, store)
    entries = Schema.list_entries(data_schema)
              |> Enum.reject(&String.starts_with?(&1.name, "__"))

    # CX-o8tx: keep parent_index current so future commit telemetry can
    # propagate dirtiness through this dir.
    populate_parent_index(data_dir_uuid, entries)

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
          data_dir_uuid: data_dir_uuid,
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

  defp ensure_parent_index_table do
    case :ets.whereis(@parent_index_table) do
      :undefined ->
        :ets.new(@parent_index_table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _tid ->
        @parent_index_table
    end
  end

  defp ensure_dirty_table do
    case :ets.whereis(@dirty_table) do
      :undefined ->
        :ets.new(@dirty_table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _tid ->
        @dirty_table
    end
  end

  defp populate_parent_index(parent_data_dir_uuid, entries) do
    Enum.each(entries, fn entry ->
      existing =
        case :ets.lookup(@parent_index_table, entry.node_id) do
          [{_, set}] -> set
          [] -> MapSet.new()
        end

      :ets.insert(
        @parent_index_table,
        {entry.node_id, MapSet.put(existing, parent_data_dir_uuid)}
      )
    end)
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
