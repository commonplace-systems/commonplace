defmodule Commonplace.Tree.DocBuilder do
  @moduledoc """
  Shared helpers for reconstructing Y.Docs from commit chains.

  Used by Fork and Merge to replay commits and build documents.
  """

  alias Commonplace.Store.CommitStoreClient
  alias Yelixer.{Doc, Encoding}

  @doc """
  Reconstruct a doc by replaying its commit chain (oldest -> newest).

  Use for content docs where edits are stored incrementally.
  Returns `{:ok, doc}` or `:none` if no commits exist.

  CX-u7p: when a snapshot commit (metadata.kind == :snapshot) appears
  in the chain, the backward walk stops at the most recent snapshot —
  the snapshot is itself a self-contained encoding of the doc state at
  that point — and the forward replay starts from that snapshot plus
  any commits chained on top. Docs with no snapshot commits replay the
  full chain exactly as before (backward-compatible).
  """
  def reconstruct_doc(store, uuid) do
    commits = CommitStoreClient.commit_log(store, uuid, limit: 10_000) |> Enum.reverse()

    case commits do
      [] ->
        :none

      _ ->
        commits_to_apply = commits |> trim_to_latest_snapshot() |> Enum.reject(&genesis?/1)
        doc = Doc.new()

        result =
          Enum.reduce(commits_to_apply, {:ok, doc}, fn c, {:ok, d} ->
            Encoding.apply_update(d, c.update)
          end)

        # CX-fkvc: opportunistically trigger a snapshot when the post-trim
        # chain is long enough to be worth compacting. The trigger primitive
        # is itself idempotent / CAS-safe, so racing the producer-side hook
        # (CX-tvyb), the periodic sweeper (CX-fab5), or the explicit CLI
        # command (CX-2ok0) collapses to a single snapshot via CX-umz.
        # Fired in a Task so the read isn't blocked on the snapshot build.
        maybe_lazy_snapshot(store, uuid, length(commits_to_apply))

        result
    end
  end

  defp maybe_lazy_snapshot(store, uuid, chain_length) do
    if lazy_snapshot_enabled?() and chain_length >= lazy_snapshot_threshold() do
      # R4(b) / CX-tdkq.4: route through the single-flight SnapshotWorker
      # instead of an unbounded `Task.start`. Under read pressure many reads
      # of the same doc fire this path at once; the worker collapses them to
      # one in-flight snapshot attempt (plus at most one coalesced re-run)
      # rather than piling up redundant Tasks. Replaces the old ETS debounce.
      Commonplace.SnapshotWorker.request(store, uuid)
    end

    :ok
  end

  # CX-fkvc: default-on in dev/prod, default-off in test (see
  # config/test.exs) so background snapshot writes don't race with
  # test isolation. Tests that exercise the lazy path flip this in
  # their setup.
  defp lazy_snapshot_enabled? do
    Application.get_env(:commonplace, :reader_lazy_snapshot_enabled, true)
  end

  defp lazy_snapshot_threshold do
    Application.get_env(
      :commonplace,
      :reader_lazy_snapshot_threshold,
      100
    )
  end

  # Given commits in chronological order (oldest -> newest), return the
  # tail starting at the most recent snapshot. If no snapshot is found,
  # returns the full list unchanged.
  defp trim_to_latest_snapshot(commits) do
    case Enum.find_index(Enum.reverse(commits), &snapshot?/1) do
      nil ->
        commits

      idx_from_end ->
        # idx_from_end is 0-based from the *end* of the list. Convert
        # to a position from the start, then drop everything before it.
        Enum.drop(commits, length(commits) - 1 - idx_from_end)
    end
  end

  defp snapshot?(commit) do
    case Map.get(commit, :metadata) do
      %{kind: :snapshot} -> true
      _ -> false
    end
  end

  # CX-m3x: genesis commits are synthetic DAG roots with an empty
  # `update` payload. They exist to establish a deterministic namespace
  # root, not to carry any Yjs state, so the reducer must skip them —
  # `Encoding.apply_update` on <<>> would crash the replay.
  defp genesis?(commit) do
    case Map.get(commit, :metadata) do
      %{kind: :genesis} -> true
      _ -> false
    end
  end

  @doc """
  Reconstruct a doc by applying only the latest commit to a fresh doc.

  Use for schema docs where fork always stores full snapshots.
  This avoids CRDT inconsistency from applying full snapshots on top of each other.
  Returns `{:ok, doc}` or `:none` if no commits exist.
  """
  def reconstruct_snapshot(store, uuid) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Doc.new()
        Encoding.apply_update(doc, commit.update)

      :none ->
        :none
    end
  end

  @doc """
  Reconstruct a doc by replaying commits up to (and including) a specific commit.

  Returns `{:ok, doc}` or `:none` if the target commit is not found in the chain.

  CX-u7p: like `reconstruct_doc/2`, this short-circuits on snapshot
  commits (metadata.kind == :snapshot). If a snapshot commit exists on
  the path from root to `target_commit_id`, the replay starts at the
  most recent snapshot at or before the target and applies only that
  snapshot plus any commits chained on top, up to and including the
  target. Without this, merges of compacted branches would start from a
  wrong baseline (`Tree.Merge.merge_leaf/5` uses this function).
  """
  def reconstruct_doc_at(store, uuid, target_commit_id) do
    commits = CommitStoreClient.commit_log(store, uuid, limit: 10_000) |> Enum.reverse()

    result =
      Enum.reduce_while(commits, {:not_found, []}, fn commit, {_status, acc} ->
        if commit.id == target_commit_id do
          {:halt, {:found, Enum.reverse([commit | acc])}}
        else
          {:cont, {:not_found, [commit | acc]}}
        end
      end)

    case result do
      {:found, to_apply} ->
        commits_to_apply = to_apply |> trim_to_latest_snapshot() |> Enum.reject(&genesis?/1)
        doc = Doc.new()

        Enum.reduce(commits_to_apply, {:ok, doc}, fn c, {:ok, d} ->
          Encoding.apply_update(d, c.update)
        end)

      {:not_found, _} ->
        :none
    end
  end
end
