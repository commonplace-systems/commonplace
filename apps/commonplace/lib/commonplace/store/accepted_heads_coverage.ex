defmodule Commonplace.Store.AcceptedHeadsCoverage do
  @moduledoc """
  BUILD-1 §4 coverage check — the gate that must run GREEN before
  SiblingMerger's scan-fallback is removed (plan #13772). It converts the
  reasoning "§3 reached `{:ready,v}`, so coverage is total" into a MEASURED
  artifact over the live corpus.

  ## Why `:ready` is not enough, and why `all_doc_uuids` is the right denominator

  `{:ready,v}` proves the backfill completed a pass over the docs it SAW
  (`all_doc_uuids`), not that every doc SiblingMerger could touch is indexed.
  The distinction turns on leg 5: `SiblingMerger.maybe_merge_siblings/3`
  short-circuits `latest_commit == :none → {:ok, :no_siblings}`
  (`sibling_merger.ex:115`) BEFORE the `:latest` guard or the fallback. So a
  doc with commits but no `{:latest,_}` (an `ensure_genesis`-only /
  interrupted / pre-seam doc — invisible to `all_doc_uuids`, which enumerates
  strictly from `{:latest,_}`) is exactly the population SiblingMerger never
  processes. ⇒ the population §4 affects is precisely the has-`:latest` set,
  which IS `all_doc_uuids`. For §4, that denominator is CORRECT, not blind —
  the docs it misses are the docs the fallback never covered either.

  ## The predicate

  The scan-fallback fires (today) for a doc that passes the `:115`
  short-circuit (has `:latest`) but whose head set does NOT contain the
  commit `:latest` points at — SiblingMerger's `:171` guard
  `MapSet.member?(heads, latest.id)`. §4's safety predicate is therefore:

      ∀ doc ∈ all_doc_uuids : latest.id ∈ accepted_heads_indexed(doc).heads

  A doc failing it would, post-§4 (fallback removed), silently stop merging
  siblings. This check reports every such doc, so the failure is a MEASURED
  zero before removal rather than a quiet divergence after.

  ## Field discrimination (presence ≠ validity)

  A row being PRESENT is not coverage: a stale/partial row that lacks
  `latest.id` passes a "has a row?" check but FAILS the `:171` guard and
  takes the fallback. `covered?/2` asserts membership, not presence — so the
  must-find control (a row present but missing `latest.id`) is caught.

  ## Denominator cross-check (plan #13772 #4)

  Both the backfill and this check enumerate via `all_doc_uuids`, so a bug
  that under-enumerates `{:latest,_}` would hide docs from BOTH and "0
  missing" would look clean. `CommitStore.latest_key_count/1` counts the
  `{:latest,_}` keyspace by an INDEPENDENT path; `denominator_consistent`
  is `examined == latest_key_count`. A false there means the denominator
  itself is not trustworthy and the zero must not be believed.

  Read-only: `all_doc_uuids`, `latest_commit` and `accepted_heads_indexed`
  are all point-reads/keyspace-scans, no DAG walk. Safe to run against a live
  serve (via erpc to already-loaded `CommitStore`).
  """

  alias Commonplace.Store.CommitStore
  require Logger

  @type report :: %{
          examined: non_neg_integer(),
          latest_key_count: non_neg_integer(),
          denominator_consistent: boolean(),
          covered: non_neg_integer(),
          missing: [String.t()],
          green: boolean()
        }

  @doc """
  Run the coverage check. `green` is true iff every examined doc satisfies
  the predicate AND the denominator cross-check holds — i.e. §4 may proceed.
  """
  @spec check(GenServer.server()) :: report()
  def check(store \\ CommitStore) do
    docs = store |> CommitStore.all_doc_uuids() |> MapSet.to_list()
    latest_key_count = CommitStore.latest_key_count(store)

    missing = docs |> Enum.reject(&covered?(store, &1)) |> Enum.sort()
    denominator_consistent = length(docs) == latest_key_count

    report = %{
      examined: length(docs),
      latest_key_count: latest_key_count,
      denominator_consistent: denominator_consistent,
      covered: length(docs) - length(missing),
      missing: missing,
      green: missing == [] and denominator_consistent
    }

    Logger.info(
      "AcceptedHeadsCoverage: examined=#{report.examined} " <>
        "latest_key_count=#{report.latest_key_count} " <>
        "denominator_consistent=#{report.denominator_consistent} " <>
        "covered=#{report.covered} missing=#{length(report.missing)} green=#{report.green}"
    )

    report
  end

  # A doc is COVERED iff SiblingMerger's `:171` guard would be TRUE for it:
  # its accepted-head index resolves to a set that CONTAINS the commit
  # `:latest` currently points at. Membership, not presence — a stale row
  # lacking `latest.id` is NOT covered (it would take the removed fallback).
  # `all_doc_uuids` only yields docs with `:latest`, so `latest_commit` and
  # `accepted_heads_indexed` both succeed; the `else` is defensive and
  # conservative (unresolvable ⇒ not covered ⇒ reported).
  defp covered?(store, doc) do
    with {:ok, latest} <- CommitStore.latest_commit(store, doc),
         {:ok, heads} <- CommitStore.accepted_heads_indexed(store, doc) do
      MapSet.member?(heads, latest.id)
    else
      _ -> false
    end
  end
end
