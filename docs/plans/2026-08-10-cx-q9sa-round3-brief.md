# BUILD BRIEF — CX-q9sa ROUND 3: the ~95 offenders my brief never asked for

**For:** Sol (codex) · **Worktree:** `/home/jes/sol-q9sa-pair/wt`
**branch:** `sol/cx-q9sa-pair` (your rounds 1+2 are COMMITTED there at `6741a21` — keep them)
**Run log:** `/home/jes/sol-q9sa-pair/sol-run3.log`

---

## 0. Environment contract (standing)

⛔ Leave changes **UNSTAGED**, no `git add`, no commit, no push. ⛔ **No serve, no
live store** — the live store is `/home/jes/commonplace/workspace/.commonplace/commits/`,
**process-derived, NOT repo-root and NOT `data/`**. ⚠️ `mix deps.get` first.

⚠️ **rc from the command itself, never through a pipe.** ⛔ **NO BARE ZEROS.**
⚠️ Redirect long suites to a file; never pipe `mix test` to `tail`.
⭐ **ESCAPE HATCH:** if the remedy doesn't fit what you measure, **that is a
FINDING — report it and stop.**

## 1. ⛔ WHAT HAPPENED, AND IT WAS MY FAULT NOT YOURS

Rounds 1+2 were merged and then **REVERTED from main** (`8a847d5`). ⛔ **Nothing
you built was wrong.** The scope I gave you was.

My round-1 brief said, in bold: *blast radius is ALL SIX APPS, because the guard
installs in EVERY app's `test_helper.exs` — there is no narrower scope.* ⇒ Then
the table one line below named `apps/commonplace/test/commonplace/process` and
`.../trust` as the "commonplace" scopes. **Those are two SUBTREES: 70 + 213 of
that app's 3278 tests.**

⇒ **~2995 tests in the app the guard is MOST present in were never run.**
Measured on the merged main before the revert:

```
mix test apps/commonplace/test  →  5 doctests, 3278 tests, 99 failures, 12 excluded
                                   95 guard fires
```

⭐ Your enumeration was honest and complete **for the suites named**. The real
total is **58 + ~95**, and the extra 95 were never in anyone's denominator
because the brief never asked for them.

## 2. ⭐ WHAT IS ALREADY DONE — DO NOT REDO ANY OF IT

Committed on your branch at `6741a21`, all verified independently by the reviewer:

- The 58-offender enumeration + per-hit table (`docs/plans/2026-08-10-cx-q9sa-guard-offenders.md`)
- Every one of those 58 fixed, **by TEARDOWN ORDERING** (stop the store before
  `rm_rf`, restore it after) — not by isolating directories, which could not work
- The **restoration property asserted INLINE in teardown** (store alive,
  registered under its own name, original `data_dir`) — better than asked for
- The web `AuditDispatcher.flush()` fix
- The guard's **child-delete control** fixed (discover the `.cub` file, never
  assume `0.cub`; flunk loudly on an empty dir)
- Guard files byte-identical to `58718f2` except that one test

## 3. ⛔ THE TASK — the same work, on the population that was missing

Enumerate and fix the guard fires in **`apps/commonplace/test`**, using exactly
the method that worked in rounds 1–2.

⚠️ **From the pre-revert run, the offenders cluster in `bd/` and `pr_*`:**
26 `ticket_create_import_verbs_test.exs` · 11 `close_gate_test.exs` ·
8 `ticket_verbs_test.exs` · 7 each `pr_accept_test.exs`,
`tix_migration_acceptance_test.exs`, `bd/cli_test.exs`, `bd/claim_test.exs` ·
5 `pr_refresh_preview_test.exs` · 4 each `pr_open_test.exs`,
`pr_decline_test.exs`, `pr_comment_test.exs` · 3 `pr_preview_read_guard_test.exs` ·
2 `fork_enforce_test.exs`

⛔ **THAT LIST IS A PRIOR, NOT A TARGET.** ⭐ **"95" IS ALSO A PRIOR.** The
measured number WINS — **do not reconcile toward 95, and do not stop when you
reach it.** The last two rounds each found a number nobody expected (58 not 41;
then 95 more); assume this one does too.

**Deliverables, same shape as before:**
1. Extend the offender table with every new hit: **file:line, deletion path,
   captured path, and which contains which.**
2. Fix each by ordering + restoration, matching what you already did.
3. ⛔ **Forbidden, unchanged: do not weaken the guard, do not delete or skip a
   test.** If an offender is legitimately pointed at the real store, **that is a
   FINDING — name it and stop.**

## 4. ⛔⛔ SUITES — THE DENOMINATOR IS THE CHECK

⭐ **This is the whole lesson of the revert. A suite path that selects fewer
tests than the app contains is a SCOPE CLAIM, and it must be checked
mechanically rather than believed.**

⇒ **For every suite you run, report the COUNT — and for `apps/commonplace/test`
the count MUST be ~3278.** ⛔ **If you run a commonplace suite and see 70, or
213, or anything that is not thousands, YOU ARE RUNNING A SUBTREE AND THE RUN IS
VOID.** That single check is what would have prevented this revert.

| suite | on-main count (`8a847d5`, guard REVERTED) |
|---|---|
| ⭐ **`apps/commonplace/test`** | ⭐ **5 doctests, 3278 tests, ~0 failures, 12 excluded — THE BIG ONE, previously never run** |
| `apps/commonplace_web/test` | 12 features, 134 tests, 0 failures, 12 excluded |
| `apps/commonplace_mcp/test` | 156 tests, 0 failures |
| `apps/commonplace_cli/test` | 97 tests, 0 failures |
| `apps/commonplace_bots/test` | 276 tests, 0 failures |
| `apps/yelixer/test` | 1 doctest, 33 properties, 390 tests, 0 failures, **11 invalid, rc=2 (PRE-EXISTING)** |

⛔ **Baseline `apps/commonplace/test` FIRST, on the current tree, and report both
its count and its failure number** — I have not measured it clean since the
revert and you should not trust my ~0.

⚠️ `mix test apps/yelixer` (app dir, no `/test`) **RUNS NOTHING AND EXITS 0**.
Use `apps/yelixer/test`. ⚠️ `mix precommit` exists **only inside
`apps/commonplace_web`** (a per-app alias); at the umbrella root it is rc=1 and
that is correct, not an error.

## 5. ⛔ Acceptance

1. The extended offender table (§3.1), per-hit.
2. ⭐⭐ **`apps/commonplace/test` GREEN, with its count** — ~3278 tests, 0 guard
   fires. ⛔ **A count in the hundreds means you ran a subtree.**
3. **All six other suites green with counts**, per §4.
4. ⭐ **The guard's RED CONTROL still goes red** — re-prove it, don't cite round 2.
5. ⭐ **ORDER-DEPENDENCE:** rounds 1→2 taught that one green run is not a verdict.
   Run `apps/commonplace/test` at **THREE seeds**, counts **PER SEED**.
6. `mix compile --warnings-as-errors` rc=0.

## 6. ⛔ Out of scope

- ⛔ Do not remove the test-env singleton (the root defect; separate project).
- ⛔ Do not fix yelixer's 11 invalid, or `apps/yelixer` at all.
- ⛔ Do not touch runtime code. This is tests + the guard support file only.
- Any other defect: **one line, don't pursue it.**
