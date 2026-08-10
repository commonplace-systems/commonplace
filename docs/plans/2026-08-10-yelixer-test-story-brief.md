# BUILD BRIEF — CX-v70s + CX-ye7n: make yelixer's test story TRUE before it gets CI

**For:** Sol (codex) · **plan's #4 (Yelixer arc), first step**
**Worktree:** `/home/jes/sol-yelixer/wt` · **branch:** `sol/yelixer-test-story`
**Run log:** `/home/jes/sol-yelixer/sol-run.log`

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ leave changes **UNSTAGED**, no
`git add`, no commit, no push. ⛔ **No serve, no live store** — the live store is
`/home/jes/commonplace/workspace/.commonplace/commits/`, **process-derived, NOT
repo-root and NOT `data/`**. ⚠️ `mix deps.get` first.

⚠️ **rc from the command itself, never through a pipe.** ⛔ **NO BARE ZEROS** —
any `0` arrives with a positive control that the pattern matches something.
⚠️ Redirect long suites to a file; never pipe `mix test` to `tail`.

⭐ **ESCAPE HATCH (standing):** if the remedy below does not fit what you
measure, **that is a FINDING — report it and stop. Do not force it.**

⭐ **PRIORS BELOW ARE PRIORS, NOT TARGETS. The measured number WINS. Do not
reconcile toward any number in this brief.**

## 1. Why this comes before CI

plan's row #4 is jes's verbatim ask: *"give Yelixir unit tests and CI."*
⛔ **You cannot put CI on this suite yet, and that is what this ticket fixes.**
Measured on clean main `390433f` by the reviewer:

```
mix test apps/yelixer        (EXACTLY as CLAUDE.md documents)  → rc=0, ZERO BYTES OF OUTPUT
mix test apps/yelixer/test                                     → rc=2,
        1 doctest, 33 properties, 390 tests, 0 failures, 11 invalid
```

⇒ **The documented verification command RUNS NOTHING AND EXITS 0.** Adding CI now
would either encode that vacuous command (a green pipeline that tests nothing) or
ship a permanently red one (rc=2). ⭐ **Both are worse than no CI, because a green
that cannot fail is read as evidence.**

## 2. ⛔ TASK A (CX-v70s) — the documented command is vacuous

`CLAUDE.md` "Running tests" claims:

```
mix test apps/yelixer             # yelixer only (includes 5320 yrs dataset tests)
```

1. **Correct it to a form that actually runs the tests**, and ⛔ **verify the
   correction BY ITS OUTPUT, not by its exit code** — paste the count.
2. ⭐ **AUDIT THE WHOLE SECTION THE SAME WAY.** `mix test`,
   `mix test apps/commonplace/test`, and any other documented invocation: each
   must be shown to produce a REAL COUNT. ⛔ A bare rc=0 does not discharge this;
   that is the exact defect. **Report a table: command → rc → count.**
3. ⭐ **PROPOSE (do not build) a refusal**: a test invocation selecting ZERO
   tests should FAIL rather than exit 0. Say where it would live and what it
   would cost. ⛔ **Do not implement it in this ticket** — it is a separate,
   umbrella-wide change and would need its own blast-radius run.

## 3. ⛔ TASK B (CX-ye7n) — 11 invalid, rc=2, and 390 vs 5320

⭐ **This is a MEASUREMENT task. Report what you find; do not fix the tests.**

1. ⭐⭐ **NAME THE 11 INVALID TESTS, one per row, WITH THE REASON EACH IS
   INVALID** (the setup failure and its actual error). ⛔ **A count without
   per-hit shapes cannot be acted on.** "Invalid" in ExUnit normally means the
   module's setup raised, so the tests never ran — they are neither passing nor
   failing, and they are currently riding inside a line that reads "0 failures".
2. **Confirm rc=2's cause** rather than assuming it is the invalid modules.
3. ⭐⭐ **THE 390-vs-5320 QUESTION — MEASURE IT, DO NOT REASON ABOUT IT.**
   CLAUDE.md advertises **5320 yrs dataset tests**; the run reports **390 tests**.
   - Do 5320 dataset tests EXIST in the tree? Where, and in what form?
   - Are they being SKIPPED, EXCLUDED (a tag?), NOT COMPILED, or absent?
   - ⛔ **Do not conclude from the doc.** The doc is already known wrong about
     the command on the very same line.
   ⇒ If a large body of differential coverage is not running, **that is the most
   important thing in this ticket** and it outranks everything above.
4. ⚠️ **Known trap, recorded so you don't burn time:** yelixer standalone
   (`cd apps/yelixer && mix test`) fails on missing deps — its committed lock
   omits `telemetry`, needing `mix deps.get` and `--no-deps-check`. Run from the
   umbrella root instead. **Report this as a finding for the standalone-repo arc;
   do not fix the lock here.**

## 4. ⛔ Acceptance — artifacts

1. **A command→rc→count table** for every documented test invocation (§2.2).
2. ⭐ **A positive control that the CORRECTED command can go RED** — point it at
   a deliberately failing test and paste the failure, then revert. ⛔ Without
   this the fix inherits the defect's own unfalsifiability.
3. **The 11 invalid tests NAMED with per-hit reasons** (§3.1).
4. **A measured answer to 390-vs-5320** (§3.3), with the commands you ran.
5. `mix compile --warnings-as-errors` rc=0.

## 5. SUITES — and ⚠️ THE COUNT IS WHAT PROVES THE COMMAND RAN ANYTHING

You are editing **CLAUDE.md** (docs) and running tests. The blast radius is
small, but ⛔ **a named suite without a count is an unverified instruction** —
that is this ticket's own subject, so hold yourself to it.

| suite | on-main count |
|---|---|
| `apps/yelixer/test` | 1 doctest, 33 properties, 390 tests, 0 failures, **11 invalid, rc=2** |
| `apps/commonplace/test/commonplace/trust` | 213 tests, 0 failures |

⭐ *(Measured by the reviewer on clean main `390433f`.)* ⚠️ Main is now
`7463a64`, which added the rm_rf test guard — **re-baseline and report both
numbers; if they differ from the above, YOUR MEASUREMENT WINS.**

## 6. ⛔ Out of scope

- ⛔ **Do not fix the 11 invalid tests.** Diagnose and report. The fix is a
  separate decision once we know what they are.
- ⛔ Do not implement the zero-tests-selected refusal (propose only).
- ⛔ Do not touch the standalone yelixer repo, its lock, or the dep flip
  (CX-fbah / CX-b6mz / CX-71m2 / CX-bx59) — those are later steps of this arc.
- ⛔ Do not set up CI in this ticket. **This ticket is what makes CI possible.**
- Any other defect: **one line, don't pursue it.**

## 7. What you cannot verify in-sandbox

- ⛔ Anything requiring the live serve — report **UNVERIFIED** and stop.
- ⭐ Everything here is reachable from the repo and its test suites.
