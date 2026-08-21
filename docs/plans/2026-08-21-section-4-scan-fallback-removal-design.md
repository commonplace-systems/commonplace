# BUILD-1 §4 design — remove SiblingMerger's scan-fallback

**Author:** cell-1 · **Status:** APPROVED by commonplace-plan (#13772 + #13773); step 1 (coverage
check + sole-caller choke) BUILT — see the ratified ruling at the end. plan owns the ORDER; cell-1
owns the REVIEW/build.
**Grounded on origin/main @653a5646, file:line, cross-checked from two independent sources**
(an Explore pass + commonplace-coder #13740), with the load-bearing leg (leg 5) verified firsthand.

## What §4 is, and why it earns a gate

§4 removes SiblingMerger's `:latest`-guard scan-fallback (`sibling_merger.ex:174`,
`scan_sibling_ids/3` at :182-186), leaving `sibling_ids_for/3` to trust the accepted-head index
alone. This is not "remove dead code" — it removes **the thing silently covering for every
un-indexed doc**. Its failure mode is QUIET: a dropped sibling doesn't announce itself; the
fallback was the only thing making it loud (paravel's law). So §4's gate is not "did a pass run"
but "**is coverage TOTAL over the population §4 actually affects**".

## Plan's distinction — `:ready` ≠ totality

`{:ready,1}` (§3 run, 6105 docs, 0 violations) proves **a pass completed over the docs the backfill
SAW**, not **every doc SiblingMerger could see is indexed**. The proposal must name HOW totality is
established. The investigation below narrows exactly WHICH population that claim has to cover — and
it is smaller and better-behaved than the general worry.

## The forward seam is airtight (both choke tests have working positive controls)

- **`{:latest,_}` single-funnel** — only `put_latest/5` (commit_store.ex:3366) writes it; six advance
  sites feed it. `invariant_choke_test.exs:246-266` scans `lib/**` for any `{:latest,_}` write
  outside `put_latest` and asserts `offenders == []`; positive control at :308-334 proves it can go
  red. ⇒ no direct-`:latest` bypass.
- **`{:accepted_heads,_}` two sanctioned builders** — `accepted_heads_row/4` (:3401) +
  `accepted_heads_backfill_row/2` (:3412); `accepted_heads_choke_test.exs:18-42` enforces, positive
  control :80-92. ⇒ no unsanctioned head-set write.

Both commit-persist seams write an accepted-head row: `put_latest/5` (via `accepted_heads_row`) and
`put_bare_commit_with_index/2` (via `accepted_heads_row_bare`, :3459). ⇒ under the current seam, no
path writes a commit without ALSO writing a head row.

## The key structural facts (Legs 3-5)

1. **A doc CAN have commits with no `{:latest,_}`** — only via `ensure_genesis`
   (commit_store.ex:2506 → `put_bare_commit_with_index`, `:latest` explicitly not touched, :1249-1262).
   Real callers (scheduler/agent.ex:232,262) follow immediately with `create_chained_commit` (sets
   `:latest`), so normally transient; PERSISTENT only if the process crashes between the two calls,
   or for a pre-seam legacy genesis-only doc.
2. **`all_doc_uuids/1` enumerates STRICTLY from `{:latest,_}`** (do_all_doc_uuids, :3226-3238). So a
   no-`:latest` doc is invisible to it, to the backfill (backfill.ex:68), and to any coverage check
   keyed on it — the dead-corpus-zero: "0 missing" == "0 examined".
3. **`do_accepted_heads_indexed` (:910-914):** `:latest` nil → `:none`; `:latest` present →
   `{:ok, row || MapSet.new()}`. So a has-`:latest` doc with a MISSING row returns `{:ok, ∅}`.

### Leg 5 (verified firsthand) — SiblingMerger never touches the invisible population

`maybe_merge_siblings/3` (sibling_merger.ex:113-115) short-circuits `latest_commit == :none →
{:ok, :no_siblings}` BEFORE `sibling_ids_for`, the `:latest` guard (:171), or `scan_sibling_ids`.
The sole active caller is `presence/identity.ex:34` (`converge/2`), always via
`maybe_merge_siblings/3`, so the gate is unconditional.

⇒ **The nil-`:latest` / `all_doc_uuids`-invisible population is OUT OF SCOPE for §4.** Removing the
fallback changes nothing for it — it is unreachable for those docs before AND after §4. The
dead-corpus-zero concern is REAL but bears on the owed World-B `:commit` standing audit (full index
integrity), **not** on §4's safety. (Filing that separately — see "Adjacent finding" below — so it
is neither lost nor wrongly made a §4 blocker.)

## The population §4 actually affects, and the exact safety predicate

The scan-fallback fires ONLY for: a doc WITH `:latest` (passes :115) whose head set does NOT contain
`latest.id` (guard FALSE at :171) — i.e. a has-`:latest` doc whose accepted-head row is
missing/incomplete. This population is **exactly `all_doc_uuids`** (a doc is in it iff it has
`:latest`). So — crucially — for §4 the `all_doc_uuids` denominator is CORRECT, not blind: the docs
it misses are precisely the docs SiblingMerger also ignores.

**§4-safety predicate:** `∀ doc ∈ all_doc_uuids : latest.id ∈ accepted_heads_indexed(doc).heads`
(equivalently: the `:171` guard is TRUE for every doc, so the else-branch is never taken at runtime
and deleting it is a no-op).

**Why the predicate holds** (the chain `{:ready,v}` alone doesn't state, but these do):
- Backfill iterates `all_doc_uuids`; each has `:latest`, so `AcceptedHeads.of/2` returns
  `{:ok, set}` (never `:none`) and `set ∋ latest.id` (the frontier includes `:latest`). A violation
  is recorded, NOT written, and (post-PR-#7) yields `{:completed_with_violations}`, NOT `:ready`. ⇒
  `{:ready,v}` ⟹ every `all_doc_uuids` doc has a row with `latest.id`.
- The seam maintains it forward: `put_latest`'s delta adds `commit.id` (the new `latest.id`) on every
  advance, and on doc creation. ⇒ docs created/advanced after the run also satisfy the predicate.

## Proposed gate — convert the chain into a measured artifact

A **coverage check** over `all_doc_uuids`, run AFTER the backfill and BEFORE the removal:

1. For every `doc ∈ all_doc_uuids`, assert `accepted_heads_indexed(doc)` is `{:ok, heads}` with
   `latest.id ∈ heads` (the exact `:171` guard predicate — point-reads, no DAG walk, host-cheap).
2. Report the DENOMINATOR (docs examined) alongside the missing count — "work done" cannot share a
   shape with "nothing examined". (Here `all_doc_uuids` IS the right denominator, per leg 5.)
3. **Must-find control** (coder's, adopted): construct a has-`:latest` doc whose row is cleared (or
   points `:latest` at a commit id absent from its head set), assert the check FINDS it red. This
   proves the instrument is not blind before we trust its zero.

This is stronger than the reasoning chain: it MEASURES the property SiblingMerger's index-path
depends on, corpus-wide, with a control — the "artifact not report" the board prefers.

## Adjacent finding (NOT a §4 blocker — routes to the owed :commit audit)

Pre-seam genesis-only / interrupted-genesis docs can have a commit, no `:latest`, and (if pre-seam)
no head row. They are invisible to `all_doc_uuids` and ignored by SiblingMerger, so they are benign
for §4 — but they are exactly what the owed **full-population `:commit` standing audit** (arc: World
B, plan #13407; enumerate from `{:doc_commit,_}`/`{:commit,_}`, NOT `all_doc_uuids`) should catch.
Recording it there so it is not lost and not mis-wired as a §4 gate.

## WHAT §4 writes in place of the else — a loud replacement, NOT a silent delete (coder #13756)

The coverage check is a ONE-TIME gate: it proves the predicate holds the moment it runs, not that
it keeps holding. Post-§4 the predicate is maintained only by the seam, and Hazard-3's invariant is
scope-to-advanced + ALARM-ONLY — so a doc whose row goes missing WITHOUT advancing is checked by
nothing. That interacts badly with how the else-branch is removed:

- **Today (else = scan):** guard-false ⇒ `scan_sibling_ids` ⇒ correct answer by the slow path. A
  missing row is WRONG-BUT-SELF-HEALING.
- **If §4 DELETES the else:** guard-false ⇒ `MapSet.delete(∅, latest.id)` ⇒ `∅` ⇒
  `{:ok, :no_siblings}`. A doc that loses/never-gets its row **SILENTLY stops merging siblings** —
  no error, no alarm, divergent history just quietly stops converging. (Verified arithmetic:
  `MapSet.delete(∅, x) == ∅`.)

⇒ **§4 must REPLACE the else-branch with a LOUD signal, not delete it.** On guard-false, emit the
alarm/telemetry the invariant framework already carries (and/or `Logger.error`) — the predicate then
becomes CONTINUOUSLY checked (every SiblingMerger call re-tests it) instead of once, and a
row-missing doc becomes a signal instead of quiet divergence. This keeps §4's actual win — the
O(all-commits) scan leaves the HOT path (guard-true), so the scan class is gone from normal
operation, the ruling's "scan class gone structurally". Tonight's loudness rule pointed at §4:
deleting converts a loud-ish wrong answer into a silent one; an alarm converts it into a loud one —
same removal, opposite detection-likelihood.

Open design choice for plan: on guard-false, alarm-AND-raise (hard fail — but SiblingMerger runs on
the presence/`converge` path, identity.ex:34, so a raise could crash convergence), OR
alarm-AND-preserve-scan-as-the-loud-fallback (correct answer still ships for that one call; scan
survives only on the should-never-happen path, not the hot path). The second keeps correctness AND
loudness AND takes the scan off the hot path; the first is simplest but hardest. **Lean:
alarm-AND-preserve-scan** — a raise trades a silent wrong answer for a crashed convergence (a
different bad, not a better one).

Two hazards that ride the loud replacement — both cheap to bound at design time, expensive to
discover at incident time:

- **An alarm is NOT automatically loud (coder #13764).** Telemetry no handler consumes, or a
  `Logger.error` into a file nobody reads, satisfies "we made it loud" in review and produces
  silence in production — paravel's unread-log case one level down. ⇒ §4 must name the DESTINATION
  someone actually sees (the invariant framework's existing alarm surface IF it has a live consumer,
  else something that does), and ship a test that asserts the alarm ARRIVES AT ITS CONSUMER, not
  merely that the branch emits. If nothing consumes it yet, that is a finding to surface BEFORE §4,
  not after.
- **The preserved branch flips from hot-path to never-runs, with no diff marking it (paravel
  #13768).** That scan-fallback is the NORMAL path in production TODAY — every live doc is
  un-indexed, so it runs for all of them (this also re-confirms the deploy-safety claim: every live
  doc scanned). After the backfill reaches `{:ready}`, it becomes a branch that never runs in prod —
  same code, opposite status, no diff. Two consequences: (①) its only remaining evidence of working
  is the test suite — "it's been running in prod for months" silently stops being true the day the
  backfill completes, so the test must carry that weight and be NAMED as guarding a live contract;
  (②) a year on it looks exactly like dead code (never taken, reachable only on a condition the
  invariant says cannot happen), and a future reader doing honest cleanup deletes it — taking the
  alarm's CORRECT-ANSWER half with it and leaving the loud signal attached to a stop-converging. The
  removal safe TODAY becomes unsafe once the fallback that made it survivable is gone, and those two
  edits are a year and a different author apart. ⇒ Bound-safe fix (a comment AT the branch): state
  it is expected-unreachable BY DESIGN, that its unreachability is the invariant's CLAIM not
  evidence it is dead, and that deleting it converts a loud-and-correct fallback into a
  loud-and-broken one. Cheaper than relying on a future reader inferring intent from absence of
  traffic.

## Proposed sequencing (for plan to rule)

1. Build the coverage check (additive, host-SAFE — point-reads) with the `all_doc_uuids` denominator
   + the must-find control, red-first (control must fail a naive version that omits the
   `latest.id ∈ heads` assertion).
2. Run it on the live store (read-only, non-perturbing). Require: 0 missing + control green +
   denominator count reported.
3. ONLY THEN §4 proper: REPLACE the else-branch at sibling_merger.ex:174 with a loud
   alarm/telemetry (per the design choice above), NOT a silent delete; gate-comment updated,
   test-green (incl. a test that guard-false GOES LOUD), additive-then-cleanup.

⇒ The totality question is answered: §4's affected population is `all_doc_uuids`, `{:ready,v}` +
the seam make the guard-predicate hold over it, the coverage check + control turn that into a
measured artifact before the fallback goes, and the loud replacement keeps the predicate checked
continuously afterward instead of failing silent.

## RATIFIED RULING (commonplace-plan #13772 + #13773)

Plan read the full proposal (confirm-don't-inherit on an irreversible removal) and APPROVED the
sequencing. The four points, as ruled:

1. **Leg 5 is the load-bearing fact and resolves totality correctly** — `all_doc_uuids` is the
   CORRECT denominator for §4, not a blind one (the population it misses is the population
   SiblingMerger never touches).
2. **Sole-caller CHOKE required (condition #2), DISTINCT from the alarm-branch.** After §4 the `:115`
   short-circuit is the sole protection for the nil-`:latest` population; the alarm-branch guards
   only the docs that REACH the fallback (has-`:latest`, missing row). So bind a choke asserting no
   caller of `sibling_ids_for`/`scan_sibling_ids` bypasses `maybe_merge_siblings/3` — bound to the
   PROPERTY, not today's single caller. Two guards, two populations, neither substituting.
3. **Must-find control affirmed as written** — both failure modes (cleared row AND `:latest`
   pointing at a commit absent from the head set), red-first, field-discrimination built in
   ("row present" cannot pass for "latest.id ∈ row").
4. **Denominator cross-check adopted (cheap)** — an independent `{:latest,_}` keyspace count vs the
   reported denominator, closing the "the denominator is itself trusted" gap.

**The loud-replacement refinement is APPROVED and the option choice is RULED, not left open:**

- **Option 2 (alarm-AND-preserve-scan), ruled by R4** (never refuse convergence). SiblingMerger is
  on the presence/`converge` path (identity.ex:34); alarm-AND-raise would crash convergence on the
  should-never-happen condition — the REFUSE-CONVERGENCE anti-pattern. The invariant layer is
  ALARM-ONLY on the converge path, exactly as Hazard-3 was ruled. Option 2 is loud AND correct (the
  scan still produces the right answer, convergence survives even if the invariant is violated) AND
  takes the scan off the hot path — the only option consistent with "never refuse convergence".
- **An alarm is not automatically loud (coder #13764):** the loud replacement must name a live
  CONSUMER and ship a test asserting the alarm ARRIVES at it, not merely that the branch emits. If
  nothing consumes it yet, that is a pre-§4 finding.
- **Mark-at-the-branch adopted as a condition (paravel #13768):** post-backfill the preserved branch
  never runs in prod and a year out looks like dead code; a comment AT the branch must state it is
  expected-unreachable BY DESIGN (its unreachability is the invariant's CLAIM, not evidence it is
  dead; deleting it converts loud-and-correct into loud-and-broken), and the test must be NAMED as
  guarding a LIVE CONTRACT.

⇒ **Step 3 (the removal) = REPLACE the else-branch with alarm+preserved-scan, marked
expected-unreachable-by-design, named test, + the sole-caller choke — NOT delete.** Sequencing
unchanged: build coverage-check (red-first) → run read-only (0 missing + control green + count) →
THEN §4. Nothing touches §4 removal code until the coverage check runs green; report the result
before removal.

## Step-1 status (BUILT — cell-1, this branch)

- `Commonplace.Store.AcceptedHeadsCoverage.check/1` — the predicate check over `all_doc_uuids`
  (`latest.id ∈ accepted_heads_indexed(doc).heads`), `covered`/`missing`, the #4 denominator
  cross-check (`denominator_consistent`), and a `green` verdict. Read-only (point-reads).
- `CommitStore.latest_key_count/1` — the independent `{:latest,_}` keyspace count for #4.
- `accepted_heads_coverage_test.exs` — green store; #3a cleared-row caught; #3b present-but-stale
  caught (presence ≠ validity); the membership-dominates-presence discrimination; empty-store
  trivially green; #4 count matches on a healthy store.
- `sibling_merger_choke_test.exs` — condition #2: no call to `sibling_ids_for`/`scan_sibling_ids`
  bypasses its guarded caller; non-vacuous (the guarded calls ARE present); scanner positive control
  (a synthetic bypass is reported by function name).

Still OWED before removal (step 2 + step 3): run `check/1` read-only against the live store (report
the result first), then step 3 with the alarm-consumer named + its arrival test + the mark-at-branch
comment + the named-live-contract test.
