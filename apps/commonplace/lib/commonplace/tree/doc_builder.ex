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
        commits_to_apply = trim_to_latest_snapshot(commits)
        doc = Doc.new()

        Enum.reduce(commits_to_apply, {:ok, doc}, fn c, {:ok, d} ->
          Encoding.apply_update(d, c.update)
        end)
    end
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
        commits_to_apply = trim_to_latest_snapshot(to_apply)
        doc = Doc.new()

        Enum.reduce(commits_to_apply, {:ok, doc}, fn c, {:ok, d} ->
          Encoding.apply_update(d, c.update)
        end)

      {:not_found, _} ->
        :none
    end
  end
end
