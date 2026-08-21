# The fork-lineage `{:doc_commit}` backfill — brief (the "(a) round")

**commonplace (cell-1), 2026-08-21.** Written at commonplace-plan's direction
(#14380: option (a) RATIFIED, option (b) pointer-authority REJECTED as doctrine —
permanently). plan ratifies this brief; the build follows post-deploy as the
designated next round. Companion evidence:
`docs/plans/2026-08-21-chit-epic-sizing-remeasure.md` (F2) and the deploy-
certification census (session probes; numbers restated below with their scope).

## The defect, measured (not inherited)

**116 docs** (1.9% of 6,110 heads; the F2 fork-lineage population, membership
byte-exact across two independent probes) carry a `:latest` pointing at commits
that have **zero `{:doc_commit, <key_doc>, _}` rows** — the old fork copied the
head pointer while every membership row stayed with the ancestor doc. Verified
2026-08-21 on a fresh `CubDB.back_up` copy:

- `latest_commit(uuid).doc_uuid ≠ uuid` for exactly 116 docs (F2, re-measured);
- **0/116** of those heads are `{:doc_commit}` members of their key doc;
- **116/116** have zero own-index rows at all — they are precisely the
  `dangling_latest` class (forked-then-never-edited);
- The chains READ perfectly (F1 census: 0 reconstruct errors — `parent_id` walks
  are doc-agnostic by design, CX-ggdv F5 fixture-proven).

**Consequences today:** `Projection.fetch_commit` (projection.ex:427) refuses them
(`{:commit_doc_mismatch, …}`) — so [6]'s verified export hard-fails on them (none
under the live mount today; deploy-note known-limitation), and [4]'s chit-mint
ancestry gate refuses any pin intersection containing one (`child_not_in_doc`).
World-B's doctrine — **ownership is the `{:doc_commit}` KEY** — is violated by
construction for these 116; every fact-keyed consumer, present and future, hits
the same wall.

## The fix: make the index true, then key on it

**Part (i) — backfill.** For each of the 116 (enumerated by the F2 predicate, not
a stored list): walk the chain backward from `:latest` via `parent_id`
(`commit_log_from`, paged, explicit limits) and write the missing
`{:doc_commit, key_doc, commit_id} => true` row for every commit in the walk.

- **Additive and idempotent**: the row value is `true`; a re-run writes the same
  rows. The index is many-to-many by design — convergent ids already carry
  multiple memberships, so dual-membership (ancestor doc AND forked doc) is
  coherent, not a new state.
- **Run model = the BUILD-1 §3 accepted-heads-backfill precedent, verbatim**: the
  code lands as a host-gated task; the live run is boss's ceremony against the
  live store (or its own window), coordinated separately from code-land. It can
  ride an off-hours window but was explicitly NOT rushed into the deploy that
  triggered it.
- **Denominator discipline**: the run reports docs processed / chains walked /
  rows written vs rows expected (from the chain walks), remainder named. A walk
  that caps without reaching genesis is a NAMED per-doc outcome, not a silent
  partial.

**Part (ii) — the fact-keyed switch.** `Projection.fetch_commit`'s cross-check
changes from the struct field to the fact: on struct-mismatch, consult
`doc_has_commit?(store, doc_uuid, commit_id)`; member → proceed (the struct field
is a first-writer trace — appearance, not fact); non-member → keep the refusal
(a genuinely wrong-doc pin is still caught — the defense survives, now keyed
correctly). Safe to land WITH (i)'s code, before the live run: for the 116,
fact-keyed refusal ≡ today's refusal until the rows exist; behavior improves the
moment the run executes.

## Acceptance (red-first throughout)

1. **The must-find fixture** (World-B pattern): a constructed fork-lineage doc —
   `:latest` at a foreign-struct commit with no own-index rows — whose verified
   export HARD-FAILS before backfill and RENDERS (with an honest verdict) after;
   same fixture through the [4] mint gate: REFUSES before, PASSES after.
2. **Idempotency**: run the backfill twice; second run writes 0 new rows and
   reports it.
3. **The defense survives**: a genuinely-foreign pin (commit not in the doc's
   chain at all) is still refused after the switch — both arms adjacent.
4. **Offline re-census**: the deploy-cert probe re-run on a post-backfill copy
   reads **116 → 0 hard-fails** (RENDER or honest-declared), all other classes
   unchanged.
5. **World-B convergence — by SET-DIFFERENCE, not count-delta** (plan's
   sharpening at ratification, #14389: a count-delta can mask an EXCHANGE — one
   processed doc still dangling + one unrelated doc newly dangling nets the same
   cardinality). Post-run: `dangling_pre \ dangling_post == the processed id set`
   AND `dangling_post ∩ processed == ∅`. Same data, one more comparison; the
   convergence claim is membership-true, matching the rigor of its inputs (the
   F2 116 were established by byte-exact membership, never by count).
6. **Readiness-gate hygiene**: the backfill respects the `{:doc_commit_index,
   :state}` readiness protocol (writes only against a ready index; never flips
   the state key itself).

## Scope fence

- NOT the `:latest`-pointer semantics (unchanged — R1 choke untouched).
- NOT a general fork-repair (only the missing membership rows; content,
  signatures, chains untouched — this writes index rows, never commits).
- NOT tonight's deploy (its own round; the deploy carries the 116 as a
  known-limitation meanwhile).
- NOT Reflog.Restore changes ([6]'s adapter already routes through Projection;
  the switch lands in one place).

## Sequencing

1. plan ratifies this brief.
2. Build lands (backfill task + fact-keyed switch + acceptance suite), CI-green,
   cp-merged — additive, deploy-safe by construction.
3. The live run: boss's host-gated ceremony (BUILD-1 §3 model), with the run
   report (denominators + per-doc outcomes) filed back into this doc's ledger.
4. Post-run: offline re-census (acceptance 4) + World-B convergence check
   (acceptance 5) close the round; [6]'s known-limitation note retires.
