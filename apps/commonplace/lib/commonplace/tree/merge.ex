defmodule Commonplace.Tree.Merge do
  @moduledoc """
  Merges changes from a source branch into a target branch.

  Uses ForkManifest provenance to compute CRDT diffs for content docs
  and structural diffs for schema docs. See docs/plans/2026-03-23-branch-merge-design.md.
  """

  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{ForkManifest, Schema, Fork}
  alias Commonplace.Document.ContentType
  alias Commonplace.Process.Config
  alias Yelixer.{Doc, Encoding, BlockStore}

  defmodule MergeReport do
    @moduledoc "Result of a merge operation."
    defstruct merged_docs: [],
              new_docs: [],
              deleted_docs: [],
              conflicts: [],
              errors: []

    @type conflict ::
            {:delete_vs_modify, String.t(), String.t()}
            | {:name_collision, String.t(), String.t(), String.t()}

    @type t :: %__MODULE__{
            merged_docs: [{String.t(), String.t()}],
            new_docs: [{String.t(), String.t()}],
            deleted_docs: [String.t()],
            conflicts: [conflict()],
            errors: [term()]
          }
  end

  @doc """
  Reconstruct a Yelixer Doc by replaying all commits for the given UUID.
  commit_log/2 returns newest-first; we reverse to apply oldest-first.
  Returns {:ok, doc} or :none if no commits exist.
  """
  def reconstruct_doc(store, doc_uuid) do
    case CommitStore.commit_log(store, doc_uuid) do
      [] ->
        :none

      commits ->
        doc = Doc.new()
        oldest_first = Enum.reverse(commits)

        Enum.reduce_while(oldest_first, {:ok, doc}, fn commit, {:ok, acc} ->
          case Encoding.apply_update(acc, commit.update) do
            {:ok, updated} -> {:cont, {:ok, updated}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  @doc """
  Reconstruct a Doc up to (and including) a specific commit.
  commit_log/2 returns newest-first; we reverse to get oldest-first,
  then apply commits until we reach target_commit_id.
  """
  def reconstruct_doc_at(store, doc_uuid, target_commit_id) do
    case CommitStore.commit_log(store, doc_uuid) do
      [] ->
        :none

      commits ->
        oldest_first = Enum.reverse(commits)

        commits_to_apply =
          Enum.reduce_while(oldest_first, [], fn commit, acc ->
            if commit.id == target_commit_id do
              {:halt, Enum.reverse([commit | acc])}
            else
              {:cont, [commit | acc]}
            end
          end)

        if commits_to_apply == [] do
          :none
        else
          doc = Doc.new()

          Enum.reduce_while(commits_to_apply, {:ok, doc}, fn commit, {:ok, acc} ->
            case Encoding.apply_update(acc, commit.update) do
              {:ok, updated} -> {:cont, {:ok, updated}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
        end
    end
  end
end
