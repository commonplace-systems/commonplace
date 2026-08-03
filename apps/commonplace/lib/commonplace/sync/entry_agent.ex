defmodule Commonplace.Sync.EntryAgent do
  @moduledoc """
  Per-file bidirectional sync agent — the leaf of the sparse-sync tree.

  Each EntryAgent keeps one on-disk file and one CRDT document (its
  `doc_uuid`) in sync, in both directions. One `sync_once/1` cycle runs
  outbound then inbound:

  - **Outbound** (disk → CRDT): if the file's content changed since we
    last looked, fold that change into the document and commit it.
  - **Inbound** (CRDT → disk): if a new commit appeared (e.g. from a
    remote peer), reconstruct the document's content and write it to the
    file atomically.

  ## The echo problem, and the two trackers that solve it

  Naive bidirectional sync loops forever: outbound writes a commit,
  inbound sees that new commit and writes the file, the next outbound
  sees a "changed" file and commits again, and so on. EntryAgent breaks
  the loop with two pieces of remembered state, one per axis:

  - `known_hash` — an MD5 of the content we believe is currently mirrored
    on *both* sides. Outbound skips when the disk content still hashes to
    `known_hash` (nothing new to push); inbound skips the file write when
    a new commit's content hashes to `known_hash` (a metadata-only change
    that doesn't alter bytes). This is the **content axis**.
  - `last_written_commit_id` — the id of the latest commit we've already
    reflected to disk. Inbound skips when the store's latest commit id
    still matches it (no new CRDT-side change). This is the **commit
    axis**.

  The two work together to close the echo: an outbound write updates
  *both* trackers (the commit it just made, and the disk hash), so the
  inbound half of the *same* cycle sees its own commit as
  already-reflected and does not write the file back out. You need both
  because the commit id alone can't tell a content change from a
  metadata-only commit, and the content hash alone can't notice CRDT-side
  history moving forward.

  ## Inbound-clobber guard (CX-dvtj, porting CX-60wl)

  Before writing CRDT content to disk, inbound re-checks the file's
  CURRENT content hash rather than trusting `known_hash` alone. If disk
  holds bytes that differ from both the CRDT content and `known_hash`,
  that's an edit outbound hasn't reconciled into a commit yet — inbound
  skips the write so it doesn't clobber it; outbound commits the edit on
  a later cycle and the CRDT catches up from there. See
  `Commonplace.Sync.Agent`'s `maybe_write_doc/8` for the sibling guard in
  the legacy full-tree agent.

  ## Outbound is a diff-and-apply, not a rewrite

  Outbound does **not** re-encode the whole file as a brand-new document.
  It reconstructs the existing CRDT, computes the text diff between the
  document's current content and the file, and applies only those
  incremental Yjs ops (`Commonplace.Document.Diff`). This preserves Yjs
  item identity (so concurrent edits from other peers still merge) and
  avoids state-vector bloat. The reconstruction uses a *stable*
  `client_id` derived from `doc_uuid` (CX-pyi) so every outbound write of
  this file reuses one state-vector slot instead of minting a fresh
  random client each time. Only the very first write — when the document
  has no commits yet — creates a new `:text` document. Inbound/read paths
  use a plain `Yelixer.Doc.new()`: they never re-encode, so no bloat is
  possible there.

  ## Snapshot hook

  After persisting an outbound commit the agent calls
  `Commonplace.SnapshotTrigger.maybe_snapshot/3`, which cuts a snapshot
  once the commit chain crosses a length threshold (with an optional
  edit-count-plus-quiet-period heuristic — both
  `soft_snapshot_chain_threshold` and `snapshot_lull_window_ms` must be
  set to enable it). Snapshot creation is CAS-deduplicated, so racing
  peers converge on one snapshot rather than each cutting their own.

  Part of the sparse-sync system — one EntryAgent per file, spawned by
  `Commonplace.Sync.DirAgent` for directory checkouts, or run standalone
  (FileAgent) for a single-file checkout.
  """

  use GenServer

  alias Commonplace.SnapshotTrigger
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Document.{ContentType, Diff}
  alias Commonplace.Sync.Export

  defstruct [
    :doc_uuid,
    :file_path,
    :store,
    :last_written_commit_id,
    :known_hash,
    :shadow_dir,
    :standalone,
    :snapshot_chain_threshold,
    # CX-592q: heuristic lull-aware layer — opts pair that gates a
    # snapshot on "enough edits + quiet period." Both must be set to
    # enable; either missing falls back to the pure mandatory threshold.
    :soft_snapshot_chain_threshold,
    :snapshot_lull_window_ms
  ]

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Run one sync cycle: outbound (disk → CRDT), then inbound (CRDT → disk)."
  def sync_once(pid) do
    GenServer.call(pid, :sync_once, 30_000)
  end

  @doc "Graceful shutdown."
  def stop(pid) do
    GenServer.stop(pid, :normal)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    state = %__MODULE__{
      doc_uuid: Keyword.fetch!(opts, :doc_uuid),
      file_path: Keyword.fetch!(opts, :file_path),
      store: Keyword.get(opts, :store, CommitStoreClient),
      last_written_commit_id: nil,
      known_hash: nil,
      shadow_dir: Keyword.get(opts, :shadow_dir),
      standalone: Keyword.get(opts, :standalone, false),
      snapshot_chain_threshold: Keyword.get(opts, :snapshot_chain_threshold),
      soft_snapshot_chain_threshold: Keyword.get(opts, :soft_snapshot_chain_threshold),
      snapshot_lull_window_ms: Keyword.get(opts, :snapshot_lull_window_ms)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:sync_once, _from, state) do
    state =
      state
      |> sync_outbound()
      |> sync_inbound()

    {:reply, :ok, state}
  end

  # --- Outbound sync (disk → CRDT) ---

  defp sync_outbound(state) do
    case Commonplace.Sync.Flock.with_shared_lock(state.file_path, 30_000, fn ->
      File.read(state.file_path)
    end) do
      {:ok, content} ->
        disk_hash = :erlang.md5(content)

        if disk_hash == state.known_hash do
          # No disk changes — skip
          state
        else
          # CX-pyi: load + mutate. Reconstruct the existing CRDT under
          # a stable client_id, compute the text diff against the disk
          # content, apply incremental Yjs ops. Avoids state-vector
          # bloat and preserves Yjs item identity.
          doc =
            case CommitStoreClient.latest_commit(state.store, state.doc_uuid) do
              {:ok, commit} ->
                d = Yelixer.Doc.new(client_id: stable_client_id(state.doc_uuid))
                {:ok, d} = Yelixer.Encoding.apply_update(d, commit.update)
                d

              :none ->
                d = Yelixer.Doc.new(client_id: stable_client_id(state.doc_uuid))
                ContentType.create(d, :text, Path.basename(state.file_path))
            end

          old_content = ContentType.get_content(doc) || ""
          doc = Diff.apply_diff(doc, old_content, content)
          update = Yelixer.Encoding.encode_update(doc)

          commit = CommitStoreClient.create_chained_commit(state.store, state.doc_uuid, update)

          # CX-tvyb: producer-side snapshot hook. After persisting the
          # writer's edit, check the chain-length threshold and cut a
          # snapshot if crossed. Safe to call concurrently with other
          # peers' triggers — CAS dedup in `write_snapshot_cas` lets the
          # first deterministic-anyone caller win and turns the rest into
          # a no-op (CX-umz parallel).
          maybe_trigger_snapshot(state)

          %{state | last_written_commit_id: commit.id, known_hash: disk_hash}
        end

      {:error, _} ->
        # File doesn't exist — skip outbound
        state
    end
  end

  # CX-tvyb: dispatch maybe_snapshot with the per-agent threshold (when
  # configured) — otherwise fall through to the primitive's default
  # (Application env / @default_chain_length_threshold).
  #
  # CX-592q: also threads the optional heuristic opts pair
  # (soft_snapshot_chain_threshold + snapshot_lull_window_ms). Both
  # must be set to enable lull-aware firing; either missing keeps the
  # hook on pure-mandatory behavior.
  defp maybe_trigger_snapshot(state) do
    opts =
      []
      |> maybe_put(:chain_length_threshold, state.snapshot_chain_threshold)
      |> maybe_put(:soft_chain_length_threshold, state.soft_snapshot_chain_threshold)
      |> maybe_put(:lull_window_ms, state.snapshot_lull_window_ms)

    SnapshotTrigger.maybe_snapshot(state.store, state.doc_uuid, opts)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # --- Inbound sync (CRDT → disk) ---

  # Not `defp`: the CX-60wl-style guard below is exercised directly in
  # tests against a hand-built state struct (no GenServer needed), the
  # same way agent_test.exs probes the legacy guard's invariants.
  @doc false
  def sync_inbound(state) do
    case CommitStoreClient.latest_commit(state.store, state.doc_uuid) do
      {:ok, commit} ->
        if commit.id == state.last_written_commit_id do
          # No new commits — skip
          state
        else
          # New commit — extract content from latest commit
          content = extract_content(commit)

          content_hash = :erlang.md5(content)

          if content_hash == state.known_hash do
            # Content unchanged despite new commit (metadata-only change)
            # Update commit tracking but don't rewrite file
            %{state | last_written_commit_id: commit.id}
          else
            # CX-60wl inbound-clobber guard (ported from Agent.maybe_write_doc/8):
            # re-check what's on disk NOW, not just what `known_hash` says we
            # last reconciled. `known_hash` is only updated at the END of a
            # cycle (see sync_outbound/1 and the write branch below), so if a
            # local edit landed on disk without outbound having folded it into
            # a commit yet (e.g. it lands between outbound's read and this
            # write), writing here would silently clobber it.
            disk_hash =
              case File.read(state.file_path) do
                {:ok, disk} -> :erlang.md5(disk)
                _ -> nil
              end

            cond do
              # Disk already holds exactly the CRDT content — record it as
              # reconciled without rewriting (avoids pointless churn).
              disk_hash == content_hash ->
                %{state | last_written_commit_id: commit.id, known_hash: content_hash}

              # Disk holds an edit we have NOT reconciled (differs from both
              # the CRDT content and the last content we know is mirrored) —
              # do NOT clobber it. Leave state as-is; outbound picks up the
              # disk edit and commits it next cycle, and the CRDT catches up
              # from there.
              disk_hash != nil and disk_hash != state.known_hash ->
                state

              # Disk is stale (absent, or equals what we last reconciled) and
              # the CRDT is ahead — write the CRDT content out.
              true ->
                Export.atomic_write(state.file_path, content)
                %{state | last_written_commit_id: commit.id, known_hash: content_hash}
            end
          end
        end

      :none ->
        # No commits exist for this doc — nothing to write
        state
    end
  end

  # --- Helpers ---

  # Extract content from a commit's update.
  #
  # Each outbound commit stores the full document state (not incremental deltas),
  # so we apply only the single commit's update to a fresh doc — matching the
  # pattern in Agent.extract_content/1.
  defp extract_content(commit) do
    doc = Yelixer.Doc.new()
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)

    case ContentType.get_type(doc) do
      :text -> ContentType.get_content(doc) || ""
      _ -> ContentType.get_content(doc) |> inspect()
    end
  end

  # CX-pyi: stable client_id keeps the SV at one slot per doc across
  # outbound writes. Reading paths use plain Doc.new() because they
  # never re-encode (no bloat possible).
  defp stable_client_id(uuid) when is_binary(uuid) do
    :erlang.phash2(uuid, 0xFFFF_FFFF)
  end
end
