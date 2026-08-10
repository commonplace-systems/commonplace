# BUILD BRIEF — CX-q9sa: re-land the rm_rf store guard AS A PAIR (guard + its 41 offenders)

**For:** Sol (codex) · **plan's #3** (feature-steer track)
**Worktree:** `/home/jes/sol-q9sa/wt` · **branch:** `sol/cx-q9sa-pair`
**Run log:** `/home/jes/sol-q9sa/sol-run.log`

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ leave changes **UNSTAGED**, no
`git add`, no commit, no push; ⛔ **no serve, no live store** — the live store is
`/home/jes/commonplace/workspace/.commonplace/commits/`, **process-derived, NOT
repo-root and NOT `data/`**. ⚠️ **`mix deps.get` first.**

⚠️ **rc from the command itself, never through a pipe.** ⛔ **NO BARE ZEROS** —
any `0` arrives with a positive control that the pattern matches something.

⚠️ **Long suites: redirect to a file and read the file.** Do not pipe a long
`mix test` to `tail` — that has hung this repo before.

## 1. What this is — landing a FINISHED fix, not an investigation

⭐ **The investigation is CLOSED and the mechanism is known.** In test env a
**production-named singleton** `CommitStore` is started by `Application.start`
and **captures `data_dir` ONCE at boot** (`application.ex:64`), opening CubDB
with `auto_compact: true`. A test that swaps the env, works, and cleans up can
**delete a directory the live store still holds open** while believing it
touched only its own. It is **not a race** — nothing here is `async: true`; it
is **sequential state damage**, so the seed decides the ORDER, which decides
whether a deletion lands before or after another call.

**The guard was built, merged, and REVERTED — correctly:**

```
58718f2  the guard (test/support/file_rm_rf_guard.exs + 6 test_helper installs)
e36ca4a  the revert -- it broke 41 tests that were never run before landing
```

⛔ **The guard is CORRECT and the 41 failures are REAL OFFENDERS** — tests
deleting a directory with the live singleton store inside. The defect was the
*landing*, not the code: a guard whose entire purpose is umbrella-wide was
verified against three targeted suites in ONE app, i.e. **tested only where it
could not fire.**

⇒ ⭐⭐ **THE WHOLE POINT OF THIS TICKET: the guard lands WITH its cleanup, in
ONE commit. A gate must not land before the things it gates are clean.**

## 2. Starting from banked state, not from scratch

The guard's code is **already in history** — recover it, do not rewrite it:

- `git revert --no-commit e36ca4a` restores exactly the reverted files, or
- `git checkout 58718f2 -- test/support/file_rm_rf_guard.exs apps/*/test/test_helper.exs apps/commonplace/test/commonplace/file_rm_rf_guard_test.exs`

⚠️ **Verify by the FILE which paths actually came back** (the revert touched 8
files across 6 apps) — do not assume from the command's exit code.

## 3. ⛔ THE OFFENDER LIST IS AN ARTIFACT YOU PRODUCE, NOT A NUMBER YOU REPEAT

⭐ **The guard's first firing IS the enumeration.** Re-apply it, run the suites,
and **capture what it names.**

⛔ **A count without per-hit shapes is un-actionable.** For **every** fire, the
list must carry:

| column | why |
|---|---|
| test file **and line** | where the fix goes |
| the **deletion path** | what the test tried to remove |
| the **captured path** | what the live store holds |
| **which of the two contains the other** | ancestor-delete vs child-delete (e.g. `0.cub`) are different bugs |

⚠️ **Expected shape from the revert's own measurement: mcp 21, web 20 = 41.**
⛔ **That is a PRIOR, not a target.** If you enumerate a different number, the
number you MEASURED wins — report it with the shapes and say so plainly. Do not
reconcile toward 41.

## 4. ⛔ Fix shape — and the two forbidden fixes

Each offender should delete **only what it owns**. The normal fix is an
isolated per-test directory that cannot overlap the store's captured dir.

⛔ **FORBIDDEN FIX 1: weakening the guard** (narrowing the overlap test,
allow-listing a path, making it warn instead of raise). The guard checks **both
directions on purpose** — deleting the store's `0.cub` child destroys it as
thoroughly as deleting the parent.

⛔ **FORBIDDEN FIX 2: deleting or skipping the offending assertion/test.** The
test's *cleanup* is wrong, not its *subject*.

⭐ **If any offender turns out to be legitimately pointed at the real store,
that is a FINDING, not a nuisance — name it and stop rather than papering it
over.** That would be a test that has been corrupting the shared store all
along.

## 5. ⛔ Acceptance — artifacts

1. ⭐⭐ **The enumerated offender table** (§3), with per-hit shapes.
2. **Each offender fixed**, with the fix shape stated once per distinct pattern
   (not 41 paragraphs — group them, but the TABLE stays per-hit).
3. ⭐ **THE GUARD'S RED CONTROL STILL GOES RED.** `file_rm_rf_guard_test.exs`
   points an `rm_rf` at the captured dir and **must fail** if the guard is
   working. ⛔ **A guard that cannot fire is indistinguishable from no guard** —
   show it firing on purpose, deliberately, after the cleanup.
4. ⭐ **Post-fix: guard fires = ZERO across all six apps**, with the fire-count
   pattern given a positive control (prove the counter can see a fire at all —
   #3 gives you one).
5. `mix compile --warnings-as-errors` rc=0.

## 6. ⛔ SUITES — NAMED BY BLAST RADIUS = ALL SIX APPS

⚠️ **The guard installs in EVERY app's `test_helper.exs`. There is no narrower
scope, and believing otherwise is exactly what caused the revert.**

**Baseline each FIRST, report both numbers, one at a time, rc from the command
itself:**

| suite | on-main count |
|---|---|
| `apps/commonplace/test/commonplace/process` | **70 tests, 0 failures** |
| `apps/commonplace/test/commonplace/trust` | **213 tests, 0 failures** |
| `apps/commonplace_web/test` | **12 features, 134 tests, 0 failures, 12 excluded** |
| `apps/commonplace_mcp/test` | **156 tests, 0 failures** |
| `apps/commonplace_cli/test` | **97 tests, 0 failures** |
| `apps/commonplace_bots/test` | ⚠️ **baseline it and report both** |
| `apps/yelixer` | ⚠️ **baseline it and report both** |

⭐ *(The first five measured by the reviewer on main at `e8b9247`, 2026-08-10
00:13Z, load ~8. Older briefs quoting web `134/10` are stale — web measured
**134/0** in that run.)*

⚠️ **Umbrella test paths across apps SILENTLY DROP.** Run **per app** and check
each count; a multi-app path in one command is not a run of both.

⚠️ **Load-marginal tests — one line each if seen, then move on, do NOT chase:**
`SandboxExecTest` (sleeps a fixed 800ms against a 100ms interval),
`CommitHoistTest` (CX-qzbh: 10s budget in a 9.9–13.9s workload),
`BotPresenceCertTest` (times out in the FULL mud suite on main).
⭐ **Discriminator if one goes red: re-run it ISOLATED and re-run the suite at
the SAME seed.** Green isolated + green on re-run at the same seed = load, not
your change. Report which you observed.

## 7. ⛔ Out of scope

- ⛔ **Do NOT remove the singleton from test env.** *That* is the root defect,
  and it is a much larger separate project. This ticket makes deletion **safe**,
  not the singleton **absent**.
- ⛔ Do not change `Trust.default_config/0`, the mint path, or the public-key
  artifact work.
- ⛔ Do not re-tune any load-marginal test's budget as a side quest.
- Any other defect: **one line, don't pursue it.**

## 8. What you cannot verify in-sandbox

- ⛔ Anything requiring the live serve — report **UNVERIFIED** and stop.
- ⭐ **Everything in §5 is reachable from the test suites alone.** If you find
  yourself needing the live workspace, the scope has drifted — say so and stop.
