# World-B `:commit` full-population audit — design

**Status:** DESIGN, awaiting plan ratification (plan #13407; carries from plan #14131).
**Author:** cell-1. **Date:** 2026-08-21.
**Related:** `2026-08-21-section-4-scan-fallback-removal-design.md` (ruling #4 routes
under-enumeration detection here), `AcceptedHeadsCoverage` (the host-cheap gate whose
denominator this audit is the independent counterpart to).

## Why this exists

The §4 coverage gate (`AcceptedHeadsCoverage`) proves every doc in `all_doc_uuids`
has its `:latest` inside its accepted-head set. Its denominator is `all_doc_uuids`,
which enumerates the `{:latest,_}` keyspace. **It cannot, by construction, detect
`all_doc_uuids` UNDER-enumerating its own keyset:** any same-keyspace cross-check
shares the range bound (the shared suspect — cf. CX-mg8s, where a `<<255>>` upper
bound silently dropped ~1/256 of ids), and unique CubDB keys mean a count-vs-set
check can never go red (§4 ruling #4 — withdrawn as decoration).

Genuine under-enumeration detection needs an **INDEPENDENT instrument**: a
full-population enumeration keyed on something structurally independent of
`{:latest,_}`. That is this audit.

## ⛔ The trap: the `{:commit}` struct's `.doc_uuid` is NOT doc ownership

The obvious reading of "enumerate from `{:commit,_}`" — scan the commit structs and
project `.doc_uuid` — is **wrong**, and silently so. `commit.ex:52` states `.doc_uuid`
is "a debugging trace of which uuid FIRST wrote the commit", deliberately EXCLUDED from
the id hash. Two consequences make it unusable as ownership:

- **Convergent ids across docs**: `genesis/1` makes a commit id a pure function of its
  uuid, so re-creations across docs share an id; a fork deep-copies. The struct
  `.doc_uuid` records only the first writer.
- A naive `P = {struct.doc_uuid}` would attribute a forked doc's commits to its SOURCE,
  fabricating orphans (or hiding real ones) — a wrong World-B verdict that looks clean.

The authoritative doc→commit ownership is the **`{:doc_commit, doc_uuid, id}` index key**,
written with the owning `doc_uuid` at store time (`commit_store.ex:3431`). So the audit
uses the `{:commit}` keyspace **by its KEY (the id) only**, never the struct value's
`.doc_uuid`.

## Two axes, four diffs

**Axis A — doc-level (the primary World-B): does `{:latest}` cover every doc that owns
commits?**

| Population | Source | Independent of `{:latest}`? |
|-----------|--------|------------------------------|
| `P_doccommit` | `{:doc_commit, doc_uuid, id}` keys → `doc_uuid` | YES — the authoritative doc→commit map, written per-commit, never via `{:latest}` |
| `P_latest` | `{:latest, doc_uuid}` = `all_doc_uuids` | NO — the suspect |

- **`orphaned_from_latest` = `P_doccommit \ P_latest`** — docs that OWN commits but have
  no head pointer. **The primary target**: `all_doc_uuids` under-enumeration.
- **`dangling_latest` = `P_latest \ P_doccommit`** — a head pointer for a doc with no
  commit-index rows. Corruption (report separately).

**Axis B — commit-id-level: is `P_doccommit` itself trustworthy?** Axis A's reference is
an index (its own range bound — CX-mg8s lived in the `{:doc_commit}` bound at
`commit_store.ex:3274`). Axis B validates it against the ground-truth commit OBJECTS, by
id:

| Set | Source |
|-----|--------|
| `ids_from_structs` | `{:commit, id}` keys (the commit objects) |
| `ids_from_doc_index` | `{:doc_commit, _, id}` keys |

- **`commits_missing_from_doc_index` = `ids_from_structs \ ids_from_doc_index`** — a
  commit object with no index row (`do_all_commit_ids_for_doc` would miss it, and it
  could hide a doc from Axis A's reference).
- **`dangling_doc_index` = `ids_from_doc_index \ ids_from_structs`** — an index row for a
  commit object that does not exist.

## The verdict (PURE, tested — fetch/verdict split, as `AcceptedHeadsCoverage`)

`verdict/1` takes the populations/sets (as `MapSet`s) and returns the four diffs above.
`green` ⟺ **all four diffs empty AND non-vacuous** (`|P_doccommit| > 0` AND
`|ids_from_structs| > 0`). An empty scan — wrong `--data-dir`, unopened store — must be
`vacuous: true, green: false` ("every doc is covered" and "there are no docs" share one
observable; same discipline as the §3/§4 non-vacuity gate). The report carries every
population/set size and every diff's members, so the verdict is re-computable from the
captured artifact without re-reading the moving store.

## Ledger precondition — audit every silent-nothing input BEFORE trusting a zero

(plan #14112, the carry.) Each input that could be silently empty must REFUSE or
read as `vacuous`, never as "all covered" — **false clear > false open**:

- the `{:commit}` or `{:doc_commit}` `CubDB.select` raising or returning `[]` on an
  unopened/wrong store → `vacuous`, not green;
- an erpc read timing out → `{:error, …}`, never `[]` coerced to an empty population;
- the `{:doc_commit}` index in a not-ready state (`@doc_commit_index_state_key`) →
  reported as an index-unavailable finding, not a silent empty `P_doccommit` that
  would fabricate a full-population `orphaned_from_latest`.

A **corpus positive control**: before believing any empty diff, assert both references
were non-empty (`|P_doccommit| > 0` AND `|ids_from_structs| > 0`) — a zero against an
empty corpus is not an all-clear.

## Durable enumerable report — NOT a standing alarm (plan #14131 carry)

First cut is a **mix task run at audit time** that captures the artifact (the honest
home; a report read when the audit runs). It is NOT wired as a recurring alarm. **If
it is ever made standing/recurring, its findings inherit the framework-gap** (invariant
`:alarm` has zero handlers — RELAY ≠ RESOLUTION ≠ EMISSION) and need the ledger +
enumerator before they mean anything; the ledger precondition above is the entry cost.

## Host-safety & the RUN gate

- Enumeration STREAMS: `CubDB.select` piped through `Stream` into `MapSet`
  accumulation — no structs accumulated. Resident memory is O(#commits) for the id sets
  (`ids_from_structs`, `ids_from_doc_index`) and O(#docs) for the doc populations.
- **The `{:commit}` scan reads the KEY (the id) only; it does NOT read the struct's
  `.doc_uuid`** (see the trap). But `CubDB.select` still deserializes each `{:commit,id}`
  VALUE (the whole Commit struct) before we discard it — O(#commits) CPU, wasted-but-
  unavoidable via `select`. The `{:doc_commit}` and `{:latest}` scans have cheap values
  (`true` / an id). This CPU cost is the concrete reason the run is host-gated.
- **Additive only**: a new module + new `CommitStore` read enumerators + a task; nothing
  on any write/converge path changes.
- The RUN is **host-gated** (§3 ceremony + `MemorySwapMax=0`; bursar-bulk-op-hazard is
  the precedent — an O(store) scan). Build lands test-green and inert; boss executes the
  run when plan + cell-1 gate it.
- ⛔ **The authoritative run is against a QUIESCENT store (stopped serve), NOT live erpc**
  — for two reasons. (1) The new enumerators are NOT resident on the running serve (it is
  behind); an erpc call to them would FORCE-LOAD working-tree code into the live node =
  a WRITE (CLAUDE.md live-probe hazard). A live World-B waits until a deploy ships these
  functions. (2) On a live store the scans straddle concurrent writes → a transient false
  orphan (a false RED, never a false green: a real orphan cannot be made to look covered).
  The stopped-store run (task opens the data_dir with its OWN code, sole opener) has
  neither problem — and it is exactly the §3 ceremony's window.

## Proposed shape (mirrors the §3/§4 artifacts)

- New `CommitStore` read enumerators (keyspace scans, mirroring `all_doc_uuids/1`):
  `all_doc_commit_doc_uuids/1` (`{:doc_commit,_,_}` → doc_uuids), `all_commit_ids/1`
  (`{:commit,_}` keys → ids), `all_doc_commit_ids/1` (`{:doc_commit,_,id}` → ids).
- `Commonplace.Store.CommitPopulationAudit` — `fetch_populations/1` (the only store
  touch) + PURE `verdict/1`; report `%{p_doccommit, p_latest, ids_from_structs,
  ids_from_doc_index, orphaned_from_latest, dangling_latest, commits_missing_from_doc_index,
  dangling_doc_index, vacuous, green}`.
- `Mix.Tasks.Commonplace.AuditCommitPopulation` — `--data-dir` (stopped-store run, the
  first cut) with durable capture-to-file, corpus positive control, verdict from the
  tested function. (`--serve-pid` live erpc run DEFERRED — needs the enumerators resident,
  i.e. a deploy first.)
- Tests: green non-empty store; each of the four diffs caught red-first (must-find
  controls, pure-data unit tests on `verdict/1`); empty store → vacuous, not green;
  `{:doc_commit}`-index-not-ready → index-unavailable finding, not silent-empty; **a
  fork-shares-an-id fixture proving the audit does NOT use `struct.doc_uuid`** (the trap).

## Resolved (plan #14150 — "guidance is complete"; cell-1 settles these defaults)

1. **Doc-ownership reference = `P_doccommit` (`{:doc_commit}` keys), NOT the `{:commit}`
   struct's `.doc_uuid`.** The struct field is a debug trace excluded from the hash and
   stale after forks (`commit.ex:52`); using it would misattribute forked docs' commits
   and fabricate/hide orphans. The `{:commit}` keyspace IS used — by its KEY (the id) —
   as Axis B's ground truth to validate the `{:doc_commit}` index that Axis A depends on.
   This is a correction to the naive reading of plan's "enumerate from `{:commit,_}`";
   both keyspaces are used, each for what it authoritatively represents.
2. **All four diffs are in scope.** Both reverse diffs (`dangling_latest`,
   `dangling_doc_index`) cost nothing extra once the populations are in hand and catch a
   distinct real failure (an index pointer with no backing commit). Throwing them away
   would leave findable corruption unlooked-at.
3. **`green` requires ALL FOUR diffs empty AND non-vacuous**, each class reported
   SEPARATELY. Any non-empty diff is a real anomaly; gating only on `orphaned_from_latest`
   would report known corruption as green — the decoration failure inverted.
