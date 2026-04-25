defmodule Commonplace.Sync.Agent do
  @moduledoc """
  Bidirectional sync agent — bridges CRDT documents with files on disk.

  Uses two layers of version tracking:
  - Content hashes: fast "did anything change on disk?" gating
  - Commit ancestry: causal ordering to prevent overwriting remote
    CRDT updates with stale disk content

  Sync cycle:
  1. Outbound (disk → CRDT): detect disk changes, sync to CRDT
  2. Inbound (CRDT → disk): export CRDT docs where latest commit
     is a descendant of (or different from) what we last wrote
  """

  use GenServer

  alias Commonplace.Sync.{Watcher, Export, InodeTracker}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema

  defstruct [
    :root_uuid,
    :sync_dir,
    :store,
    :known_paths,
    :known_hashes,
    # %{doc_uuid => commit_id} — the commit whose content is currently on disk
    :written_commits,
    # InodeTracker.Registry pid (nil if shadow tracking disabled)
    :inode_registry,
    # CX-0nkq: monotonic ms timestamp of last reflog checkpoint. nil
    # means "never" — first sync_once will checkpoint. Subsequent
    # ticks skip the checkpoint until @reflog_checkpoint_min_interval_ms
    # elapses, giving 10x relief on the per-second sync flood while
    # preserving CX-86t2's race-fix property (synchronous-when-fired).
    :last_reflog_checkpoint_ms
  ]

  # Minimum wall-clock gap between back-to-back reflog checkpoints
  # in the same Sync.Agent. SyncLoop ticks at 1s; without this gate
  # we'd burn one full-tree reflog walk per second per agent. The
  # 10s cadence preserves audit cadence while eliminating the
  # contention spam under heavy commit activity (CX-0nkq).
  @reflog_checkpoint_min_interval_ms 10_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Run one sync cycle: outbound (disk → CRDT), then inbound (CRDT → disk)."
  def sync_once(pid) do
    GenServer.call(pid, :sync_once, 30_000)
  end

  @impl true
  def init(opts) do
    inode_registry =
      if Keyword.get(opts, :shadow_tracking, false) do
        {:ok, pid} = InodeTracker.Registry.start_link([])
        pid
      else
        nil
      end

    state = %__MODULE__{
      root_uuid: Keyword.fetch!(opts, :root_uuid),
      sync_dir: Keyword.fetch!(opts, :sync_dir),
      store: Keyword.get(opts, :store, CommitStoreClient),
      known_paths: MapSet.new(),
      known_hashes: %{},
      written_commits: %{},
      inode_registry: inode_registry
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:sync_once, _from, state) do
    state = do_sync(state)
    state = maybe_reflog_checkpoint(state)

    {:reply, :ok, state}
  end

  # CX-86t2: when the reflog checkpoint fires, it runs synchronously
  # inside sync_once. The prior async-via-Task.start implementation
  # raced with concurrent root writers (test code, remote peer, MCP
  # command) — each encoded its own stale view of root, and because
  # reconstruct_snapshot/2 applies only the latest commit, the
  # last-writer-wins dropped the earlier writer's mutation. A flaky
  # test (agent_test.exs:154) surfaced this when the test wrote to
  # root between sync_once returning and the next sync_once's export
  # phase: crdt_file.txt was silently lost from root's schema.
  # Synchronous checkpointing restores the invariant that sync_once
  # returns only once all writes it triggered are fully durable.
  #
  # CX-0nkq: rate-limit at @reflog_checkpoint_min_interval_ms. Without
  # this gate, SyncLoop's 1s tick produces one full-tree reflog walk
  # per second per agent — wasteful and a major contributor to
  # CommitStore mailbox contention during heavy commit activity (e.g.
  # MCP fork on a deep tree timed out at 5s under this pressure).
  # The gate is a wall-clock skip, not an idempotency check; a real
  # skip-when-nothing-changed cursor is the proper fix tracked in
  # CX-0nkq's body.
  defp maybe_reflog_checkpoint(state) do
    now_ms = System.monotonic_time(:millisecond)
    last = state.last_reflog_checkpoint_ms

    if last == nil or now_ms - last >= @reflog_checkpoint_min_interval_ms do
      Commonplace.Reflog.Snapshot.checkpoint(state.root_uuid, state.store, "server")
      %{state | last_reflog_checkpoint_ms: now_ms}
    else
      state
    end
  end

  defp do_sync(state) do
    # Phase 0: Check shadows for stale writes
    if state.inode_registry do
      check_shadows(state)
    end

    # Phase 1: Outbound — disk → CRDT
    sync_outbound_recursive(state.root_uuid, state.sync_dir, state.store, state.known_paths, state.known_hashes, state.inode_registry)

    # Phase 2: Inbound — CRDT → disk, using commit ancestry
    written = export_with_ancestry(state.root_uuid, state.sync_dir, state.store, state.written_commits, state.inode_registry)

    # Phase 3: Update known state from current disk
    {known, hashes} = scan_disk_state(state.sync_dir, "")
    %{state | known_paths: known, known_hashes: hashes, written_commits: written}
  end

  @doc false
  # Export CRDT to disk, tracking which commit IDs we write.
  # Only writes when the latest commit differs from what we last wrote.
  # When registry is provided, creates shadow hardlinks before atomic writes.
  defp export_with_ancestry(root_uuid, dir, store, written_commits, registry) do
    File.mkdir_p!(dir)
    shadow_dir = Path.join(dir, ".commonplace-shadow")
    schema_doc = load_schema(root_uuid, store)

    Schema.list_entries(schema_doc)
    |> Enum.reduce(written_commits, fn entry, written ->
      path = Path.join(dir, entry.name)

      case entry.type do
        :dir ->
          File.mkdir_p!(path)
          sub_schema = load_schema(entry.node_id, store)
          export_entries_with_ancestry(sub_schema, path, store, written, registry)

        :doc ->
          maybe_write_doc(entry, path, store, written, registry, shadow_dir)
      end
    end)
  end

  defp export_entries_with_ancestry(schema_doc, dir, store, written_commits, registry) do
    Schema.list_entries(schema_doc)
    |> Enum.reduce(written_commits, fn entry, written ->
      path = Path.join(dir, entry.name)

      case entry.type do
        :dir ->
          File.mkdir_p!(path)
          sub_schema = load_schema(entry.node_id, store)
          export_entries_with_ancestry(sub_schema, path, store, written, registry)

        :doc ->
          maybe_write_doc(entry, path, store, written, registry, Path.join(dir, ".commonplace-shadow"))
      end
    end)
  end

  defp maybe_write_doc(entry, path, store, written, registry, shadow_dir) do
    case CommitStoreClient.latest_commit(store, entry.node_id) do
      {:ok, commit} ->
        last_written = Map.get(written, entry.node_id)

        cond do
          # Same commit — nothing changed, skip write
          last_written == commit.id ->
            written

          # New or updated — write to disk
          true ->
            content = extract_content(commit)

            if registry do
              InodeTracker.atomic_write_with_shadow(path, content, shadow_dir, registry, commit.id, entry.node_id)
            else
              Export.atomic_write(path, content)
            end

            Map.put(written, entry.node_id, commit.id)
        end

      :none ->
        written
    end
  end

  # Check shadow hardlinks for stale writes and merge them back into CRDT
  defp check_shadows(state) do
    shadows = InodeTracker.Registry.list_shadows(state.inode_registry)

    Enum.each(shadows, fn shadow ->
      fingerprint = shadow.fingerprint
      current_fingerprint = InodeTracker.file_fingerprint(shadow.shadow_path)

      if current_fingerprint != nil and current_fingerprint != fingerprint do
        # Stale write detected — read content and create a commit.
        # CX-pyi: load + mutate against the shadow's commit, applying
        # the disk-content diff under a stable client_id so repeated
        # stale-write recoveries don't bloat the SV.
        stale_content = File.read!(shadow.shadow_path)

        doc =
          case CommitStoreClient.get_commit(state.store, shadow.commit_id) do
            {:ok, commit} ->
              d =
                Yelixer.Doc.new(client_id: stable_client_id(shadow.doc_uuid))

              {:ok, d} = Yelixer.Encoding.apply_update(d, commit.update)
              d

            _ ->
              d =
                Yelixer.Doc.new(client_id: stable_client_id(shadow.doc_uuid))

              Commonplace.Document.ContentType.create(d, :text, Path.basename(shadow.path))
          end

        old_content = Commonplace.Document.ContentType.get_content(doc) || ""

        doc =
          Commonplace.Document.Diff.apply_diff(doc, old_content, stale_content)

        update = Yelixer.Encoding.encode_update(doc)

        # Create commit with the shadow's commit_id as parent
        CommitStoreClient.create_commit(state.store, shadow.doc_uuid, update, shadow.commit_id)

        # Clean up the shadow
        InodeTracker.cleanup_shadow(shadow.shadow_path)
      end
    end)
  end

  # CX-pyi: stable client_id keeps the SV at one slot per doc across
  # writes from this agent's sync paths. Reading paths use plain
  # Doc.new() because they never re-encode (no bloat possible).
  defp stable_client_id(uuid) when is_binary(uuid) do
    :erlang.phash2(uuid, 0xFFFF_FFFF)
  end

  defp extract_content(commit) do
    doc = Yelixer.Doc.new()
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)

    case Commonplace.Document.ContentType.get_type(doc) do
      :text -> Commonplace.Document.ContentType.get_content(doc) || ""
      _ -> Commonplace.Document.ContentType.get_content(doc) |> inspect()
    end
  end

  defp sync_outbound_recursive(root_uuid, dir, store, known_paths, known_hashes, inode_registry) do
    changes = Watcher.detect_changes(root_uuid, dir, store, inode_registry: inode_registry)

    changes =
      Enum.filter(changes, fn change ->
        case change.type do
          :deleted ->
            # Only delete if the path was previously known on disk
            MapSet.member?(known_paths, change.name)

          :modified ->
            # Only apply if disk content actually changed from what we last synced.
            # Content hash is a fast gate — if disk matches what we last saw,
            # the CRDT was updated remotely, let inbound handle it.
            content = Commonplace.Sync.Flock.with_shared_lock(change.path, 30_000, fn ->
              File.read!(change.path)
            end)
            disk_hash = :erlang.md5(content)
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

          sync_outbound_recursive(entry.node_id, sub_dir, store, sub_known, sub_hashes, inode_registry)
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
            case File.read(full) do
              {:ok, content} ->
                hash = :erlang.md5(content)
                {paths, Map.put(hashes, rel, hash)}
              {:error, _} ->
                # File disappeared or is unreadable — skip
                {paths, hashes}
            end
          end
        end)

      {:error, _} ->
        {MapSet.new(), %{}}
    end
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
end
