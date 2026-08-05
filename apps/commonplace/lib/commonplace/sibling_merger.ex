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

  ## Sibling ordering and merge failures (CX-xxav)

  When more than one sibling exists, they are attempted in ascending
  binary-id order and the first that merges wins. Two things about
  that are deliberate:

  - **The order is explicit.** It used to be `[sibling_id | _] =
    MapSet.to_list(sibling_ids)` — i.e. whichever id BEAM's term order
    happened to put first. That made which sibling gets merged a
    function of hash bytes: bumping `Snapshotter`'s version tag
    (CX-2xn1) re-rolled every commit id in the fixture and silently
    changed which sibling `two_peer_merge_e2e_test`'s cross-epoch case
    exercised — flipping a green test red without any behavior
    changing. An arbitrary choice is fine; an *accidental* one is not,
    because it makes tests over this path unable to fail on purpose.

  - **A merge failure is reported, not renamed.** A sibling whose
    merge engine refuses (e.g. `{:untranslatable, :case_b, id}` from
    the cross-epoch translator) used to collapse to
    `{:ok, :no_siblings}` — "there is nothing to merge", which is
    false and unfalsifiable: the caller cannot tell a converged doc
    from one whose convergence just failed. Now every sibling is
    attempted, and if all of them fail the result is
    `{:error, {:siblings_unmergeable, [{sibling_id, reason}, ...]}}`
    carrying each refusal.
  """

  alias Commonplace.Store.{Commit, CommitStore, Merger}
  alias Commonplace.Trust.CodeDocHeuristic

  require Logger

  @default_strategy :translate

  @type merged_result ::
          {:ok, :merged, Commit.t()}
          | {:ok, :no_siblings}
          | {:ok, :code_doc_skip}
          | {:error, {:siblings_unmergeable, [{binary(), term()}]}}

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
      all), or when a sibling existed but `:latest` moved under us
      mid-write (CAS `:parent_moved` — re-invoke on a fresh read).
    - `{:error, {:siblings_unmergeable, [{sibling_id, reason}, ...]}}`
      (CX-xxav) when siblings existed and EVERY one of them was
      refused by the merge engine. Distinct from `:no_siblings`, which
      now means only what it says.
    - `{:ok, :code_doc_skip}` (CX-obfb) when a sibling exists but
      `doc_uuid` classifies as a code doc: auto-merging would emit a
      delta-merge commit whose `merge_parents` side-line Gate B
      (`Commonplace.Trust.authorized_to_execute?`) never traverses, so
      un-authorized content could reach execution unchecked. Heads stay
      divergent — code docs converge only by re-authorship (an
      `:execute`-authorized signer minting a regular full-state commit).
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

        # CX-xxav: `Enum.sort/1`, not raw MapSet iteration order — see
        # the moduledoc's "Sibling ordering and merge failures".
        case sibling_ids |> MapSet.to_list() |> Enum.sort() do
          [] ->
            {:ok, :no_siblings}

          [sibling_id | _] = siblings ->
            # Only tax the path where a sibling actually exists — the
            # common no-op case (:no_siblings) skips the classifier read.
            if CodeDocHeuristic.code_doc?(doc_uuid, store) do
              Logger.warning(
                "SiblingMerger: skipping auto-merge for code doc #{doc_uuid} — " <>
                  "no-delta-merge-on-code-docs invariant (CX-obfb). Heads stay " <>
                  "divergent; converge by re-authorship (an :execute-authorized " <>
                  "signer mints a regular full-state commit)."
              )

              :telemetry.execute(
                [:commonplace, :sibling_merge, :skipped_code_doc],
                %{system_time: System.system_time()},
                %{doc_uuid: doc_uuid, latest_id: latest.id, sibling_id: sibling_id}
              )

              {:ok, :code_doc_skip}
            else
              merge_first_mergeable(store, latest, siblings, strategy)
            end
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

  # CX-xxav: walk `siblings` in the caller's (sorted) order and return
  # the first that merges. Accumulate each refusal so that "every
  # sibling was refused" can be reported as itself rather than
  # laundered into `{:ok, :no_siblings}`.
  defp merge_first_mergeable(store, latest, siblings, strategy) do
    Enum.reduce_while(siblings, [], fn sibling_id, failures ->
      case merge_and_write(store, latest, sibling_id, strategy) do
        {:ok, :merged, _} = merged -> {:halt, merged}
        # `:latest` moved under us — no point trying the remaining
        # siblings against a head we no longer hold.
        {:ok, :no_siblings} = backoff -> {:halt, backoff}
        {:error, reason} -> {:cont, [{sibling_id, reason} | failures]}
      end
    end)
    |> case do
      failures when is_list(failures) ->
        {:error, {:siblings_unmergeable, Enum.reverse(failures)}}

      result ->
        result
    end
  end

  defp merge_and_write(store, latest, sibling_id, strategy) do
    case CommitStore.get_commit(store, sibling_id) do
      {:ok, sibling} ->
        case Merger.merge(store, latest.id, sibling.id, strategy: strategy) do
          {:ok, merge_commit} ->
            case CommitStore.write_prebuilt_commit_cas(store, merge_commit) do
              {:ok, stored} ->
                {:ok, :merged, stored}

              # Concurrent local writer advanced :latest — bail to the
              # caller, who can re-invoke on a fresh read.
              {:error, :parent_moved} ->
                {:ok, :no_siblings}
            end

          {:error, reason} ->
            {:error, reason}
        end

      :none ->
        {:error, {:unknown_sibling, sibling_id}}
    end
  end
end
