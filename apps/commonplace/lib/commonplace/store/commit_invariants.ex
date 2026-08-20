defmodule Commonplace.Store.CommitInvariants do
  @moduledoc """
  Commit-domain resting-state invariants (`domain: :commit`), the first
  non-bd members of `Commonplace.Invariants.Registry`.

  ## Hazard 3 — accepted heads are an antichain

  A document's accepted-head set (the durable frontier maintained by the
  head-update seam, see `Commonplace.Store.AcceptedHeads`) must be an
  antichain: no accepted head may be a DAG-ancestor of another accepted
  head of the same document. The seam enforces this by construction
  (advancing to a commit prunes the heads it dominates), so this invariant
  is the BACKSTOP that outlives a future edit to the seam — if the
  domination delta ever regresses, a dominated head survives in the set
  and this check alarms. Plan #13391 / boss #13365: registered as an
  invariant rather than trusted to the seam's inline logic, because a rule
  inside a function is enforced only until someone edits that function.

  It is ALARM-ONLY and never blocks (plan #13391): a local merge advancing
  `:latest` must never be refused — that is refusing convergence (R4). The
  invariant observes; it does not gate.

  ## Ancestry follows both edges

  Domination here is DAG-reachability following `parent_id` AND
  `merge_parents`, not the linear chain: a sibling folded into another
  head by a merge commit is reachable only through the `merge_parents`
  edge. `CommitStore.is_ancestor?/3` walks the linear chain only and would
  miss exactly that case, so this module does its own two-edge walk.
  """

  alias Commonplace.Store.CommitStoreClient

  @doc """
  Hazard 3 for one document. Reads the durable accepted-head set and
  returns `:ok`, `{:violation, details}`, or `{:error, reason}`.
  A set of fewer than two heads is trivially an antichain.
  """
  @spec antichain(GenServer.server(), String.t()) ::
          :ok | {:violation, map()} | {:error, term()}
  def antichain(store \\ CommitStoreClient, doc_uuid) do
    case CommitStoreClient.accepted_heads_indexed(store, doc_uuid) do
      :none -> :ok
      {:ok, heads} -> antichain_of(heads, store, doc_uuid)
    end
  end

  @doc """
  The core judgment on an explicit head set — exposed so the violation
  path is testable without injecting a corrupt index row. Returns
  `{:violation, _}` naming the dominated/dominating pair if any head is a
  DAG-ancestor of another, else `:ok`.
  """
  @spec antichain_of(MapSet.t(), GenServer.server(), String.t()) :: :ok | {:violation, map()}
  def antichain_of(heads, store, doc_uuid) do
    if MapSet.size(heads) < 2 do
      :ok
    else
      Enum.find_value(heads, :ok, fn head ->
        case dominated_ancestor(
               store,
               seeds_of(store, head),
               MapSet.new(),
               MapSet.delete(heads, head)
             ) do
          nil ->
            nil

          ancestor ->
            {:violation,
             %{
               doc_uuid: doc_uuid,
               descendant: head,
               ancestor: ancestor,
               message:
                 "accepted head is a DAG-ancestor of another accepted head " <>
                   "of the same document; the seam must prune folded heads"
             }}
        end
      end)
    end
  end

  # Walk `head`'s STRICT ancestors following parent_id AND merge_parents,
  # returning the FIRST ancestor that is a member of `targets`, else nil.
  #
  # Bounded: a violation early-exits at the first dominated head, and a
  # clean check walks a SINGLE document's history once, holding only the
  # visited set — same class as `SiblingMerger.dag_reachable_from/2`. It is
  # per-doc bounded (by that doc's DAG depth), never corpus-wide; a
  # corpus-wide sweep would hold one such walk at a time, released per doc.
  defp dominated_ancestor(_store, [], _seen, _targets), do: nil

  defp dominated_ancestor(store, [id | rest], seen, targets) do
    cond do
      MapSet.member?(targets, id) ->
        id

      MapSet.member?(seen, id) ->
        dominated_ancestor(store, rest, seen, targets)

      true ->
        seen = MapSet.put(seen, id)

        case CommitStoreClient.get_commit(store, id) do
          {:ok, commit} -> dominated_ancestor(store, seeds(commit) ++ rest, seen, targets)
          :none -> dominated_ancestor(store, rest, seen, targets)
        end
    end
  end

  defp seeds_of(store, id) do
    case CommitStoreClient.get_commit(store, id) do
      {:ok, commit} -> seeds(commit)
      :none -> []
    end
  end

  defp seeds(commit) do
    [commit.parent_id | commit.merge_parents || []]
    |> Enum.reject(&is_nil/1)
  end
end
