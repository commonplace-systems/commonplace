defmodule Commonplace.Store.CommitPopulationAudit do
  @moduledoc """
  World-B `:commit` full-population audit (plan #13407) — the INDEPENDENT
  instrument the §4 coverage gate (`AcceptedHeadsCoverage`) structurally cannot
  be.

  That gate's denominator is `all_doc_uuids`, which enumerates `{:latest,_}`. It
  cannot detect `all_doc_uuids` UNDER-enumerating its own keyset: a same-keyspace
  cross-check shares the range bound (the shared suspect — CX-mg8s), and unique
  CubDB keys mean a count-vs-set check can never go red (§4 ruling #4, withdrawn
  as decoration). Genuine under-enumeration detection needs a population keyed on
  something structurally independent of `{:latest,_}` — this audit.

  ## ⛔ The trap: `{:commit}` struct `.doc_uuid` is NOT doc ownership

  The naive reading of "enumerate from `{:commit,_}`" — scan the structs and
  project `.doc_uuid` — is wrong, silently. `.doc_uuid` is a debug trace of the
  FIRST writer, EXCLUDED from the id hash (`commit.ex:52`); with convergent
  genesis ids and fork deep-copy a commit id is shared across docs. Using it as
  ownership would attribute a forked doc's commits to its SOURCE and
  fabricate/hide orphans. The authoritative doc→commit map is the
  `{:doc_commit, doc_uuid, id}` index KEY. This module uses the `{:commit}`
  keyspace by its KEY (the id) only — never the struct value's `.doc_uuid`.

  ## Two axes, four diffs

  **Axis A — doc-level (the primary):** does `{:latest}` cover every doc that owns
  commits?

    * `orphaned_from_latest` = `P_doccommit \\ P_latest` — docs that OWN commits
      but have no head pointer. THE primary target (`all_doc_uuids`
      under-enumeration).
    * `dangling_latest` = `P_latest \\ P_doccommit` — a head pointer for a doc with
      no commit-index rows (corruption).

  ⚠️ INTERPRETATION NOTE — genesis-only docs (pending plan ruling). `ensure_genesis`
  writes `{:commit}`+`{:doc_commit}` but NOT `{:latest}` (it calls
  `put_bare_commit_with_index`, like `import_commit`); a doc that has only ever had
  a genesis committed therefore appears in `orphaned_from_latest`. Whether that is a
  real orphan (unreachable data) or a benign "reserved, not yet written" state is a
  domain judgment this module does not make: it reports `orphaned_from_latest`
  COMPLETELY (every doc with commits but no head). If the host-gated run shows the
  set is dominated by genesis-only docs, the reader should bring the real number to
  plan for a genesis-aware refinement (distinguish genesis-only from
  has-content-but-no-head) rather than either silently filtering or treating all as
  equally severe. Reporting complete-and-honest beats a built-in guess.

  **Axis B — commit-id-level:** is `P_doccommit` (Axis A's reference, itself an
  index) trustworthy against the ground-truth commit OBJECTS?

    * `commits_missing_from_doc_index` = `ids_from_structs \\ ids_from_doc_index`
      — a commit object with no index row (`do_all_commit_ids_for_doc` would miss
      it; could hide a doc from Axis A's reference).
    * `dangling_doc_index` = `ids_from_doc_index \\ ids_from_structs` — an index
      row for a commit object that does not exist.

  ## Fetch / verdict split (Option B) + non-vacuity + ledger precondition

  `verdict/1` is PURE over a plain populations map, so the go/no-go is tested
  without a store (incl. every must-find control as pure-data). `fetch_populations/1`
  is the only store touch. `green` requires the `{:doc_commit}` index READY, the
  corpus NON-EMPTY (`|P_doccommit| > 0` AND `|ids_from_structs| > 0` — "every doc
  covered" and "there are no docs" share one observable), AND all four diffs
  empty. A not-ready index is `index_ready: false, green: false`: its populations
  are partial and their diffs are NOT authoritative, so the audit reports
  index-unavailable rather than emitting a fabricated full-population diff over a
  half-built index (`false clear > false open`).

  ## Run model — QUIESCENT store, not live erpc

  Not run in the live serve. The authoritative run opens the STOPPED serve's
  data_dir with its OWN `CommitStore` (sole opener), under the §3 ceremony +
  `MemorySwapMax=0` (host-gated for the O(#commits) `{:commit}` value-deser cost).
  A LIVE erpc run is DEFERRED: the enumerators this module calls are not resident
  on the (behind) serve, so erpc'ing them would force-load working-tree code — a
  WRITE (the live-probe hazard) — and live scans straddle concurrent writes
  (transient false orphan; a false RED, never a false green). See
  `Mix.Tasks.Commonplace.AuditCommitPopulation` and the design doc
  `docs/plans/2026-08-21-world-b-commit-population-audit-design.md`.
  """

  alias Commonplace.Store.CommitStore
  require Logger

  @type populations :: %{
          p_doccommit: MapSet.t(),
          p_latest: MapSet.t(),
          ids_from_structs: MapSet.t(),
          ids_from_doc_index: MapSet.t(),
          index_ready: boolean()
        }

  @type report :: %{
          p_doccommit: non_neg_integer(),
          p_latest: non_neg_integer(),
          ids_from_structs: non_neg_integer(),
          ids_from_doc_index: non_neg_integer(),
          orphaned_from_latest: [String.t()],
          dangling_latest: [String.t()],
          commits_missing_from_doc_index: [binary()],
          dangling_doc_index: [binary()],
          index_ready: boolean(),
          vacuous: boolean(),
          green: boolean()
        }

  @doc """
  Run the audit against a store: `fetch_populations/1` then `verdict/1`, logging
  a one-line summary. The full report (member lists included) is the return
  value and the durable artifact the task captures.
  """
  @spec check(GenServer.server()) :: report()
  def check(store \\ CommitStore) do
    report = store |> fetch_populations() |> verdict()

    Logger.info(
      "CommitPopulationAudit: p_doccommit=#{report.p_doccommit} p_latest=#{report.p_latest} " <>
        "ids_from_structs=#{report.ids_from_structs} ids_from_doc_index=#{report.ids_from_doc_index} " <>
        "orphaned_from_latest=#{length(report.orphaned_from_latest)} " <>
        "dangling_latest=#{length(report.dangling_latest)} " <>
        "commits_missing_from_doc_index=#{length(report.commits_missing_from_doc_index)} " <>
        "dangling_doc_index=#{length(report.dangling_doc_index)} " <>
        "index_ready=#{report.index_ready} vacuous=#{report.vacuous} green=#{report.green}"
    )

    report
  end

  @doc """
  Read the four populations (ONE unbounded `CommitStore.population_scan/1` pass —
  no range bound to share a truncation, plan #14155) plus the `{:doc_commit}`
  index readiness — the ONLY store-touching part. A keyspace scan, not a DAG walk.
  """
  @spec fetch_populations(GenServer.server()) :: populations()
  def fetch_populations(store \\ CommitStore) do
    store
    |> CommitStore.population_scan()
    |> Map.put(
      :index_ready,
      CommitStore.doc_commit_index_state(store) == CommitStore.doc_commit_index_ready()
    )
  end

  @doc """
  The PURE go/no-go over the populations map — no store access, so it is the
  same tested code over fixtures, a stopped-serve store, or captured populations.
  Returns the four diffs (sorted member lists), the population sizes, the index
  readiness, `vacuous`, and `green`.

  `green` ⟺ `index_ready` AND not `vacuous` AND all four diffs empty. `vacuous`
  ⟺ `P_doccommit` empty OR `ids_from_structs` empty (an empty scan must not read
  as full coverage). A not-ready index forces `green: false` regardless of the
  diffs, which over a half-built index are not authoritative.
  """
  @spec verdict(populations()) :: report()
  def verdict(%{
        p_doccommit: p_doccommit,
        p_latest: p_latest,
        ids_from_structs: ids_from_structs,
        ids_from_doc_index: ids_from_doc_index,
        index_ready: index_ready
      }) do
    orphaned_from_latest = sorted_diff(p_doccommit, p_latest)
    dangling_latest = sorted_diff(p_latest, p_doccommit)
    commits_missing_from_doc_index = sorted_diff(ids_from_structs, ids_from_doc_index)
    dangling_doc_index = sorted_diff(ids_from_doc_index, ids_from_structs)

    vacuous = MapSet.size(p_doccommit) == 0 or MapSet.size(ids_from_structs) == 0

    all_clean =
      orphaned_from_latest == [] and dangling_latest == [] and
        commits_missing_from_doc_index == [] and dangling_doc_index == []

    %{
      p_doccommit: MapSet.size(p_doccommit),
      p_latest: MapSet.size(p_latest),
      ids_from_structs: MapSet.size(ids_from_structs),
      ids_from_doc_index: MapSet.size(ids_from_doc_index),
      orphaned_from_latest: orphaned_from_latest,
      dangling_latest: dangling_latest,
      commits_missing_from_doc_index: commits_missing_from_doc_index,
      dangling_doc_index: dangling_doc_index,
      index_ready: index_ready,
      vacuous: vacuous,
      green: index_ready and not vacuous and all_clean
    }
  end

  defp sorted_diff(a, b), do: MapSet.difference(a, b) |> MapSet.to_list() |> Enum.sort()
end
