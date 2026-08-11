# CI-red enumeration, phase (a): the measurement — evidence table, zero interpretation

> STATUS: DRAFT FOR PLAN'S REVIEW (offered msg 11125) — not dispatched.
> Renderings plan should check: [R1] "matched-method isolation (CX-q9sa)" is
> rendered below as same-population-same-seed re-run (the load-vs-ordering
> discriminator); if plan means something sharper, correct §5. [R2] The
> sandbox fence is part of the recorded enclosure, not avoided — see §2.

Executor: Sol, via the egress runner, in a fresh worktree. Deliverable is ONE
evidence table plus raw logs. ⛔ No diagnosis, no classification, no fixes —
any urge to interpret is a deviation to report, not follow. Phase (b)
classification happens elsewhere, over the table.

## 1. Preconditions (operator sets, Sol VERIFIES — a wrong scope VOIDS the run)

The measurement owns the box (queue #1-runs-alone rule) AND a full umbrella
run against a live serve is a known flock hazard (2026-07-18 incident). So:

- The operator stops the :5199 serve before dispatch and restarts after.
- ⛔ Sol asserts BEFORE EVERY umbrella run: `curl -s -m 2 -o /dev/null
  http://localhost:5199/; echo rc=$?` must be NON-zero (connection refused).
  If :5199 ever ANSWERS, every subsequent run is VOID — stop and report
  which runs completed under valid enclosure. The assertion output is part
  of each run's enclosure record.
- Record per run, before and after: `cat /proc/loadavg`, `date -u`,
  `git rev-parse HEAD`, worktree path, `MIX_ENV`. If 1-min load exceeds 2.0
  at a run's start, note it loudly and delay up to 5 minutes; if it stays
  high, run anyway and FLAG the row (never silently absorb).

## 2. Enclosure facts that must ride the artifact

- Runs happen inside the Sol sandbox: node signing key masked → trust
  anchors resolve EMPTY. Tonight's core suite ran 3,294/0 inside this same
  fence, so the mask does not red the core suite wholesale — but ANY failure
  whose message smells of `:untrusted_root` / anchors / signing gets its row
  ANNOTATED "possible fence artifact", recorded, never dropped.
- These are LOCAL runs; comparison against CI's own red identities is
  phase (b)'s job, not this artifact's.

## 3. The umbrella runs

From the worktree root (never a per-app cd — umbrella path-drop is a known
trap; a run that reports 0 tests is VOID, assert the total test count on
every run):

```
mix test --seed 101 > run-seed101.log 2>&1; echo "rc=$?"
mix test --seed 202 > run-seed202.log 2>&1; echo "rc=$?"
mix test --seed 303 > run-seed303.log 2>&1; echo "rc=$?"
```

Seeds 101/202/303 deliberately match the suite-reliability arc's prior
measurements for cross-night comparability. ⛔ Redirect to files, never pipe
to tail. From each log extract FAILURE IDENTITIES — `file:line` + full test
name — never counts alone. Record each run's total test count and duration.

## 4. Alone runs

Every test identity appearing in ≥2 of the three runs: run its FILE alone
(same worktree, same MIX_ENV), record red/green + count + duration + the
exact command. (Pool law: the most frequent member runs alone FIRST, before
anything else in this section.)

## 5. Matched-method runs [rendering R1 — plan to confirm]

For each DISPUTED identity (red in an umbrella run, green alone): repeat the
FULL umbrella at the SAME seed where it failed, once.
- Same population + same seed + now green ⇒ evidence toward LOAD.
- Still red at the same seed ⇒ deterministic-at-that-seed (ordering /
  contamination class).
Record the outcome per identity with the command. No further repeats without
reporting first (budget guard).

## 6. The deliverable

One markdown table, every row carrying its evidence commands:

| test identity | red in seeds | alone | matched-method | enclosure refs / flags |

Plus: the raw run-seed*.log files, the per-run enclosure records, and a
deviations section (empty is a claim — say "none" only if true). Total test
counts per run stated. Nothing else: no severity, no root causes, no fixes.

## 7. Budget

3 umbrella runs (~15–25 min each) + alone runs + matched-method repeats:
expect 2–3 hours. If the third umbrella run has not STARTED after 2 hours,
stop and report what completed — a partial table under valid enclosure beats
a complete one under drift.
