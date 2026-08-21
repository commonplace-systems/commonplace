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

  ## Non-vacuity (a green must mean coverage, not emptiness)

  `green` REQUIRES `examined > 0`. An empty corpus — the exact off-by-one
  `--data-dir` that produced one vacuous §3 run — otherwise reports
  `missing == []` and would authorise §4 on a store that was never examined
  ("every doc satisfies the predicate" and "there are no docs" share one
  observable). So `examined == 0` yields `vacuous: true, green: false` with
  the reason visible (commonplace-coder #13795, the same shape as PR #7's
  non-vacuity gate).

  ## What this gate does NOT establish (routed, not faked)

  Its denominator is `all_doc_uuids`, whose trustworthiness rests on the
  `{:latest,_}` range bound (`commit_store.ex` CX-mg8s — correct for the
  ASCII-string uuids in use today). This gate CANNOT detect `all_doc_uuids`
  UNDER-enumerating its own keyset: any cheap same-keyspace count shares that
  bound (a bug hits both identically), and CubDB keys are unique so a
  count-vs-set cross-check can never go red. Genuine under-enumeration
  detection needs an INDEPENDENT full-population enumeration (from the
  `{:commit,_}` / `{:doc_commit,_}` keyspace) — which is exactly the owed
  World-B `:commit` standing audit (plan #13407), not this host-cheap gate.
  We do not ship a can't-go-red cross-check to imply a guarantee we don't
  have.

  Read-only: `all_doc_uuids`, `latest_commit` and `accepted_heads_indexed`
  are all point-reads/keyspace-scans, no DAG walk. Safe to run against a live
  serve (via erpc to already-loaded `CommitStore`).
  """

  alias Commonplace.Store.CommitStore
  require Logger

  @type report :: %{
          examined: non_neg_integer(),
          covered: non_neg_integer(),
          missing: [String.t()],
          vacuous: boolean(),
          green: boolean()
        }

  @doc """
  Run the coverage check. `green` is true iff the corpus is non-empty AND
  every examined doc satisfies the predicate — i.e. §4 may proceed.
  """
  @spec check(GenServer.server()) :: report()
  def check(store \\ CommitStore) do
    docs = store |> CommitStore.all_doc_uuids() |> MapSet.to_list()
    examined = length(docs)
    missing = docs |> Enum.reject(&covered?(store, &1)) |> Enum.sort()
    vacuous = examined == 0

    report = %{
      examined: examined,
      covered: examined - length(missing),
      missing: missing,
      vacuous: vacuous,
      green: not vacuous and missing == []
    }

    Logger.info(
      "AcceptedHeadsCoverage: examined=#{report.examined} covered=#{report.covered} " <>
        "missing=#{length(report.missing)} vacuous=#{report.vacuous} green=#{report.green}"
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
