defmodule Commonplace.Sync.Agent do
  @moduledoc """
  Bidirectional sync agent — keeps a CRDT document tree and a directory
  of files on disk reflecting each other.

  One agent (a `GenServer`) owns one checkout: a `root_uuid` schema tree
  and the `sync_dir` it maps to. Each `sync_once/1` runs a full
  reconciliation in both directions. The hard part is not copying bytes —
  it is determining, per document, *which side is authoritative this
  cycle* so the agent never clobbers a fresh CRDT update (arriving from a
  remote peer, the MCP API, or a merge) with stale disk content it wrote
  itself a moment ago.

  ## Why two layers of version tracking

  - **Content hashes** (`known_hashes`) are the cheap gate: "did this
    file change on disk since we last looked?" A streaming SHA-256 per file answers
    that without reconstructing any CRDT.
  - **Commit identity** (`written_commits`: `doc_uuid => commit_id`) is
    the authority gate: the exact commit whose content is *currently on
    disk*. Inbound export only rewrites a file when the document's latest
    commit differs — so a file already written is never rewritten, and a
    doc advanced remotely is.

  Together they arbitrate direction. Unchanged disk hash → divergence
  came from the CRDT side → **inbound** wins. Changed hash → user edited
  the file → **outbound** carries it into the CRDT. Without the hash gate
  the two phases would fight, each cycle overwriting the other's work.

  ## The sync cycle (`do_sync/1`)

  0. **Shadow check** (optional) — detect writes that landed *between*
     cycles and fold them back in (see "Stale-write detection").
  1. **Outbound** (disk → CRDT) — `Watcher.detect_changes/4` finds disk
     edits/adds/deletes; the hash gate filters out files that only the
     CRDT changed; survivors are applied via `Watcher.apply_changes/4`.
  2. **Inbound** (CRDT → disk) — walk the schema tree and, per the commit
     gate above, atomically write any doc whose latest commit isn't the
     one already on disk.
  3. **Rescan** — re-read disk state into `known_paths` / `known_hashes`
     so the next cycle starts from ground truth.

  ## Cycle consistency & the inbound-clobber guard (CX-60wl)

  Two invariants keep concurrent disk edits from being silently lost:

    * `known_hashes` records only content the agent OBSERVED-AND-RECONCILED
      this cycle — the *pre-outbound* disk snapshot overlaid with the exact
      bytes inbound wrote — never a blind post-outbound rescan (which would
      absorb a mid-cycle write outbound never committed).
    * Inbound (`maybe_write_doc/8`) never overwrites disk content it hasn't
      reconciled: if `disk_hash != known_hashes[rel]` the file holds an
      unreconciled edit, so inbound SKIPS and lets outbound commit it next
      cycle (the CRDT then catches up / merges). This also elides the
      redundant write-back of content outbound just read from disk.

  RESIDUAL (not fully closed): the guard reads `disk_hash` and then writes in
  a separate step, so an edit landing in that read→atomic-write window still
  clobbers. This shrinks the loss window from the original cross-phase (~ms,
  clobbered on *any* concurrent edit) to a μs read→write TOCTOU. Full closure
  requires either shadow-tracking ON (below — it detects the post-write stale
  edit and recommits) or a CAS-style conditional write (write only if disk
  still hashes to what was read). Acceptable at single-writer MUD/dev-sync
  scale; default shadow-tracking ON is tracked as a pre-widening item
  (see CX-60wl).

  ## Stale-write detection (shadow tracking)

  Enabled by `shadow_tracking: true`. When inbound writes a file it also
  hardlinks a *shadow* copy (via `InodeTracker`) tagged with the commit
  it wrote. Phase 0 of the next cycle compares each shadow's fingerprint
  to the live file: a mismatch means the file was modified out-of-band
  after the write but before outbound's snapshot saw it — a write that
  would otherwise be lost. The agent recovers it by diffing the stale
  content against the shadow's commit and committing the delta
  (`check_shadows/1`). This closes the narrow window between one
  `sync_once` returning and the next one scanning — and is the REACTIVE
  backstop that fully closes the inbound-guard's μs TOCTOU residual above.

  **Cleanup (CX-k34x / CX-wrg0).** A shadow entry is retired one of two
  ways: `check_shadows/1` finds it diverged and folds the stale content
  into the CRDT (CX-k34x), or — if a path is overwritten again before it
  ever diverges — `reconcile_superseded_shadow/3` gives it one last
  fingerprint check at write time and evicts it as clean (CX-wrg0). Both
  paths funnel through `evict_shadow/2`, which unlinks the shadow file
  and removes the registry entry. Without the second path, a
  steadily-overwritten file with no stale writers would leak one
  registry entry and one shadow hardlink per write for the life of the
  BEAM.

  ## State-vector hygiene

  Write paths reconstruct docs under a **stable per-doc client id**
  (`stable_client_id/1`, CX-pyi), not a fresh random one. A CRDT's state
  vector grows one slot per distinct client that has ever written; minting
  a new client id on every sync write would bloat the SV without bound.
  Read-only paths use a plain `Yelixer.Doc.new/0` — they never re-encode,
  so they can't bloat anything.

  ## Reflog checkpoint durability

  After each sync, `maybe_reflog_checkpoint/1` writes a recursive reflog
  checkpoint of the tree. Two properties are deliberate:

  - **Synchronous** (CX-86t2): the checkpoint runs *inside* `sync_once`,
    not in a background task. Because snapshot reconstruction applies
    only the latest commit, an async checkpoint encoding a stale view of
    root could race a concurrent root writer and silently drop its
    mutation (last-writer-wins). Running it synchronously upholds the
    contract that `sync_once` returns only once every write it triggered
    is durable.
  - **Rate-limited** (CX-0nkq): `SyncLoop` ticks every second, but a
    full-tree reflog walk per second per agent is wasteful and a major
    source of `CommitStore` mailbox contention. A wall-clock gate
    (`@reflog_checkpoint_min_interval_ms`, 10s) skips redundant
    checkpoints while preserving the synchronous-when-fired property
    above. (A proper change-aware cursor is the tracked follow-up.)

  Procedural mechanics live in their owning modules: `Commonplace.Sync.Watcher`
  (disk-change detection/apply), `Commonplace.Sync.Export` /
  `Commonplace.Sync.InodeTracker` (atomic + shadowed writes), and
  `Commonplace.Reflog.Snapshot` (the checkpoint walk).
  """

  use GenServer

  require Logger

  alias Commonplace.Sync.{Watcher, Export, InodeTracker}
  alias Commonplace.Store.{ArtifactStore, CommitStoreClient}
  alias Commonplace.Sync.{BinaryClassifier, BinaryWriteBack}
  alias Commonplace.Tree.Schema

  defstruct [
    :root_uuid,
    :sync_dir,
    :store,
    :artifact_store,
    :binary_extensions,
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
      artifact_store: Keyword.get(opts, :artifact_store, default_artifact_store()),
      binary_extensions:
        Keyword.get(opts, :binary_extensions, BinaryClassifier.declared_extensions()),
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

    # Snapshot disk BEFORE outbound — the state outbound reconciles against.
    # Using this (not a fresh post-outbound rescan) as the basis for the next
    # cycle's known_hashes is the fix for CX-60wl: a write landing mid-cycle
    # (after outbound's read) is NOT silently absorbed into known_hashes
    # uncommitted — it stays divergent and is re-detected + committed next
    # cycle. known_hashes must record only content this cycle
    # OBSERVED-AND-RECONCILED: the pre-outbound disk snapshot (untouched +
    # uncommitted-write files) overlaid with the exact bytes inbound wrote.
    {_pre_paths, pre_hashes} = scan_disk_state(state.sync_dir, "")

    # Phase 1: Outbound — disk → CRDT
    sync_outbound_recursive(
      state.root_uuid,
      state.sync_dir,
      state.store,
      state.artifact_store,
      state.binary_extensions,
      state.known_paths,
      state.known_hashes,
      state.inode_registry
    )

    # Phase 2: Inbound — CRDT → disk, using commit ancestry. Returns the
    # commit map AND {rel_path => sha256(bytes it wrote)} for the files it wrote
    # this cycle (loop prevention: content just written matches the CRDT, so
    # outbound must not push it back — hashing the EXACT written buffer makes
    # this byte-match by construction, no CRDT-extract-vs-disk risk).
    {written, inbound_hashes} =
      export_with_ancestry(
        state.root_uuid,
        state.sync_dir,
        state.store,
        state.artifact_store,
        state.written_commits,
        state.inode_registry,
        state.known_hashes
      )

    # Phase 3: known_paths from current disk (delete detection is path-based,
    # not part of the hash race); known_hashes = pre-outbound snapshot overlaid
    # with inbound-written hashes.
    {known_paths, _post_hashes} = scan_disk_state(state.sync_dir, "")
    known_hashes = Map.merge(pre_hashes, inbound_hashes)
    %{state | known_paths: known_paths, known_hashes: known_hashes, written_commits: written}
  end

  @doc false
  # Export CRDT to disk, tracking which commit IDs we write AND the on-disk
  # hash of the bytes we wrote (keyed by rel-path, IDENTICAL scheme to
  # `scan_disk_state`, so the `Map.merge` into known_hashes aligns).
  # Only writes when the latest commit differs from what we last wrote.
  # When registry is provided, creates shadow hardlinks before atomic writes.
  # Returns `{written_commits, inbound_hashes}`. `known_hashes` (last cycle's
  # reconciled disk hashes) gates the write so inbound never clobbers an
  # unreconciled disk edit (CX-60wl clobber race).
  defp export_with_ancestry(
         root_uuid,
         dir,
         store,
         artifact_store,
         written_commits,
         registry,
         known_hashes
       ) do
    File.mkdir_p!(dir)
    schema_doc = load_schema(root_uuid, store)

    export_schema(
      schema_doc,
      dir,
      "",
      store,
      artifact_store,
      {written_commits, %{}},
      registry,
      known_hashes
    )
  end

  # Rel-path is built the SAME way `scan_disk_state/2` builds its keys:
  # top-level entries are their bare name; nested entries are
  # "#{prefix}/#{name}". Any drift here misaligns the known_hashes merge →
  # a spurious "changed" next cycle → re-commit loop, so the two must match
  # exactly (guarded by the "inbound-written file is a no-op next cycle" test).
  defp export_schema(schema_doc, dir, prefix, store, artifact_store, acc, registry, known_hashes) do
    shadow_dir = Path.join(dir, ".commonplace-shadow")

    Schema.list_entries(schema_doc)
    |> Enum.reduce(acc, fn entry, {written, hashes} ->
      path = Path.join(dir, entry.name)
      rel = if prefix == "", do: entry.name, else: "#{prefix}/#{entry.name}"

      case entry.type do
        :dir ->
          File.mkdir_p!(path)
          sub_schema = load_schema(entry.node_id, store)

          export_schema(
            sub_schema,
            path,
            rel,
            store,
            artifact_store,
            {written, hashes},
            registry,
            known_hashes
          )

        :doc ->
          maybe_write_doc(
            entry,
            path,
            rel,
            store,
            artifact_store,
            {written, hashes},
            registry,
            shadow_dir,
            known_hashes
          )
      end
    end)
  end

  defp maybe_write_doc(
         entry,
         path,
         rel,
         store,
         artifact_store,
         {written, hashes},
         registry,
         shadow_dir,
         known_hashes
       ) do
    case CommitStoreClient.latest_commit(store, entry.node_id) do
      {:ok, commit} ->
        last_written = Map.get(written, entry.node_id)
        materialized = extract_content(commit)
        content_hash = materialized_hash(materialized)
        disk_hash = file_hash(path)

        cond do
          # Same commit — nothing written this cycle. Do NOT record a hash
          # here: leave known_hashes[rel] to the pre-outbound disk snapshot
          # (the Map.merge base), which correctly reflects either the
          # reconciled disk content OR an uncommitted mid-cycle user edit
          # (kept divergent → retried next cycle).
          last_written == commit.id ->
            {written, hashes}

          # Disk already holds exactly the CRDT content — record it as
          # reconciled but DON'T rewrite. This kills the redundant write-back
          # (outbound just committed what it read from disk) that would
          # otherwise clobber a concurrent edit, and avoids pointless churn.
          content_hash != nil and disk_hash == content_hash ->
            {Map.put(written, entry.node_id, commit.id), Map.put(hashes, rel, content_hash)}

          # Disk holds an edit we have NOT reconciled (differs from both the
          # CRDT and the last content we synced) — do NOT clobber it. Leave it
          # for outbound to commit next cycle; the CRDT then catches up. Without
          # shadow-tracking this is the guard that keeps inbound from
          # overwriting a concurrent disk edit (CX-60wl clobber race).
          disk_hash != nil and disk_hash != Map.get(known_hashes, rel) ->
            {written, hashes}

          # Disk is stale (absent, or equals what we last reconciled) and the
          # CRDT is ahead → write the CRDT content out. Record the SHA-256 of the
          # EXACT bytes we wrote (byte-match by construction → next-cycle
          # outbound sees disk == known and won't push it back).
          true ->
            case write_materialized(
                   materialized,
                   path,
                   artifact_store,
                   store,
                   registry,
                   shadow_dir,
                   commit,
                   entry
                 ) do
              :ok ->
                {Map.put(written, entry.node_id, commit.id), Map.put(hashes, rel, content_hash)}

              {:skipped, _reason} ->
                {written, hashes}
            end
        end

      :none ->
        {written, hashes}
    end
  end

  # Check shadow hardlinks for stale writes and merge them back into CRDT.
  # A CLEAN shadow (never diverged) is deliberately left tracked here —
  # its protection window stays open across cycles until either it
  # diverges (handled below) or the path is overwritten again
  # (`reconcile_superseded_shadow/3` closes it at that point, CX-wrg0).
  defp check_shadows(state) do
    shadows = InodeTracker.Registry.list_shadows(state.inode_registry)

    Enum.each(shadows, fn shadow ->
      reconcile_shadow(state.store, state.inode_registry, shadow, evict_if_clean: false)
    end)
  end

  # CX-wrg0: at the moment a path gets overwritten AGAIN, any shadow left
  # over from the PREVIOUS generation (tracked but not yet reconciled by
  # `check_shadows/1`) has reached the end of its protection window — a
  # third generation is about to exist at this path, so a stale fd still
  # holding the first-generation inode is now writing content nobody will
  # ever reconcile against. Give it one last look here:
  #
  #   - diverged  -> the existing recovery path folds the stale content
  #                  into the CRDT (same as periodic check_shadows would).
  #   - clean     -> nothing ever wrote to it; evict the registry entry
  #                  and unlink the shadow file instead of leaking both
  #                  forever (the second growth vector CX-wrg0 fixes —
  #                  CX-k34x only evicted the diverged case; unlike
  #                  check_shadows/1's periodic sweep, THIS caller wants
  #                  the clean branch to evict, since a new generation is
  #                  about to be tracked at the same path).
  #
  # Race window: a stale write landing between this check and the rename
  # inside atomic_write_with_shadow (below) is not caught — the shadow
  # file has already been judged clean and is about to be superseded.
  # This is not a new hole: it's the same class of μs TOCTOU already
  # documented and accepted for the inbound guard (CX-60wl/CX-axdi).
  # Shadow-tracking narrows loss windows, it was never claimed to close
  # them completely.
  defp reconcile_superseded_shadow(store, registry, path) do
    case InodeTracker.Registry.shadow_for_path(registry, path) do
      {:ok, shadow} -> reconcile_shadow(store, registry, shadow, evict_if_clean: true)
      :error -> :ok
    end
  end

  # Shared by the periodic sweep (check_shadows/1) and the write-time
  # supersession check (reconcile_superseded_shadow/3): judge one shadow
  # entry's fingerprint and either recover its stale content (always) or
  # evict it as clean (only when `evict_if_clean: true` — the periodic
  # sweep leaves clean shadows tracked; supersession always retires them).
  defp reconcile_shadow(store, registry, shadow, opts) do
    evict_if_clean = Keyword.fetch!(opts, :evict_if_clean)
    current_fingerprint = InodeTracker.file_fingerprint(shadow.shadow_path)

    cond do
      current_fingerprint != nil and current_fingerprint != shadow.fingerprint ->
        # Stale write detected — read content and create a commit.
        # CX-42no: File.read! here would crash the whole sync pass (and
        # thus the whole checkout, via SyncLoop's crash-loop) if the
        # shadow hardlink went unreadable between the fingerprint check
        # above and this read. Skip just this shadow and retry next pass.
        case File.read(shadow.shadow_path) do
          {:ok, stale_content} ->
            recover_stale_shadow(store, registry, shadow, stale_content)

          {:error, reason} ->
            Logger.warning(
              "Sync.Agent: skipping unreadable shadow #{shadow.shadow_path} (#{inspect(reason)})"
            )
        end

      current_fingerprint != nil and evict_if_clean ->
        # Fingerprint unchanged: never diverged. Called from the
        # write-time supersession path, so this generation's window is
        # closing regardless — evict now instead of leaking forever.
        evict_shadow(registry, shadow)

      true ->
        # Either the shadow file is unreadable/missing right now (leave
        # it tracked, retry next pass), or it's clean and this is the
        # periodic sweep, which intentionally leaves clean shadows
        # tracked — their window closes at supersession time, not here.
        :ok
    end
  end

  # CX-pyi: load + mutate against the shadow's commit, applying the
  # disk-content diff under a stable client_id so repeated stale-write
  # recoveries don't bloat the SV.
  defp recover_stale_shadow(store, registry, shadow, stale_content) do
    doc =
      case CommitStoreClient.get_commit(store, shadow.commit_id) do
        {:ok, commit} ->
          d = Yelixer.Doc.new(client_id: stable_client_id(shadow.doc_uuid))
          {:ok, d} = Yelixer.Encoding.apply_update(d, commit.update)
          d

        _ ->
          d = Yelixer.Doc.new(client_id: stable_client_id(shadow.doc_uuid))
          Commonplace.Document.ContentType.create(d, :text, Path.basename(shadow.path))
      end

    old_content = Commonplace.Document.ContentType.get_content(doc) || ""
    doc = Commonplace.Document.Diff.apply_diff(doc, old_content, stale_content)
    update = Yelixer.Encoding.encode_update(doc)

    # Create commit with the shadow's commit_id as parent
    CommitStoreClient.create_commit(store, shadow.doc_uuid, update, shadow.commit_id)

    # CX-k34x: the stale content has been folded into the CRDT, so
    # nothing further can be learned by continuing to track this inode —
    # evict it now that reconciliation is complete.
    evict_shadow(registry, shadow)
  end

  # CX-k34x/CX-wrg0: the shadow hardlink shares the OLD inode's (dev,
  # inode) pair — that's the whole point of hardlinking before the
  # overwrite (see InodeTracker.atomic_write_with_shadow). Recompute the
  # registry key from it, unlink the shadow file, and remove the
  # registry entry. Without this, Registry.track/5 (called on every
  # write) has no matching eviction and the in-memory map — plus one
  # shadow hardlink per entry — grows without bound for the life of the
  # BEAM.
  defp evict_shadow(registry, shadow) do
    old_inode_key = InodeTracker.inode_key(shadow.shadow_path)
    InodeTracker.cleanup_shadow(shadow.shadow_path)
    InodeTracker.Registry.remove_shadow(registry, old_inode_key)
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
      :text -> {:text, Commonplace.Document.ContentType.get_content(doc) || ""}
      :binary -> {:binary, Commonplace.Document.ContentType.get_content(doc)}
      _ -> {:text, Commonplace.Document.ContentType.get_content(doc) |> inspect()}
    end
  end

  defp sync_outbound_recursive(
         root_uuid,
         dir,
         store,
         artifact_store,
         binary_extensions,
         known_paths,
         known_hashes,
         inode_registry
       ) do
    watcher_opts = [
      inode_registry: inode_registry,
      artifact_store: artifact_store,
      binary_extensions: binary_extensions
    ]

    changes = Watcher.detect_changes(root_uuid, dir, store, watcher_opts)

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
            #
            # CX-42no: the file was readable moments ago (Watcher.detect_changes
            # just File.regular?/File.read!'d it to flag this as :modified), but
            # a file can go unreadable between that check and this one (perms
            # flip, unlink+symlink race). Reading here under rescue and treating
            # a failure as "not confirmed changed" (drop the change, retried
            # next tick) keeps one bad file from crash-looping the whole pass.
            case hash_locked(change.path) do
              disk_hash when is_binary(disk_hash) ->
                Map.get(known_hashes, change.name) != disk_hash

              nil ->
                Logger.warning(
                  "Sync.Agent: skipping unreadable modified file #{change.path} (:stream-read-failed)"
                )

                false
            end

          _ ->
            true
        end
      end)

    if changes != [] do
      Watcher.apply_changes(changes, root_uuid, dir, store, watcher_opts)
    end

    # Recurse into subdirectories
    schema_doc = load_schema(root_uuid, store)

    Schema.list_entries(schema_doc)
    |> Enum.each(fn entry ->
      if entry.type == :dir do
        sub_dir = Path.join(dir, entry.name)

        cond do
          symlinked_dir?(sub_dir) ->
            # CX-42no: never follow a symlinked directory into the outbound
            # walk — see Watcher.symlinked_dir?/1 for the rationale (no
            # visited-set needed, matches git/rsync default behavior, and
            # nothing exercises following symlinked dirs today).
            Logger.warning(
              "Sync.Agent: skipping symlinked directory #{sub_dir} (not followed, prevents cycle)"
            )

          File.dir?(sub_dir) ->
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

            sync_outbound_recursive(
              entry.node_id,
              sub_dir,
              store,
              artifact_store,
              binary_extensions,
              sub_known,
              sub_hashes,
              inode_registry
            )

          true ->
            :ok
        end
      end
    end)
  end

  defp symlinked_dir?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _ -> false
    end
  end

  # Hash under the shared-lock discipline without retaining whole-file bytes.
  defp hash_locked(path) do
    Commonplace.Sync.Flock.with_shared_lock(path, 30_000, fn ->
      file_hash(path)
    end)
  end

  defp scan_disk_state(dir, prefix) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce(names, {MapSet.new(), %{}}, fn name, {paths, hashes} ->
          rel = if prefix == "", do: name, else: "#{prefix}/#{name}"
          full = Path.join(dir, name)

          paths = MapSet.put(paths, rel)

          cond do
            symlinked_dir?(full) ->
              # CX-42no: don't descend into symlinked directories — see
              # symlinked_dir?/1 above. The path itself is still recorded
              # in `paths` (so it doesn't spuriously look "deleted"), just
              # not walked for children.
              Logger.warning("Sync.Agent: scan_disk_state skipping symlinked directory #{full}")

              {paths, hashes}

            File.dir?(full) ->
              {sub_paths, sub_hashes} = scan_disk_state(full, rel)
              {MapSet.union(paths, sub_paths), Map.merge(hashes, sub_hashes)}

            true ->
              case file_hash(full) do
                nil -> {paths, hashes}
                hash -> {paths, Map.put(hashes, rel, hash)}
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

  defp materialized_hash({:text, content}), do: hash_bytes(content)
  defp materialized_hash({:binary, %{cid: cid}}), do: cid

  defp write_materialized(
         {:text, content},
         path,
         _artifact_store,
         store,
         registry,
         shadow_dir,
         commit,
         entry
       ) do
    if registry do
      reconcile_superseded_shadow(store, registry, path)

      InodeTracker.atomic_write_with_shadow(
        path,
        content,
        shadow_dir,
        registry,
        commit.id,
        entry.node_id
      )
    else
      Export.atomic_write(path, content)
    end

    :ok
  end

  defp write_materialized(
         {:binary, envelope},
         path,
         artifact_store,
         _store,
         _registry,
         _shadow_dir,
         _commit,
         _entry
       ) do
    BinaryWriteBack.write(artifact_store, envelope, path)
  end

  defp file_hash(path) do
    case ArtifactStore.digest(File.stream!(path, [], 64 * 1024)) do
      {:ok, cid, _size} -> cid
      {:error, _reason} -> nil
    end
  rescue
    _ -> nil
  end

  defp hash_bytes(content), do: Base.encode16(:crypto.hash(:sha256, content), case: :lower)

  defp default_artifact_store do
    Application.get_env(:commonplace, :data_dir, "data") |> ArtifactStore.new()
  end
end
