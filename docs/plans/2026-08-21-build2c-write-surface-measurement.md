# BUILD-2c write-surface measurement — the three counts (the write half of the seam)

**Measured by cell-1, 2026-08-21, against `main` @`c5a222e4`.** The warm-tail
companion to the BUILD-2a read-seam work (plan flagged it as an optional
warm-context grab, `commonplace-plan` #14246). 2a made the READ side cell-scoped;
2c is the WRITE side. Same §6-gate method as the 2a precondition
(`2026-08-21-build2a-precondition-measurement.md`): each count carries a
denominator + a positive control; the cross-check names its disagreement branch.

> ⚠️ Scope of the claim: this is a **call-site + signature** measurement. It
> SIZES 2c (turns designed→ready); it does not CERTIFY it. The exhaustive "no
> write reaches a `{:commit}`/`{:latest}` row without a cell-id" proof is 2c's own
> acceptance step, the way 2a's migration-verify was — *a call site is not a
> dataflow*.

## Headline

**2c is even more built-ahead than 2a.** Every commit-history WRITE already
carries its cell-id (doc_uuid) by signature, and the raw-write-bypass perimeter
is **already closed** — by 2a's guard (which forbids *all* `CubDB.*` outside the
adapter, writes included) plus the pre-existing commit-row write-checker. There
is **no raw-access migration** and **no ambient-write finding**. 2c's real
content is a thin cell-scoped write-API mirror plus **one genuine design nugget:
the first cross-cell relationship.**

## Count 1 — raw write-bypass surface (the migration denominator)

- **Denominator:** `{:commit,` / `{:doc_commit,` / `{:latest,` storage-key write
  literals + `CubDB.put*/delete/clear` in product code (`apps/*/lib`) outside
  `store/`.
- **Real raw writes outside the adapter = 1:** `projection/mixed_plane_history_fixture.ex`
  (`@moduledoc false`; already the write-checker's allowlisted `seed!` writer).
  The 24 `{:commit,` grep hits are 23 **PubSub message shapes**
  `{:commit, uuid, commit_id, meta}` (a 4-tuple broadcast, NOT the 2-tuple
  `{:commit, id}` storage key) + that 1 fixture write.
- **Positive control:** the fixture's `CubDB.put_multi` appears (line 106). ✓
- **Cross-check:** `CubDB.put*/delete` outside `store/` = the **same 1 file**.
  Had it differed, a site would be writing commit state by a third path; it
  agrees ⇒ no third raw-write path in product code.
- ⭐ **Already guarded:** 2a's `scripts/check_commonplace_cubdb_reads.exs` forbids
  ALL `CubDB.*` outside the adapter — the name says "read" but it is
  access-agnostic — so a raw `{:latest}`/`{:commit}` put bypass is red-on-CI
  today. The commit-row write-checker adds the `{:commit}`↔`{:doc_commit}`
  pairing invariant on top. 2c inherits a closed raw perimeter; it does not build
  one.

## Count 2 — the write-verb surface (is each write cell-scoped?)

- **Commit-history write verbs, all with a cell-id in the signature:**
  `create_commit(doc_uuid, …)`, `create_chained_commit(doc_uuid, …)`,
  `create_snapshot_commit(doc_uuid, …)`, `snapshot(doc_uuid)`,
  `set_latest(doc_uuid, …)`, `ensure_genesis(doc_uuid)`, `import_commit(commit)`
  (carries `commit.doc_uuid`).
- **Product callers outside the adapter = 226** sites across ~30 files, all routed
  through `CommitStore`/`CommitStoreClient` with a doc_uuid in hand.
- ⇒ "every commit write names its cell" is **already true by signature** (plan's
  "largely built-ahead" prediction, confirmed). Unlike 2a — which needed a new
  reader module + one ambient-scan migration — 2c has **no ambient write to
  migrate.**

## Count 3 — ambient (cell-less) writes = 0 in the commit-history verbs

The cell-less store writes — `store_capability` / `store_revocation` /
`store_sla_tombstone` / `activate_eviction_anchor` / `put_execute_clean` — write
**trust/eviction-side data** keyed by cap-id / anchor-id / fingerprint, **not
commit history.** Out of 2c's scope (2c = the write half of *commit history*,
mirroring 2a's read half, which likewise excluded the secret/trust/eviction
stores).

## The one design nugget — the first cross-cell relationship

`set_merge_point/3` and `set_last_merge_commit/4` are inherently **cross-cell**
writes: they name **two** cells (`target_uuid` + `source_uuid`). A cell-scoped
write API (`CellStore.append`/`advance_ref` over the existing verbs) has to express
"this write touches two cells" — which the pure append/advance shape does not.
This is the topology doc's *"transactions stop at the cell boundary / a multi-cell
operation is an atomic selection"* in miniature, and it is the analogue of 2a's
one ambient-scan finding: **the spine of 2c's brief, not a no-op.**

## What this sizes

2c's round = a thin cell-scoped write-API mirror over the existing (already
cell-scoped) verbs **IF** a symmetric named write seam is wanted, plus the
cross-cell-merge design question. **No raw-access migration, no ambient-write
findings.** The acceptance criteria carry over from 2a: guard both directions
(already met by 2a's guard for the raw perimeter), behavior-preserving, no
identity rewritten — with the exhaustive cell-scoping proof as 2c's own
acceptance.
