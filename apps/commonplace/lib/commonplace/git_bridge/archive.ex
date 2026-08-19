defmodule Commonplace.GitBridge.Archive do
  @moduledoc """
  GitBridge G1.5 (CX-b0ow.4): a self-verifying, full-fidelity commit
  archive under `<repo_dir>/.commonplace/archive/`, so the git-synced
  tree becomes a complete, independently-restorable backup of full CRDT
  commit history — not just latest-state files.

  This is EXPORT-ONLY and adds no new trust surface: rows are inert
  JSON blobs, nothing here writes back to the CommitStore.

  ## Row format

  Each row reuses `Commonplace.Federation.Envelope.for_commit/2`
  as-is — it already builds a self-verifying JSON envelope (commit +
  capability-proof cert chain, base64 `term_to_binary` payloads) and
  already carries a version field (`"v"`), so there is no need to wrap
  it in a second `archive_format` envelope. `Envelope.encode/2`'s
  underlying map has few keys (`v`, `commit`, `certs`), well under
  Erlang's small-map threshold, so its key iteration order — and
  therefore `Jason.encode!/1`'s output — is deterministic for equal
  input; re-archiving the same commit is provably byte-identical
  without routing through `CanonicalJson`.

  ## Layout

  `.commonplace/archive/<doc-uuid>/<commit-id-hex>.json` — the filename
  is ONLY the commit id (lowercase hex); there is no sequence prefix.
  Ordering lives in the envelope's `parent_id` chain, not the filename
  or directory listing order. Re-archiving an existing row is a
  byte-identical no-op: `write_row/3` skips writing when the target
  file already exists, since the content only ever depends on the
  commit stored under that id.

  One file per commit is an ACCEPTED v1 cost — no batching/compaction.

  ## Watermark

  A single canonical-JSON `.commonplace/archive/watermarks.json` keyed
  by doc uuid (option (b) from the design), over the per-doc-file
  alternative (option (a)):

    * one file to read/write per cycle instead of N, so a multi-doc
      cycle's watermark advance is a single atomic write (same
      `Export.atomic_write/2` + fsync-then-rename primitive `Sidecar`
      already uses for `mount.json`);
    * easier to inspect/diff in git — one file shows the whole mount's
      archive progress instead of scattering `.watermark` files across
      every doc's archive subdirectory;
    * simpler prune/traversal story (no extra filename to exclude from
      "is this a commit row" checks inside each per-doc directory).

  ## Cycle logic (per doc)

  1. Read the doc's current head via `CommitStoreClient.latest_commit/2`.
     No commits at all -> nothing to do.
  2. If the stored watermark already equals the head, there is nothing
     new -> skip (cheap common case, avoids a `commit_log` walk on a
     quiescent doc every cycle).
  3. Otherwise walk the chain oldest -> newest via
     `CommitStoreClient.commit_log/3` (parent_id chain from `:latest`,
     bounded by a generous `limit`).
  4. Write a row for every commit in that walk (skip already-existing
     files — the idempotent no-op path).
  5. Advance the watermark to the new head ONLY if the walk actually
     proves continuity: either it reached genesis (oldest commit in
     the walked window has `parent_id == nil`) or the old watermark
     commit itself appears in the walked window. If neither holds —
     the walk was truncated by `limit` before reaching either — the
     rows found are still written (honest partial progress), but the
     watermark is NOT advanced, so a later cycle with a larger
     effective window (the previously-written rows already exist, so
     `write_row/3` skips them; the walk just needs to reach the old
     watermark or genesis this time) can complete the join without
     ever fabricating continuity.

  ## Genesis / empty-update commits

  `Envelope.for_commit/2` packs a `%Commit{}` with `:erlang.term_to_binary/1`
  and has no opinion on empty `update` binaries or `nil` `parent_id` —
  a genesis-shaped commit packs and decodes exactly like any other.
  `build_envelope/2` still wraps the call defensively (this module's
  own row-coverage note): if packing ever does raise for some commit
  shape, that row is skipped (counted as not-written) rather than
  crashing the whole GitBridge sync cycle.
  """

  require Logger

  alias Commonplace.Federation.Envelope
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.GitBridge.CanonicalJson
  alias Commonplace.Sync.Export

  @archive_dir ".commonplace/archive"
  @watermarks_file "watermarks.json"
  @walk_limit 10_000

  @doc """
  Archive every commit for every uuid in `doc_uuids` that hasn't
  already been archived, under `<repo_dir>/#{@archive_dir}`.

  Returns `%{archived_count: non_neg_integer()}` — the number of row
  files newly written this call (already-existing rows don't count).
  """
  @spec archive(GenServer.server(), String.t(), Enumerable.t()) :: %{
          archived_count: non_neg_integer()
        }
  def archive(store, repo_dir, doc_uuids) do
    watermarks = read_watermarks(repo_dir)

    {new_watermarks, archived_count} =
      doc_uuids
      |> Enum.uniq()
      |> Enum.reduce({watermarks, 0}, fn uuid, {wms, count} ->
        {wms2, written} = archive_doc(store, repo_dir, uuid, wms)
        {wms2, count + written}
      end)

    if new_watermarks != watermarks do
      write_watermarks(repo_dir, new_watermarks)
    end

    %{archived_count: archived_count}
  end

  # --- Per-doc cycle ---

  defp archive_doc(store, repo_dir, uuid, watermarks) do
    case CommitStoreClient.latest_commit(store, uuid) do
      :none ->
        {watermarks, 0}

      {:ok, head_commit} ->
        head_hex = encode_id(head_commit.id)
        watermark = Map.get(watermarks, uuid)

        if watermark == head_hex do
          {watermarks, 0}
        else
          commits = CommitStoreClient.commit_log(store, uuid, limit: @walk_limit)
          {written, continuous?} = write_rows(store, repo_dir, uuid, commits, watermark)

          new_watermarks =
            if continuous? do
              Map.put(watermarks, uuid, head_hex)
            else
              watermarks
            end

          {new_watermarks, written}
        end
    end
  end

  # `commits` is newest -> oldest (CommitStoreClient.commit_log/3 walks
  # parent_id from :latest; see CommitStore.collect_log/4). Continuity
  # is proven either by reaching genesis (the oldest commit in the
  # window — the LAST element — has no parent) or by finding the prior
  # watermark commit inside the window — anything else means the walk
  # was truncated by `@walk_limit` before joining up with known history,
  # and honesty requires NOT advancing the watermark past that point.
  # This applies on the first cycle too (nil watermark): a truncated
  # first walk must not advance either, or commits older than the
  # window would silently never be archived.
  defp write_rows(store, repo_dir, uuid, commits, watermark) do
    reached_genesis? =
      commits != [] and match?(%{parent_id: nil}, List.last(commits))

    watermark_in_window? =
      watermark != nil and Enum.any?(commits, &(encode_id(&1.id) == watermark))

    continuous? = reached_genesis? or watermark_in_window?

    written =
      Enum.reduce(commits, 0, fn commit, acc ->
        if write_row(store, repo_dir, uuid, commit), do: acc + 1, else: acc
      end)

    {written, continuous?}
  end

  # Returns true iff a NEW file was written (false when skipped, either
  # because the row already exists or because packing failed).
  defp write_row(store, repo_dir, uuid, commit) do
    path = row_path(repo_dir, uuid, commit.id)

    if File.exists?(path) do
      false
    else
      case build_envelope(store, commit) do
        {:ok, content} ->
          Export.atomic_write(path, content)
          true

        :skip ->
          false
      end
    end
  end

  defp build_envelope(store, commit) do
    body = Envelope.for_commit(store, commit)
    content = if String.ends_with?(body, "\n"), do: body, else: body <> "\n"
    {:ok, content}
  rescue
    error ->
      Logger.warning(
        "GitBridge.Archive: failed to build envelope for commit #{inspect(commit.id)} " <>
          "(doc #{commit.doc_uuid}): #{inspect(error)}"
      )

      :skip
  end

  # --- Paths ---

  defp row_path(repo_dir, uuid, commit_id) do
    Path.join([repo_dir, @archive_dir, uuid, encode_id(commit_id) <> ".json"])
  end

  defp encode_id(id) when is_binary(id), do: Base.encode16(id, case: :lower)

  # --- Watermarks ---

  defp watermarks_path(repo_dir), do: Path.join([repo_dir, @archive_dir, @watermarks_file])

  defp read_watermarks(repo_dir) do
    case File.read(watermarks_path(repo_dir)) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp write_watermarks(repo_dir, watermarks) do
    json = CanonicalJson.encode(watermarks)
    Export.atomic_write(watermarks_path(repo_dir), json)
  end
end
