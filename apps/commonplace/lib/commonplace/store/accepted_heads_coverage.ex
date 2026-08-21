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

  ## Fetch / verdict split (Option B — plan #13835, the structural version)

  The go/no-go is a PURE function `verdict/1` over `[{doc, latest_id, heads}]`
  — the TESTED code, incl. the #3a/#3b must-find cases as pure-data unit
  tests. `check/1` = `fetch_entries/1` (the only part that touches the store)
  then `verdict/1`. The live coverage run (§4 step 2) assembles the SAME
  entries via resident erpc readers and calls THIS `verdict/1` on the runner's
  node — so the decision code is the tested function, not a hand-transcription
  that could diverge (there is no transcription to validate; nothing to keep
  in sync). The residual untested surface is only the mechanical FETCH, whose
  slip shows up as a wrong denominator that `examined > 0` and the
  fetch+verdict-vs-`check/1` fixture check both bear on. And because
  `verdict/1`'s INPUT is a plain data structure, the live run can LOG the
  entries + the verdict together, so the gate's decision is a durable artifact
  re-verdictable later without re-reading the moving live store (boss #13836:
  the transient-observable → capture law, the same one the vanishing
  MemoryMax taught tonight).

  ⚠️ On a LIVE serve the fetch's two per-doc reads (`latest_commit` then
  `accepted_heads_indexed`) can STRADDLE a seam head-advance and report a
  covered doc as missing — a false RED (never a false green; it cannot
  wrongly authorise §4). Step 2 mitigates it (single-read variant, or
  re-read `missing` and report both passes so skew is a visible number); the
  quiescent uses here (tests, a stopped-serve store) do not hit it.
  """

  alias Commonplace.Store.CommitStore
  require Logger

  @type entry :: {doc :: String.t(), latest_id :: String.t() | nil, heads :: MapSet.t()}
  @type report :: %{
          examined: non_neg_integer(),
          covered: non_neg_integer(),
          missing: [String.t()],
          vacuous: boolean(),
          green: boolean()
        }

  @doc """
  Run the coverage check against a store: `fetch_entries/1` then `verdict/1`.
  Behavior-preserving over the pre-split `check/1`.
  """
  @spec check(GenServer.server()) :: report()
  def check(store \\ CommitStore) do
    report = store |> fetch_entries() |> verdict()

    Logger.info(
      "AcceptedHeadsCoverage: examined=#{report.examined} covered=#{report.covered} " <>
        "missing=#{length(report.missing)} vacuous=#{report.vacuous} green=#{report.green}"
    )

    report
  end

  @doc """
  Assemble the coverage entries from the store — the ONLY store-touching part.
  One `{doc, latest_id, heads}` per doc in `all_doc_uuids`. A doc that fails
  to resolve (a live-serve race between enumerate and read) becomes
  `{doc, nil, ∅}`, which `verdict/1` counts as missing (conservative — a
  false red, never a false green). The live §4-step-2 run mirrors this
  assembly over resident erpc readers; see the moduledoc's skew note.
  """
  @spec fetch_entries(GenServer.server()) :: [entry()]
  def fetch_entries(store) do
    store
    |> CommitStore.all_doc_uuids()
    |> MapSet.to_list()
    |> Enum.map(&entry_for(store, &1))
  end

  @doc """
  The PURE go/no-go over coverage entries — no store access, so it is the
  same tested code whether run over fixtures, a stopped-serve store, or the
  live run's fetched-and-captured entries. A doc is COVERED iff its head set
  CONTAINS the commit `:latest` points at (SiblingMerger's `:171` guard):
  membership, not presence — a stale row lacking `latest_id` is NOT covered.
  `green` requires `examined > 0` (non-vacuity) AND `missing == []`.
  """
  @spec verdict([entry()]) :: report()
  def verdict(entries) do
    examined = length(entries)
    missing = entries |> Enum.reject(&covered_entry?/1) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    vacuous = examined == 0

    %{
      examined: examined,
      covered: examined - length(missing),
      missing: missing,
      vacuous: vacuous,
      green: not vacuous and missing == []
    }
  end

  defp covered_entry?({_doc, latest_id, heads}), do: MapSet.member?(heads, latest_id)

  defp entry_for(store, doc) do
    with {:ok, latest} <- CommitStore.latest_commit(store, doc),
         {:ok, heads} <- CommitStore.accepted_heads_indexed(store, doc) do
      {doc, latest.id, heads}
    else
      _ -> {doc, nil, MapSet.new()}
    end
  end
end
