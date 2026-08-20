defmodule Commonplace.Store.AcceptedHeads do
  @moduledoc """
  The accepted-head SET for a document — its non-dominated frontier.

  A document's accepted heads are `:latest` (the local head pointer) plus
  the tips of any sibling branches that are persisted for the document but
  not reachable from `:latest`. This is precisely the set `SiblingMerger`
  reconstructs when it asks "what are this document's non-dominated
  heads?" — a sibling chain's tip IS a head; its interior commits are
  dominated by that tip and are not.

  ## Why this module exists

  `SiblingMerger` currently derives siblings inline as
  `all_commit_ids_for_doc(doc) − reachable(:latest)`, where
  `all_commit_ids_for_doc` is a per-call scan the Stage-B ruling
  (2026-08-08 multiplayer-proposal-reaction §1) marked for retirement in
  favour of an eagerly maintained head index. This module names the
  accepted-head set as a first-class primitive and establishes it as the
  computation an incrementally-maintained index (a later increment) must
  match. Naming and testing the set is the additive first step; the
  durable index, the single head-update seam, and retiring the scan are
  separate, later increments.

  This increment is READ-ONLY over existing store primitives
  (`latest_commit/2`, `commit_ids_for_doc/2` for the reachable chain, and
  `all_commit_ids_for_doc/2` for the full per-doc set). It touches no
  write path and runs no backfill.
  """

  alias Commonplace.Store.CommitStore

  @doc """
  The accepted-head set for `doc_uuid`.

  Returns `{:ok, MapSet.t(binary())}` of head commit ids (always
  including `:latest`), or `:none` when the document has no commits.
  """
  @spec of(GenServer.server(), String.t()) :: {:ok, MapSet.t(binary())} | :none
  def of(store \\ CommitStore, doc_uuid) do
    case CommitStore.latest_commit(store, doc_uuid) do
      :none ->
        :none

      {:ok, latest} ->
        # `dag_reachable_from/2` walks BOTH parent_id and merge_parents
        # from :latest (see below); `all_commit_ids_for_doc/2` is the full
        # per-doc set. Their difference is every commit off the :latest
        # DAG — sibling branches, interior and tips alike.
        reachable = dag_reachable_from(store, latest.id)
        all_for_doc = CommitStore.all_commit_ids_for_doc(store, doc_uuid)
        off_latest = MapSet.difference(all_for_doc, reachable)

        heads =
          off_latest
          |> non_dominated_tips(store)
          |> MapSet.put(latest.id)

        {:ok, heads}
    end
  end

  # A commit in `off_latest` is a tip iff no other commit in `off_latest`
  # names it as a parent (via `parent_id` or `merge_parents`). Removing
  # every such referenced parent leaves exactly the frontier tips: in a
  # chain C -> R1 -> R2, R1 is named by R2 and is dropped, R2 is named by
  # nobody and survives. C is reachable from :latest and so is not in
  # `off_latest` to begin with.
  defp non_dominated_tips(off_latest, store) do
    dominated =
      Enum.reduce(off_latest, MapSet.new(), fn id, acc ->
        case CommitStore.get_commit(store, id) do
          {:ok, commit} ->
            [commit.parent_id | commit.merge_parents || []]
            |> Enum.reject(&is_nil/1)
            |> Enum.reduce(acc, fn parent, inner ->
              if MapSet.member?(off_latest, parent), do: MapSet.put(inner, parent), else: inner
            end)

          :none ->
            acc
        end
      end)

    MapSet.difference(off_latest, dominated)
  end

  # Everything reachable from :latest following BOTH parent_id and
  # merge_parents — mirrors `SiblingMerger.dag_reachable_from/2`. The
  # merge_parents edge is essential: a sibling already folded into :latest
  # by a merge commit is reachable only through that edge, so walking the
  # linear parent chain alone (`commit_ids_for_doc`) would leave it in
  # `off_latest` and report a merged-in sibling as a still-open head.
  defp dag_reachable_from(store, root_id), do: walk_dag(store, [root_id], MapSet.new())

  defp walk_dag(_store, [], acc), do: acc

  defp walk_dag(store, [id | rest], acc) do
    if MapSet.member?(acc, id) do
      walk_dag(store, rest, acc)
    else
      acc = MapSet.put(acc, id)

      case CommitStore.get_commit(store, id) do
        {:ok, commit} ->
          next =
            [commit.parent_id | commit.merge_parents || []]
            |> Enum.reject(&is_nil/1)

          walk_dag(store, next ++ rest, acc)

        :none ->
          walk_dag(store, rest, acc)
      end
    end
  end
end
