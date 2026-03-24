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

  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType
  alias Commonplace.Sync.Export

  defstruct [
    :doc_uuid,
    :file_path,
    :store,
    :last_written_commit_id,
    :known_hash,
    :shadow_dir,
    :standalone
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
      store: Keyword.get(opts, :store, CommitStore),
      last_written_commit_id: nil,
      known_hash: nil,
      shadow_dir: Keyword.get(opts, :shadow_dir),
      standalone: Keyword.get(opts, :standalone, false)
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
          # Disk content changed — create a new CRDT doc and commit
          doc = Yelixer.Doc.new()
          doc = ContentType.create(doc, :text, Path.basename(state.file_path))
          doc = ContentType.insert_text(doc, 0, content)
          update = Yelixer.Encoding.encode_update(doc)

          commit = CommitStore.create_chained_commit(state.store, state.doc_uuid, update)

          %{state | last_written_commit_id: commit.id, known_hash: disk_hash}
        end

      {:error, _} ->
        # File doesn't exist — skip outbound
        state
    end
  end

  # --- Inbound sync (CRDT → disk) ---

  defp sync_inbound(state) do
    case CommitStore.latest_commit(state.store, state.doc_uuid) do
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
end
