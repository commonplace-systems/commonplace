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
4. **Denominator cross-check — WITHDRAWN (plan #13810, coder #13795).** A `{:latest,_}` count
   cannot independently check whether `all_doc_uuids` under-enumerated `{:latest,_}`: they read the
   SAME keyspace, so the range bound is the shared suspect and any same-keyspace count inherits it;
   and with unique CubDB keys the only class such a count could catch (dup-collapse, count > set)
   cannot occur — so it can NEVER GO RED = decoration. Removed rather than shipped (a can't-go-red
   check in a gate is worse than an absent one — it reports as coverage). Genuine under-enumeration
   detection needs an INDEPENDENT instrument — a full-population enumeration from `{:commit,_}` /
   `{:doc_commit,_}`, structurally independent of `{:latest,_}` — which is the owed World-B
   `:commit` standing audit (plan #13407), the honest home for it, not this host-cheap gate.

**Step-2 condition — RULED (plan #13812, adopting paravel #13808 + coder #13802 + boss 7x34):**
the live coverage run is a hand-transcribed MIRROR of `check/1` over already-resident readers, so
the code producing the GO/NO-GO is NOT the 24-tested module. Non-perturbation
(`:code.is_loaded` + before/after `:code.all_loaded`) proves the probe does not DISTURB the serve;
it says nothing about whether it COMPUTES THE RIGHT THING — two independent claims a clean run
presents as one. ⇒ Before the live run, the EXACT mirror source must run against
`AcceptedHeadsCoverage`'s own fixtures and produce IDENTICAL output to the tested module, INCLUDING
going RED on #3a (cleared row) and #3b (present-but-stale). That validates the transcription — the
one thing the module's tests structurally cannot. boss will not execute an unvalidated mirror.

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
  (`latest.id ∈ accepted_heads_indexed(doc).heads`), reporting `examined`/`covered`/`missing`/
  `vacuous`/`green`. `green` requires `examined > 0` (non-vacuity, coder #13795 defect (b)) AND
  `missing == []`. Read-only (point-reads). NO denominator cross-check (withdrawn — see ruling #4);
  the moduledoc honestly scopes the denominator to `all_doc_uuids` and routes genuine
  under-enumeration to the World-B `:commit` full-scan audit.
- `accepted_heads_coverage_test.exs` — non-empty green store; #3a cleared-row caught; #3b
  present-but-stale caught (presence ≠ validity); membership-dominates-presence discrimination;
  empty store is VACUOUS and NOT green (the fix).
- `sibling_merger_choke_test.exs` — condition #2: no call to `sibling_ids_for`/`scan_sibling_ids`
  bypasses its guarded caller; non-vacuous (the guarded calls ARE present); scanner positive control
  (a synthetic bypass is reported by function name).

## Step 2 (DONE — coverage gate GREEN, 2026-08-21 03:02:47Z)

Resolved to **Option B** (no transcription): the durable `commonplace.coverage_canary` mix task
runs the tested `verdict/1` + `build_entry/3` over erpc-injected resident readers. boss executed the
live `--all` run against the serve (`--serve-pid 664985`, re-derived from `ss -ltnp`).

**VERDICT (plan's gate, satisfied):**

    examined=6106  covered=6106  missing=0  vacuous=false  green=TRUE
    skew: pass1=0 pass2=0 SKEW=0
    non-perturbation: serve :code.all_loaded 701 → 701  UNCHANGED
    telemetry: 0 handlers on [:commonplace,:commit,:latest_read]
    serve RSS: 235,956 → 237,280 kB (Δ +1,324 kB, transient — settled below pre-run after)
    wall 48,703.6 ms · transfer 11,586,238 B · largest single commit 1,484,397 B

- The **post-backfill 6106th doc** (created after `:ready`) is COVERED — forward-maintenance is a
  DEMONSTRATED positive, not an argument about the seam.
- Capture (entries + verdict): `/tmp/section4-coverage-664985.capture`, 2,250,672 bytes,
  **sha256 `52091b80939c0a6a5e32af85ae4ea3cf89ba466804a50199eae435ace2f815db`**. ⚠️ It is in `/tmp`
  (ephemeral) and is live-store doc-ids/commit-hashes — NOT committed here (repo-visibility of
  operational data uncertain); the verdict + hash above are the durable in-git record, and the
  capture file is to be preserved out of `/tmp` on the host for re-verdiction (boss's host path).
- **Sizing keeper (measured, boss):** the 500-doc canary understated WALL by 3.2× and the MAX single
  commit by 59× (canary max 25,164 B vs full 1,484,397 B). v4-uuid randomness buys unbiasedness
  in EXPECTATION, not tail coverage — a small sample of a heavy-tailed distribution understates the
  MEAN too, not just the tail. ⛔ Do not size a job on this corpus from a canary without an
  extreme-value treatment or a full pass. The 3.2× wall gap is measurement-without-mechanism, filed.

⇒ plan GO for step 3 (#13938): gate satisfied against every false-green mode hunted (non-vacuous,
skew-0, non-perturbing, tested-verdict-no-transcription, controls red-first in the 15/0 suite,
re-verdictable capture).

## Step 3 (NEXT — the removal; plan GO given, destination ruling pending)

Replace the else-branch at `sibling_merger.ex:174` with alarm+preserved-scan (Option 2, ruled by R4
— never crash the converge path), marked expected-unreachable-BY-DESIGN, the test named as guarding
a LIVE CONTRACT, + the sole-caller choke already landed in step 1. NOT a silent delete.

### The alarm-consumer finding (coder #13764's pre-§4 requirement — RESOLVED, and it IS the flagged case)

An Explore pass mapped every alarm/telemetry/audit surface (2026-08-21). **There is NO durable,
routinely-read alarm sink that a SiblingMerger inline branch can write to without new wiring:**

- **Invariants `:alarm`** (`Dispatcher.alarm/4`, dispatcher.ex:307-326) tri-emits Logger + telemetry
  + `broadcast_red`, but it only fires during debounced resting-state Dispatcher runs — NOT callable
  inline from the merge — and its `[:commonplace,:invariants,:violation]` telemetry has **zero
  attached handlers** in production.
- **`broadcast_red`** is ephemeral Phoenix.PubSub; a background merge has no guaranteed subscriber
  to that doc's red topic.
- **Audit RedLog** (`AuditLog`→`AuditDispatcher`→`RedLog.commit`) is the ONLY surface with a live
  programmatic consumer — the `AuditCanary` deadman reads the substrate records on a schedule — and
  it is durable. BUT it is a DENIAL surface (`audit_log.ex:125-140`); a stale-head-index is not a
  denial, and wiring it in needs a new event + a `build_payload` clause + `DenySites.audited/0` +
  `DenySiteScanTest` + canary coverage. A design decision, not a drop-in.
- **Logger**: prod level `:info` (config/prod.exs:24), NO file backend — console/journal, durable
  only as the launcher captures it. But the codebase already TREATS the serve log as a watched
  operator surface: `DeployGapMonitor.report/1` (deploy_gap_monitor.ex:106-114) reports via
  `Logger.error` into "the serve log operators already watch" (application.ex:694), and
  `audit_log.ex:215` names the local Logger "the fallback sink of last resort."

**Recommended (pending plan/coder ruling): `Logger.error`-led tri-emit**, copying the established
fail-loud pattern from `AuditCanary.alarm/3` (audit_canary.ex:341-357): `Logger.error` (load-bearing
— needs no subscription, and is the operator-watched sink `DeployGapMonitor` deliberately targets) +
`:telemetry.execute` + `broadcast_red` alongside (ready for a future handler/subscriber, matching
convention). Arrival test = `capture_log` asserts the alarm line emits on the guard-false branch.

**The alternative for MORE rigor (plan #13938 said this fail-open gate deserves it): the audit
RedLog** — the only destination with a deadman reader — at the cost of the denial-surface wiring
above and the semantic stretch (a non-denial alarm in a denial surface). ⇒ **Destination is plan's
ruling; step 3 does not build until it lands.**
