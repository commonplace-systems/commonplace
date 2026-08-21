# Chit-epic sizing RE-MEASURE — precondition report (epic step [0])

**commonplace (cell-1), 2026-08-21.** This is the chit epic's mandated first
step: re-confirm the 2026-08-06 sizing (`@cd968b1`, folded into the chit spec's
§8.5 SIZED amendment `@c023e1c`) before commonplace-plan writes step [1]'s
consolidated-foundation brief off it. The spec's own rule — *"code re-verification
is the build's first task"* — and the 2a/2c doctrine (a step-sequence on a stale
sizing is a plan on stale measurement) put this on the critical path. Same shape
as `docs/plans/2026-08-21-build2a-precondition-measurement.md` and the 2c
write-surface measurement: denominators, positive + negative controls, a
disagreement branch, no green-by-construction, read-only.

Design being re-measured: `commonplace-plan/docs/plans/2026-08-06-chit-projection-sizing-brief.md`
(M1 capability · M2 determinism · M3 cost · M4 census) and the five findings the
executed run folded into chit-spec §8.5.

---

## Scope, bound INTO the artifact (read before trusting any number)

- **Substrate:** a single read-consistent **`CubDB.back_up/2` offline copy** of the
  live serve's store, taken 2026-08-21 **11:21Z**. Live serve pid **664985** on
  :5199; live store `workspace/.commonplace/commits/` (confirmed via `/proc/664985/fd`).
  Copy = 2.3 GB compacted single `0.cub` (live was 5.1 GB across 3 pre-compaction files).
- **Non-perturbation, measured not asserted:** `:code.is_loaded/1` confirmed
  `CommitStore` and `CubDB` resident on the serve BEFORE any call (an erpc to an
  unloaded module force-loads working-tree code = a write). `:code.all_loaded`
  before/after the back_up: **716 → 718**; the two new modules were `CubDB.Snapshot`
  and `Enumerable.CubDB.Btree` (dep code) — **zero `Commonplace.*` working-tree
  modules force-loaded**. The live serve was not perturbed.
- **All probes ran OFFLINE** against the copy via a locally-started `CommitStore`
  (`--no-start`, so `CommitStoreClient` routes to the local store, not the serve),
  calling the REAL reconstruction code (`DocBuilder`, `Projection`). Reads only:
  `mint: false`, `reader_lazy_snapshot_enabled` forced off, no writes, no cleanup of
  anything found (findings filed, not fixed).
- **Copy faithfulness (replica-proxy leg):** a 31-doc subsample compared `:latest`
  (id + update bytes) copy-vs-live (erpc `CommitStore.latest_commit`, a resident fn):
  **31/31 exact match, 0 drift, 0 mismatch.** The copy mirrors the live heads.
- **M3 absolutes** (below) are OFFLINE-COPY numbers (skip the GenServer
  serialization real projection pays); the cost *shape* is what the decision keys on.
- Probes were **authored fresh** for this round (the 2026-08-06 scripts were
  ephemeral; none committed). Harness preserved under the session scratchpad.

---

## Verdict summary

| # | Finding | 2026-08-06 | 2026-08-21 | Verdict |
|---|---------|-----------|-----------|---------|
| 1 | Silent-wrong-bytes (chain replay drops schema entries) | 80/2376 docs, 124 entries | **80**/1778 docs, **126** dropped + 1 added | **STANDS — unmoved** |
| 2 | Fork lineage (`:latest` at foreign `doc_uuid`) | 2.2% | **1.9%** (116/6108) | **STANDS** |
| 3 | Mixed-plane hazard is PIN-ONLY | 0 head / 1 pin | **0 head / 1 pin** | **STANDS — unmoved** |
| 4 | Projection tamper-blind on full-state chains | 76% absorbed | **62.2%** absorbed | **STANDS — magnitude moved** |
| 5 | Determinism passes (fresh processes) | 0/119 fail | **0/466 fail**, 231 distinct shas | **STANDS** |

**Bottom line for step [1]: every load-bearing conclusion of the 2026-08-06
sizing holds. The consolidation fold survives; both consumers still sit behind a
verified-projection layer; snapshot-compaction stays on the dependency list; the
ancestry checker must still key on fact-not-`:latest`-doc_uuid; the tripwire must
still run at pin reads.** No decision number flipped. Details and the one nuance
that sharpens (not overturns) Finding 1 below.

---

## M4 — corpus census (vacuity-checked: classes sum to the total, remainder named)

| class | count |
|---|---|
| head docs (`all_doc_uuids`, the denominator) | **6108** (was 5186) |
| schema, entries non-empty | 1778 |
| schema, empty | 14 |
| non-schema (text / other) | 4316 |
| `latest_none` | 0 |
| `snap_error` (reconstruct failed) | 0 |
| **SUM** | **6108 — remainder 0** ✓ |

Commits scanned by the pin sweep: **≈35,515 across 6,107 of 6,108 docs** (≈31,142
scanned + ≈4,373 skipped; the single unfinished doc `ffeacb17…` is a deeply
`:conflicted` non-schema chain that emits `:conflicted`, never `:mixed_plane`, so it
cannot change the mixed-plane count). Denominators throughout are built from what
**arrived** (docs with a readable `:latest`), not what survived — the zero
`latest_none`/`snap_error`/`chain_error` counts confirm nothing was silently
dropped from any denominator. Classifier stated plainly: a **dir-schema doc** =
`Doc.has_type?(reconstruct_snapshot(doc), "entries")`. (The 2026-08-06 "2376
dir-schema" figure counted differently or predates 15 days of corpus change; my
1792 total schema / 1778 non-empty is the reproducible classifier for this round.)

---

## Finding 1 — silent-wrong-bytes (chain replay drops schema entries). **STANDS.**

**Method.** For every dir-schema doc: entry set from `reconstruct_doc` (full-chain
replay — the k20z-suppressing candidate) vs `reconstruct_snapshot` (latest-commit-only —
what `Document.Server.init` and `Workspace.profile` actually serve at head, i.e. the
authoritative live read). Count docs whose entry maps disagree; count entries dropped.

**Result.** **80 / 1778** dir-schema docs disagree — *exactly the 80 of 2026-08-06.*
**126** tree entries dropped by chain replay (was 124), **1** added, **0** reconstruct
errors. Real entries silently lost: `__reflog`, `__processes.json`, `output.txt`,
`prompts.txt`, `bartleby`, `server`, `claude-code.bot`. Example doc `6a717fca…`:
snapshot shows 6 entries, chain replay shows 3 (drops `__processes.json`, `__reflog`,
`bartleby`).

**Controls.** Set-diff self-test proved the comparator both detects a dropped key
and passes identical sets before any corpus count. Both arms exercised on the corpus
(80 disagree AND ~1700 agree) — the probe demonstrably reports equal *and* unequal.

**Nuance that SHARPENS the finding (new this round).** One doc (`a4f1be2a…`) has
chain replay *add* an entry (41 vs 40), not just drop — so this is silent *wrong*
bytes in both directions, not purely lossy. And the pin sweep independently
corroborated the class: the `Projection` oracle's replay-vs-direct **dual-path check
returns `{:unknown, {:conflicted, …}}`** on divergent docs (e.g. every commit of
`ffeacb17…`). That means the *verified-projection layer partially exists and CATCHES
this divergence as `:conflicted`* — whereas raw `reconstruct_doc` (Finding 1's path)
stays silent. This is exactly why §8.5 ruled the layer a DEPENDENCY: the catch lives
in `Projection`'s dual path, not in reconstruction. Step [1]/[5] should treat
`:conflicted` as the existing seam to build the layer on, not a new one to invent.

---

## Finding 2 — fork lineage (`:latest` at a foreign `doc_uuid`). **STANDS.**

**Method.** For each head doc, `latest_commit(uuid).doc_uuid == uuid`? Ownership is
the `{:doc_commit}` KEY; `commit.doc_uuid` is the stale struct field (excluded from
the content address, wrong after fork/import) — the same World-B / MixedPlaneHistory
appearance-vs-fact trap.

**Result.** **116 / 6108 = 1.9%** (was 2.2%). Example: key `108dbaed…` carries a
`:latest` commit whose struct `doc_uuid` is `16fcb834…`.

**Control.** Mismatch detector proven to fire on foreign and pass on own before the
corpus pass; both arms exercised (116 mismatch, ~6000 match).

**Consequence unchanged:** chit-ancestry (epic step [4]) must key on the fact
(`{:doc_commit}` membership), never the naive `:latest` doc_uuid — same discipline
as World-B's `.doc_uuid`→`{:doc_commit}` fix.

---

## Finding 3 — mixed-plane hazard is PIN-ONLY. **STANDS — unmoved.**

**Method.** `project_at` returns `{:unknown, {:mixed_plane, _}}` when a pin trips, so
it IS the oracle. Head leg: scan every doc at `:latest`. Pin leg: full history sweep
(`MixedPlaneHistory.run`, ~35.5k commits) emitting a HIT per tripping pin.

**Result.** **0 mixed-plane trips at head** (was 0). **1 pin HIT** (doc
`235d73b5…`, the armed doc) across the history (6,107/6,108 docs; the one unfinished
doc cannot add a mixed-plane HIT — see M4) (was 1). Head-only auditing cannot see it
— the tripwire must run at pin reads.

**Control.** The sweep's built-in gate ran the fixture positive control FIRST and
passed (`head=CLEAN history=TRIPS`) — the tripwire is proven able to fire before any
corpus zero at head is trusted.

**Head tail worth noting:** at head, 149 docs projected `{:unknown, <other>}` and 116
`{:error}` (≈4.3%) — not mixed-plane, but the head read is not universally `{:ok}`;
these are the fork-lineage / chain-integrity / conflicted cases surfacing.

---

## Finding 4 — projection tamper-blindness on full-state chains. **STANDS — magnitude moved.**

**Method.** Flip one byte in a fetched commit's `update` IN MEMORY (never a store
write) and re-run the exact reduce reconstruction does; ABSORBED = canonical output
byte-identical (silent), CAUGHT = output differs or reduce errors. Scoped to
full-state (schema) chains — the finding's stated scope. **Flip position is
load-bearing:** flipping only the *last* commit gives 6.9% absorbed (the last full-
state commit is largely the *suppressed* one under k20z and its corruption is caught);
flipping *every* commit — including the superseded/earlier ones that dominate the
replayed output — is the position-independent rate the finding measured.

**Result (all-commits, full-state chains).** **596 / 958 flips = 62.2% absorbed**
(was 76%). Text/delta contrast: 56.2%. The magnitude dropped from 76% but the
qualitative conclusion is intact: a majority of single-byte store corruptions produce
byte-identical canonical output — the reconstruction layer cannot self-detect
corruption, so **the verified-projection layer is a DEPENDENCY, not an enhancement.**

**Controls.** Identity control 408/408 (comparison can report "same"); `flip_noop = 0`
(every flip actually changed the input, so "absorbed" is never a non-flip); caught arm
reachable (362 caught) and absorbed arm reachable (596) — both directions exercised.

---

## Finding 5 — determinism. **STANDS.**

**Method.** Project each of a deterministic sample of `(doc, commit)` pairs to
canonical export bytes (`Projection.project_at` → `PostState.canonical_bytes`) in TWO
fresh OS processes; diff. Sample = 60 dense + every-40th doc × {head, middle, oldest}
commit, spanning schema/text/deep classes.

**Result.** **466 pairs, 430 `:ok`, 231 distinct shas, byte-identical across both
processes → 0 nondeterministic pairs** (was 0/119). No stop-the-line.

**Controls.** Diversity control: 231 distinct shas among 430 `:ok` projections proves
the hash actually distinguishes content (not a vacuous "all equal"). Must-fail
control: corrupting one line of run-1 made `diff` report the difference — the
cross-process comparator can go red.

**Caveat retained, verbatim from §8.5:** *determinism ≠ correctness.* The export is
reproducible today, **including reproducibly wrong** — Finding 1's 80 docs project
deterministically to the wrong entry set. Determinism is necessary for stable export
SHAs and insufficient for correct ones; that is precisely why the verified-projection
layer (Finding 4) is a dependency, not an add-on.

---

## Disagreement branch — what moved, and why it does not change the sizing

- **Finding 4: 76% → 62.2%.** Corpus-mix / chain-depth dependent, and my flip is one
  deterministic mid-byte per commit rather than the 2026-08-06 sampling. It remains a
  MAJORITY-absorbed result on full-state chains; decision number 2/§3.4 (verified-
  projection layer is a dependency) is unchanged. No re-litigation.
- **Finding 2: 2.2% → 1.9%.** Small drift over 15 days and +922 docs; same phenomenon,
  same consequence for step [4].
- **Denominator shift (2376 → 1778/1792 schema).** A classifier difference stated
  above, not a population collapse; Finding 1's *numerator* is identically 80.
- **Nothing crossed a decision threshold.** Determinism still 0 (the only unconditional
  gate). Unprojectable/silent-wrong still confined to the named full-state-schema class.
  Cost shape unchanged (full-history-linear walk; snapshot-compaction stays on the list).

## What step [1] can build on (handing back to commonplace-plan)

1. The five findings are re-confirmed; step sizing may proceed on THESE numbers.
2. The `Projection` **`:conflicted` verdict is the existing seam** for the verified-
   projection layer (Finding 1 nuance) — the dual replay-vs-direct check already fires;
   step [5] extends it, it does not start from zero.
3. `reconstruct_snapshot` (latest-commit-only) is the authoritative head read for
   schema docs; `reconstruct_doc` (chain replay) is the silent-wrong path — the
   commit-verb / pin-read foundation (steps [1]/[2]) must read per-commit, never
   chain-replay full-state schemas (the k20z inherited constraint, re-confirmed live).
4. Fork-lineage (1.9%) and the fact-not-`:latest`-doc_uuid discipline are live in the
   corpus today; step [4]'s ancestry invariant needs it from the first commit.
