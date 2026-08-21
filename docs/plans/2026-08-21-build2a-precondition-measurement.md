# BUILD-2a precondition measurement — the three counts (§6 of plan's BUILD-2 brief)

**Measured by cell-1, 2026-08-21, against `main` @`8e34b061`.** Discharges the
precondition in `commonplace-plan:docs/plans/2026-08-21-build2-cell-aware-storage-brief.md`
§6. commonplace holds the repo; plan holds the design. Each count carries a
positive control and its denominator; the cross-check names its disagreement
branch.

> Method note (boss #14156/#14193): a count is reported with its DENOMINATOR; no
> "it'll show up if it's broken" without saying how that was established; a
> cross-check states what a DISAGREEMENT would have meant.

## Headline

**The raw-CubDB surface OUTSIDE the storage adapter is ~ONE real product site.**
The seam substantially already exists: **134 of 136 real `CubDB.` access lines
live inside `apps/commonplace/lib/commonplace/store/`.** BUILD-2a is therefore a
SMALL round — the doomed-round risk the precondition guards against ("assumes a
handful, finds two hundred") does not obtain. The work is: (a) add `CommitReader`
as the cell-scoped read API over the existing `CommitStore`/`CommitStoreClient`
seam; (b) close/allowlist the `CommitStore.db_handle/1` escape hatch; (c) migrate
ONE ambient scan (a finding, not mechanical); (d) build the source guard.

## Count 1 — the raw-CubDB access surface (migration denominator + guard allowlist)

- **Denominator:** `139` lines match `CubDB\.` in product code (`apps/*/lib`),
  **all in the `commonplace` core app** — `0` in `commonplace_cli`, `_web`,
  `_mcp`, `_bots`. Storage is centralized in core.
- **Positive control:** a known site appears — `commit_store.ex` has 12
  `CubDB.select` lines incl. the World-B `population_scan` I just landed. ✓
- Of 139: **3 are comments/docstrings** (`tree/doc_builder.ex:349`,
  `gold/chain.ex:74`, `commonplace.ex:7`), **136 are real access.**
- **Split:** `134` inside `store/` (the adapter cluster) · **`2` outside.**
  - `projection/mixed_plane_history.ex:70` — a REAL product read (ambient
    `{:commit}` scan; see Count 3). Reaches CubDB via `CommitStore.db_handle/1`.
  - `projection/mixed_plane_history_fixture.ex:106` — a write, but the module is
    `@moduledoc false` internal fixture, not product surface.
- **Escape hatch:** `CommitStore.db_handle/1` (`commit_store.ex:847`, = `resolve_db`)
  hands out the raw `CubDB.t()`. Callers OUTSIDE the adapter: the same 2 files
  (`mixed_plane_history` + its fixture). Inside the adapter (legitimate):
  `commit_store_client`, `trust_side_store` (shares the commit db by design).
- **Other db-acquisition paths swept:** `:persistent_term.get({_, :db, _})` in
  product code = 2 sites, both adapter-internal own-db resolves
  (`commit_store.ex:3205`, `trust_side_store.ex:294`) — 0 bypasses. (Control: the
  same pattern appears in 4 TEST files, so it IS findable where present.)

⇒ **Real product migration surface outside the adapter = 1 site** (+ the hatch to
close, + 1 internal fixture).

## Count 2 — the adapter boundary (narrow-or-invent)

- **A commit-history adapter already exists:** `CommitStore` + `CommitStoreClient`
  (CLAUDE.md mandates `CommitStoreClient`, not `CommitStore` directly). ⇒ **2a
  NARROWS this existing seam** (adds `CommitReader` as the cell-scoped read API
  over it), it does NOT invent one — the smaller of the brief's two round sizes.
- **Physical CubDB instances** (`CubDB.start_link`): `2` — `commit_store` and
  `secret_store`. `trust_side_store`/`eviction_authority_ledger` ride the commit
  db via `db_handle`. The non-commit stores (secret, trust, eviction) hold
  DIFFERENT data (not commit history) and are **out of 2a's scope** (2a is the
  commit reader).
- **The leak the guard must close:** `db_handle/1` is what lets a caller obtain
  the raw db and bypass the client. The guard's allowlist = the `store/` adapter
  modules + migration tooling; `db_handle/1`'s out-of-adapter callers are what it
  must forbid (or narrow to an allowlisted set).

## Count 3 — scopability of the reads (the real difficulty)

- **Ambient-scan class count = 1:** `MixedPlaneHistory.commit_ids_by_doc/2`
  (`mixed_plane_history.ex:70`) does `CubDB.select` over the WHOLE `{:commit}`
  keyspace and reduces by a `doc_uuids` set. It takes `doc_uuids` as input but
  scans ambiently at the storage layer — the exact "a scan that today spans
  multiple docs" case (brief §3.3). A **finding**, not a mechanical rewrite.
- **Every other commit read in product code already routes through
  `CommitStore`/`CommitStoreClient`** with a doc-uuid (cell-id) in hand — those
  are seam-routed, not raw, and migrate mechanically to `CommitReader`.
- ⚠️ **Latent-correctness finding at the same site:** its reduce matches
  `{{:commit, commit_id}, %{doc_uuid: doc_uuid}}` — it groups commits by the
  **struct value's `.doc_uuid`**, which is a debug trace of the FIRST writer
  (excluded from the id hash, stale after forks / shared across convergent genesis
  ids — `commit.ex:52`), NOT authoritative ownership. This is the exact trap
  World-B's design flagged. Migrating this read to the `{:doc_commit}` index (the
  authoritative doc→commit map) is therefore not purely behavior-preserving — it
  would CORRECT the ownership basis. Whether it is a live bug today depends on
  whether forked/convergent-id commits reach this projection; that is a
  reproduce-before-reporting question for the migration round, flagged here so the
  round treats this site as a correctness migration, not a mechanical one.

## Cross-check (with its disagreement branch)

The direct-`CubDB.` outside-adapter count (2 real: `mixed_plane_history:70`,
`fixture:106`) AGREES with the `db_handle`-caller outside-adapter count (2:
`mixed_plane_history:69`, `fixture:64`) — the same two files. **Had they
differed**, a site would be reaching CubDB by a THIRD path (a handle passed
around, stashed in a module attr, or a different acquisition). They agree ⇒ no
third raw path in product code.

## Reproduce-before-prioritizing verdict on the .doc_uuid finding (plan #14196 part 3)

**Verdict: LATENT, not a live user-facing hotfix. The 2a migration cleans it up;
it does not need to LEAD 2a.** Established by code-trace (not yet an empirical
run — flagged as such; the empirical construction is 2a's own migration-verify
step):

1. **Fork is structurally SAFE.** `Commit.new(doc_uuid, …)` stamps the struct's
   `.doc_uuid` to the PASSED uuid (and it is excluded from the content address).
   `Fork` mints the forked doc's commits via `create_commit(new_uuid, …)`
   (`fork.ex:365/475/…`), so they carry the FORK's uuid — `commit_ids_by_doc`
   groups them correctly. A fork reproduce would show CORRECT grouping; fork is
   NOT the trigger. (This is why "construct a forked doc" alone would have
   returned a false all-clear — the trigger is elsewhere.)
2. **The trigger is a cross-doc commit-id COLLISION.** `put_built_commit` writes
   `{:commit, id}` and `{:doc_commit, commit.doc_uuid, id}` together, so the index
   doc and the struct's `.doc_uuid` agree AT WRITE TIME. They diverge only when an
   id is SHARED across two docs — a content-address collision (same
   update+parent+metadata), which cross-doc needs shared ancestry (an imported
   commit, i.e. federation/catch-up) since distinct uuids yield distinct genesis
   chains. Rare, and multi-node-only.
3. **The consumer is an operator diagnostic, not a user view.** `commit_ids_by_doc`
   is called only by `MixedPlaneHistory` (`:452`), whose only consumer is the
   `mix commonplace.mixed_plane_scan` task — operator-run, not real-time
   user-facing history.

⇒ No user sees wrong history in real time from this; it can mis-group only in an
operator scan, only under cross-doc id collision (federation). So it does NOT lead
2a as a hotfix. Migrating the site to the `{:doc_commit}` index (authoritative
ownership) corrects the basis as a clean correctness-improving step within 2a — and
2a's migration-verify SHOULD include the empirical collision construction (two docs
sharing an imported commit id; assert the pre-migration grouping mis-attributes and
the post-migration one does not) as its red→green.

## What this sizes (converts 2a designed → ready)

The brief's §3–§5 become a **small, bounded round**: build `CommitReader`
(read API: `history`/`heads`/`at`/`inventory`, all cell-scoped, over the existing
`CommitStore` seam) + the **source guard** (red-first: a raw `CubDB.`/`db_handle`
in product code fails CI; allowlist = `store/` + migration tooling) + migrate the
**one** ambient site (`commit_ids_by_doc`, a correctness-bearing finding). The
guard is the deliverable; the reader is easy; the migration is one finding, not a
sweep. Acceptance §5 items 1 (guard both directions), 3 (`inventory` without
enumerating the workspace), and 4 (empty key diff) all apply unchanged.
