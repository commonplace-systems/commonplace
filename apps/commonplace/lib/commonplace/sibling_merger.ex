defmodule Commonplace.SiblingMerger do
  @moduledoc """
  Distributed sibling-commit merge primitive (CX-4qn1).

  `maybe_merge_siblings/3` discovers commits that are persisted for
  `doc_uuid` but NOT reachable in the commit DAG of `:latest` (the
  per-doc head pointer), then collapses them into that head by running
  `Merger.merge/4` and CAS-writing the resulting merge commit.
  "Reachable" here means walking back from `:latest` along *both* the
  `parent_id` and the `merge_parents` edges — not just the linear
  parent chain. Following `merge_parents` is what makes the operation
  idempotent: a sibling already folded into the head by an earlier
  merge stays reachable *through* that merge commit, so it is not
  re-merged on every call and repeated invocations settle on
  `{:ok, :no_siblings}`.

  The merge commit's `parent_id` is the local head we observed, so the
  compare-and-swap (CAS) gate
  (`CommitStore.write_prebuilt_commit_cas/2`) rejects stale-head
  writers as `:parent_moved` and lets the caller retry on a fresh
  read without clobbering a concurrent local writer.

  ## Why this bead exists

  `CommitStore.import_commit/2` persists remote commits into CubDB but
  deliberately does NOT advance `:latest` if a head is already set —
  advancing would silently clobber the local head when two peers
  wrote chained off the same parent. As a result, imported sibling
  commits are reachable via id lookup but invisible to the linear
  chain walk from `:latest` (see `commit_ids_for_doc/2`). CX-l7j
  fixed the in-process version of this race via GenServer mailbox
  serialization; distributed siblings require post-hoc reassembly.

  ## Scope

  Primitive only. Wiring-point decisions (post-import hook vs. sync
  agent sweep vs. explicit caller) are deferred to the follow-up beads
  listed on CX-4qn1. The primitive is auto-trigger-friendly: same-parent
  callers produce the same merge commit id (byte-deterministic CAS
  write), and a stale-parent caller cleanly backs off.
  """

  alias Commonplace.Store.{Commit, CommitStore, Merger}

  @default_strategy :translate

  @type merged_result ::
          {:ok, :merged, Commit.t()}
          | {:ok, :no_siblings}

  @doc """
  Merge any sibling commits for `doc_uuid` into `:latest`.

  Opts:
    - `:strategy` — `:translate` (default) or `:merge_snapshot`. Passed
      through to `Merger.merge/4`.

  Returns:
    - `{:ok, :merged, commit}` when a sibling was merged and persisted;
      `:latest` now points to `commit.id`.
    - `{:ok, :no_siblings}` when every persisted commit for `doc_uuid`
      is already on `:latest`'s chain (or the doc has no commits at
      all).
  """
  @spec maybe_merge_siblings(GenServer.server(), String.t(), keyword()) :: merged_result()
  def maybe_merge_siblings(store \\ CommitStore, doc_uuid, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, @default_strategy)

    case CommitStore.latest_commit(store, doc_uuid) do
      :none ->
        {:ok, :no_siblings}

      {:ok, latest} ->
        covered = dag_reachable_from(store, latest.id)
        all_for_doc = CommitStore.all_commit_ids_for_doc(store, doc_uuid)
        sibling_ids = MapSet.difference(all_for_doc, covered)

        case MapSet.to_list(sibling_ids) do
          [] -> {:ok, :no_siblings}
          [sibling_id | _] -> merge_and_write(store, latest, sibling_id, strategy)
        end
    end
  end

  # Walk the commit DAG from `root_id` following BOTH `parent_id` and
  # `merge_parents`. Everything visited is "already in :latest's history"
  # and cannot be a sibling. Without the merge_parents edge, a sibling
  # that was already folded in (via `merge_parents`) would keep getting
  # re-merged on every call, never reaching the `:no_siblings` fixpoint.
  defp dag_reachable_from(store, root_id) do
    walk_dag(store, [root_id], MapSet.new())
  end

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

  defp merge_and_write(store, latest, sibling_id, strategy) do
    case CommitStore.get_commit(store, sibling_id) do
      {:ok, sibling} ->
        case Merger.merge(store, latest.id, sibling.id, strategy: strategy) do
          {:ok, merge_commit} ->
            case CommitStore.write_prebuilt_commit_cas(store, merge_commit) do
              {:ok, stored} -> {:ok, :merged, stored}
              # Concurrent local writer advanced :latest — bail to the
              # caller, who can re-invoke on a fresh read.
              {:error, :parent_moved} -> {:ok, :no_siblings}
            end

          {:error, _reason} ->
            {:ok, :no_siblings}
        end

      :none ->
        {:ok, :no_siblings}
    end
  end
end
