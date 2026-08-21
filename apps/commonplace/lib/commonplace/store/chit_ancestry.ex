defmodule Commonplace.Store.ChitAncestry do
  @moduledoc """
  The chit ancestry invariant (spec §3): a chit's `parents` are NARRATIVE
  CLAIMS — "this moment follows that one" — and this module makes each
  claim mechanically checkable. The claim, precisely: for every doc
  pinned by BOTH the child and a parent, the child's pinned commit
  DESCENDS-OR-EQUALS the parent's pinned commit. [4] applied: recording
  a false claim is impossible (refused at the mint gate,
  `Commonplace.Store.ChitMint`) or loud (the `:chit_ancestry` registry
  entry re-verifies the resting corpus).

  ## The domain is the INTERSECTION of the two pins

  Only docs present in both `tree_pin`s are judged. A doc only in the
  child's pin is an ADDITION and a doc only in the parent's pin is a
  DELETION — both are legitimate tree edits between two moments, not
  descent violations, so neither enters the domain. A child whose pin
  shares no docs with its parent makes no descent claim at all and
  passes vacuously (`verdict([])`), which is distinct from the
  `parents: []` genesis case — there the chit claims no parent moment,
  so `check/2` returns `:ok` before fetching anything.

  ## Membership is the `{:doc_commit}` FACT, never the struct field

  "Commit X belongs to doc D" is decided exclusively by
  `CommitStoreClient.doc_has_commit?/3` — the authoritative
  `{:doc_commit, doc, id}` index row. A commit STRUCT's `.doc_uuid` is a
  stale first-writer trace, wrong for the fork-lineage slice of the live
  corpus (F2: 1.9% measured) — so `fetch/3` never loads a commit struct
  to decide ownership; the naive-field mistake is structurally
  unavailable here.

  ## Descent is a paged parent_id walk with cap honesty

  Descent is decided by walking `commit_log_from/3` newest-first from
  the child's pinned commit in bounded pages, up to a total budget of
  `CommitStore.max_commit_log_limit/0`. Equality short-circuits `:equal`
  before any walk. A walk that exhausts the budget without reaching the
  parent's commit is `{:indeterminate, :walk_capped}` — a NAMED
  non-answer that fails closed at the mint gate, never silently-true and
  never silently reported as tamper.

  ## Not on any read/converge path

  Nothing in reading, syncing, or converging documents calls this
  module. It runs at the mint gate (an explicit user action — refusing a
  mint refuses recording a false narrative, not convergence; R4
  preserved) and in the resting-state invariant registry.
  """

  alias Commonplace.Store.{Chit, CommitStore, CommitStoreClient}

  # Page size for the descent walk — the same paging shape as
  # DocBuilder's scan_for/5: fetch small pages so the common short
  # answer never pays for the whole budget's worth of rows.
  @walk_page 256

  @type descent_fact :: :equal | :descends | :not_ancestor | {:indeterminate, :walk_capped}

  @type row :: %{
          doc: String.t(),
          child_commit: binary(),
          parent_commit: binary(),
          child_member: boolean(),
          parent_member: boolean(),
          descent: descent_fact()
        }

  @type failure :: %{
          parent: binary() | nil,
          doc: String.t() | nil,
          child_commit: binary() | nil,
          parent_commit: binary() | nil,
          reason: term()
        }

  @doc """
  Check every parent claim of `child` independently. Returns `:ok` or
  `{:error, {:ancestry_violation, failures}}` where each failure names
  WHICH parent (merge chits carry ≥2), which doc, both pinned commits,
  and the reason. A parent cid with no stored chit is itself a named
  failure (`{:parent_chit_missing, cid}`) — an uncheckable claim is not
  a passing one.

  The `parents: []` genesis case returns `:ok` immediately: no parent
  moment is claimed, so there is nothing to verify (the no-claim case —
  see the moduledoc for how it differs from an empty intersection).
  """
  @spec check(GenServer.server(), Chit.t()) ::
          :ok | {:error, {:ancestry_violation, [failure()]}}
  def check(_store, %Chit{parents: []}), do: :ok

  def check(store, %Chit{} = child) do
    failures =
      Enum.flat_map(child.parents, fn parent_cid ->
        case CommitStoreClient.get_chit(store, parent_cid) do
          {:ok, %Chit{} = parent} ->
            check_against(store, child, parent)

          :none ->
            [
              %{
                parent: parent_cid,
                doc: nil,
                child_commit: nil,
                parent_commit: nil,
                reason: {:parent_chit_missing, parent_cid}
              }
            ]
        end
      end)

    case failures do
      [] -> :ok
      failures -> {:error, {:ancestry_violation, failures}}
    end
  end

  @doc """
  One parent's claim: fetch the facts, judge them purely, and stamp each
  failing row with the parent's cid. Returns the (possibly empty) list
  of failures.
  """
  @spec check_against(GenServer.server(), Chit.t(), Chit.t()) :: [failure()]
  def check_against(store, %Chit{} = child, %Chit{} = parent) do
    case store |> fetch(child, parent) |> verdict() do
      :ok -> []
      {:error, failures} -> Enum.map(failures, &Map.put(&1, :parent, parent.cid))
    end
  end

  @doc """
  The fetch half of the fetch/verdict split: gather every store-derived
  fact `verdict/1` needs, one row per doc in the INTERSECTION of the two
  pins (additions and deletions are out — see the moduledoc). Membership
  facts come from `doc_has_commit?/3` only; the descent fact skips the
  walk entirely when the two pinned commits are equal.
  """
  @spec fetch(GenServer.server(), Chit.t(), Chit.t()) :: [row()]
  def fetch(store, %Chit{} = child, %Chit{} = parent) do
    child.tree_pin
    |> Map.take(Map.keys(parent.tree_pin))
    |> Enum.map(fn {doc, child_commit} ->
      parent_commit = Map.fetch!(parent.tree_pin, doc)

      %{
        doc: doc,
        child_commit: child_commit,
        parent_commit: parent_commit,
        child_member: CommitStoreClient.doc_has_commit?(store, doc, child_commit),
        parent_member: CommitStoreClient.doc_has_commit?(store, doc, parent_commit),
        descent: descent(store, child_commit, parent_commit)
      }
    end)
  end

  @doc """
  The pure half: judge fetched rows with no store access. A row passes
  iff both membership facts are true AND the descent fact is `:equal` or
  `:descends`; anything else fails with a named reason —
  `:child_not_in_doc`, `:parent_not_in_doc`, `:not_ancestor`, or the
  cap-honesty non-answer `{:indeterminate, :walk_capped}` (membership
  failures are reported first: a pin that is not even a row of its doc
  makes the descent fact moot). `verdict([])` is `:ok` — a claim over an
  empty intersection asserts nothing.
  """
  @spec verdict([row()]) :: :ok | {:error, [failure()]}
  def verdict(rows) when is_list(rows) do
    case Enum.flat_map(rows, &row_failure/1) do
      [] -> :ok
      failures -> {:error, failures}
    end
  end

  defp row_failure(row) do
    case row_reason(row) do
      :ok ->
        []

      reason ->
        [
          %{
            parent: nil,
            doc: row.doc,
            child_commit: row.child_commit,
            parent_commit: row.parent_commit,
            reason: reason
          }
        ]
    end
  end

  defp row_reason(%{child_member: false}), do: :child_not_in_doc
  defp row_reason(%{parent_member: false}), do: :parent_not_in_doc
  defp row_reason(%{descent: descent}) when descent in [:equal, :descends], do: :ok
  defp row_reason(%{descent: :not_ancestor}), do: :not_ancestor
  defp row_reason(%{descent: {:indeterminate, :walk_capped} = capped}), do: capped

  # Equal short-circuits BEFORE any walk: the same commit is trivially
  # descends-or-equals, and paying a page fetch to learn that would make
  # the common unchanged-doc case the expensive one.
  defp descent(_store, commit_id, commit_id), do: :equal

  defp descent(store, child_commit, parent_commit) do
    walk(store, child_commit, parent_commit, 0, CommitStore.max_commit_log_limit())
  end

  # Paged newest-first parent_id walk from the child's pinned commit
  # (inclusive — harmless: equality was already short-circuited, so a
  # hit is always a PROPER ancestor). The walk is deliberately
  # doc-agnostic, exactly like commit_log_from itself: fork-lineage
  # chains cross `.doc_uuid` boundaries and must still be walkable.
  defp walk(_store, _from_id, _target, walked, budget) when walked >= budget,
    do: {:indeterminate, :walk_capped}

  defp walk(store, from_id, target, walked, budget) do
    page =
      CommitStoreClient.commit_log_from(store, from_id, limit: min(@walk_page, budget - walked))

    if Enum.any?(page, &(&1.id == target)) do
      :descends
    else
      case List.last(page) do
        # An empty page means from_id has no stored commit row — the
        # chain is unwalkably absent, which membership already reports;
        # descent-wise the parent was not found.
        nil -> :not_ancestor
        %{parent_id: nil} -> :not_ancestor
        %{parent_id: parent_id} -> walk(store, parent_id, target, walked + length(page), budget)
      end
    end
  end
end
