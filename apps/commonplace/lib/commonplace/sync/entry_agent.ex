defmodule Commonplace.Sync.EntryAgent do
  @moduledoc """
  Per-file bidirectional sync agent.

  Each EntryAgent manages sync for a single document/file pair:
  - **Inbound** (CRDT → disk): when a new commit appears in the store,
    reconstruct the document content and write it to disk atomically.
  - **Outbound** (disk → CRDT): when the file changes on disk,
    create a new CRDT document with the file content and commit it.

  Uses content hashing (MD5) to avoid redundant writes in either direction,
  and commit ID tracking to detect new CRDT-side changes.

  Part of the sparse sync system — one EntryAgent per file. Spawned by
  DirAgent for directory checkouts, or used standalone as FileAgent for
  single-file checkouts.
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

  defp sync_inbound(state) do
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
            # Content changed — write to disk
            Export.atomic_write(state.file_path, content)
            %{state | last_written_commit_id: commit.id, known_hash: content_hash}
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
