defmodule Commonplace.Tree.DocBuilder do
  @moduledoc """
  Shared helpers for reconstructing Y.Docs from commit chains.

  Used by Fork and Merge to replay commits and build documents.
  """

  alias Commonplace.Store.CommitStoreClient
  alias Yelixer.{Doc, Encoding}

  @doc """
  Reconstruct a doc by replaying its full commit chain (oldest -> newest).

  Use for content docs where edits are stored incrementally.
  Returns `{:ok, doc}` or `:none` if no commits exist.
  """
  def reconstruct_doc(store, uuid) do
    commits = CommitStoreClient.commit_log(store, uuid, limit: 10_000) |> Enum.reverse()

    case commits do
      [] ->
        :none

      _ ->
        doc = Doc.new()
        Enum.reduce(commits, {:ok, doc}, fn c, {:ok, d} -> Encoding.apply_update(d, c.update) end)
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
        doc = Doc.new()
        Enum.reduce(to_apply, {:ok, doc}, fn c, {:ok, d} -> Encoding.apply_update(d, c.update) end)

      {:not_found, _} ->
        :none
    end
  end
end
