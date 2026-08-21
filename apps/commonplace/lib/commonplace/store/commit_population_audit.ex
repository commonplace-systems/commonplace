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

  ⛔ GENESIS-ONLY PARTITION — `orphaned_from_latest` is SPLIT, not filtered (plan
  #14171/#14173, paravel #14168, coder #14170). `ensure_genesis` writes
  `{:commit}`+`{:doc_commit}` but NO `{:latest}` (`put_bare_commit_with_index`,
  like `import_commit`); `{:latest}` is set only on the FIRST ADVANCE
  (`create_chained_commit`), never at genesis — the documented contract
  (`accepted_heads_coverage.ex:15`: a "doc with commits but no `{:latest,_}` (an
  `ensure_genesis`-only … doc)" is the population SiblingMerger never processes,
  and `all_doc_uuids` correctly misses). So genesis-only docs land in
  `orphaned_from_latest` BY CONSTRUCTION, benignly.

  A green gated on `orphaned_from_latest` empty could therefore NEVER go green — the
  mirror of the withdrawn §4 decoration (a check that cannot go RED): both stop
  carrying information because the output no longer varies with the subject, and a
  single REAL orphan would hide among the expected genesis-only entries
  (8,332-hiding-605, in the instrument built to find things). So:

    * `orphaned_genesis_only` = docs in `orphaned_from_latest` whose ENTIRE
      `{:doc_commit}` set is EXACTLY `{Commit.genesis(doc_uuid).id}`. The predicate
      is a RECONSTRUCTION, not shape-equality: the genesis id is a pure function of
      the doc uuid (timestamp is not hashed — `commit.ex`), so we recompute it and
      require the stored set to match. A doc merely tagged `kind: :genesis` cannot
      satisfy it; a real genesis-only doc cannot fail it.
    * `orphaned_other` = the rest — docs that own commits BEYOND genesis yet have no
      head. THIS is the under-enumeration World-B hunts (incl. interrupted docs that
      wrote content but never advanced `{:latest}`).

  `green` gates on `orphaned_other` (not `orphaned_from_latest`); `orphaned_genesis_only`
  is an informational count that never forces red. Both are reported completely.

  ⚠️ SCOPE (coder #14170): `orphaned_genesis_only` is provably benign FOR §4
  (SiblingMerger short-circuits `latest == :none`), NOT benign in general — whether a
  reserved-but-never-written doc SHOULD exist is a tree/schema question this audit
  does not answer. The partition makes the number interpretable; the disposition of
  those docs stays open.

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

  alias Commonplace.Store.{Commit, CommitStore}
  require Logger

  @type populations :: %{
          p_latest: MapSet.t(),
          ids_from_structs: MapSet.t(),
          doc_commit_ids: %{optional(String.t()) => MapSet.t()},
          index_ready: boolean()
        }

  @type report :: %{
          p_doccommit: non_neg_integer(),
          p_latest: non_neg_integer(),
          ids_from_structs: non_neg_integer(),
          ids_from_doc_index: non_neg_integer(),
          orphaned_from_latest: [String.t()],
          orphaned_genesis_only: [String.t()],
          orphaned_other: [String.t()],
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
        "(genesis_only=#{length(report.orphaned_genesis_only)} other=#{length(report.orphaned_other)}) " <>
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

  # A doc is genesis-only iff its ENTIRE {:doc_commit} set is exactly the one
  # genesis id — recomputed from the doc uuid (a pure function; timestamp is not
  # hashed), NOT inferred from a metadata tag. Reconstruction, not shape-equality.
  #
  # ⭐ FAILS SAFE (plan #14176): if a stored genesis id ever DIVERGED from the
  # reconstruction, the doc would fail this predicate and drop to orphaned_other
  # — a benign doc flagged as a real orphan (false RED, costs attention), NEVER a
  # real orphan classified benign (false green, hides the condition). The
  # predicate errs toward false-red > false-clear by construction; do not "relax"
  # it to a metadata-tag check, which would invert that direction.
  defp genesis_only?(doc, doc_commit_ids) do
    MapSet.equal?(
      Map.get(doc_commit_ids, doc, MapSet.new()),
      MapSet.new([Commit.genesis(doc).id])
    )
  end

  @doc """
  The PURE go/no-go over the populations map — no store access, so it is the
  same tested code over fixtures, a stopped-serve store, or captured populations.
  `p_doccommit` and `ids_from_doc_index` are DERIVED here from `doc_commit_ids`
  (one source of truth). Returns the diffs (sorted member lists) incl. the
  genesis-only / other partition of `orphaned_from_latest`, the population sizes,
  the index readiness, `vacuous`, and `green`.

  `green` ⟺ `index_ready` AND not `vacuous` AND `orphaned_other == []` AND
  `dangling_latest == []` AND both Axis-B diffs empty. It gates on `orphaned_other`
  (beyond-genesis), NOT `orphaned_from_latest`: genesis-only docs are benign by
  contract and would make green permanently unreachable. `vacuous` ⟺ `P_doccommit`
  empty OR `ids_from_structs` empty (an empty scan must not read as full coverage).
  A not-ready index forces `green: false` regardless of the diffs, which over a
  half-built index are not authoritative.
  """
  @spec verdict(populations()) :: report()
  def verdict(%{
        p_latest: p_latest,
        ids_from_structs: ids_from_structs,
        doc_commit_ids: doc_commit_ids,
        index_ready: index_ready
      }) do
    # p_doccommit and ids_from_doc_index are DERIVED from the grouped map, so the
    # doc population and the doc-index id set cannot disagree with the per-doc sets
    # the partition uses (one source of truth, no redundant inputs to keep in sync).
    p_doccommit = doc_commit_ids |> Map.keys() |> MapSet.new()

    ids_from_doc_index =
      doc_commit_ids |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    orphaned = MapSet.difference(p_doccommit, p_latest)

    {genesis_only, other} =
      orphaned
      |> MapSet.to_list()
      |> Enum.split_with(&genesis_only?(&1, doc_commit_ids))

    orphaned_genesis_only = Enum.sort(genesis_only)
    orphaned_other = Enum.sort(other)

    dangling_latest = sorted_diff(p_latest, p_doccommit)
    commits_missing_from_doc_index = sorted_diff(ids_from_structs, ids_from_doc_index)
    dangling_doc_index = sorted_diff(ids_from_doc_index, ids_from_structs)

    vacuous = MapSet.size(p_doccommit) == 0 or MapSet.size(ids_from_structs) == 0

    # green gates on orphaned_OTHER (beyond-genesis), NOT orphaned_from_latest:
    # genesis-only docs are benign-by-contract and would make green unreachable.
    all_clean =
      orphaned_other == [] and dangling_latest == [] and
        commits_missing_from_doc_index == [] and dangling_doc_index == []

    %{
      p_doccommit: MapSet.size(p_doccommit),
      p_latest: MapSet.size(p_latest),
      ids_from_structs: MapSet.size(ids_from_structs),
      ids_from_doc_index: MapSet.size(ids_from_doc_index),
      orphaned_from_latest: Enum.sort(MapSet.to_list(orphaned)),
      orphaned_genesis_only: orphaned_genesis_only,
      orphaned_other: orphaned_other,
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
