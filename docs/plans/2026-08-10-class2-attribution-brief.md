# BUILD BRIEF — class 2: find WHICH neighbour reddens a test that is green alone

**For:** Sol (codex) · **plan's #1 (suite reliability), class 2 of three**
**Worktree:** `/home/jes/sol-class2/wt` · **branch:** `sol/class2-attribution`
**Run log:** `/home/jes/sol-class2/sol-run.log`

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ **UNSTAGED** only, no `git add`,
no commit, no push. ⛔ **No serve, no live store** (live store is
`/home/jes/commonplace/workspace/.commonplace/commits/`, process-derived).
⚠️ `mix deps.get` first. ⚠️ **rc from the command itself, never through a pipe.**
⛔ **NO BARE ZEROS** — any `0` arrives with a positive control.

⛔⛔ **UMBRELLA TEST RUNS ARE MUTUALLY EXCLUSIVE ON THIS BOX.**
`commonplace_web` binds **:4002**. ⭐ **EVERY run in this ticket must be preceded
by a port PRE-FLIGHT that REFUSES if the port is held:**

```bash
h=$(ss -ltnp 2>/dev/null | grep -c ":4002"); [ "$h" -eq 0 ] || { echo "ABORT: :4002 busy"; exit 3; }
```

⚠️ **An `:eaddrinuse` run exits rc=1 with an EMPTY summary and looks exactly like
a catastrophic failure.** Two measurements were destroyed that way before this
guard existed. ⛔ **A run with no counts is an ENVIRONMENT error, never a result.**

⭐ **ESCAPE HATCH:** if the remedy doesn't fit what you measure, **that is a
FINDING — report it and stop.**

## 1. What class 2 is

Main's `apps/commonplace/test` suite is **non-deterministic**: measured 4 / 1 /
4 / 4 failures at seeds 101 / 202 / 303 / 404, **with different sets each time.**
Isolating each member split them into three classes. **This ticket is class 2:**

| test | alone | in the suite |
|---|---|---|
| `DocBuilder` bounded walk (`tree/doc_builder_bounded_walk_test.exs`) | **22 tests, 0 failures** | red at seeds 101 and 303 |
| `Green.Bursar` bounded persistence (`green/bursar_test.exs`) | **44 tests, 0 failures** | red at seeds 101 and 303 |

⇒ **Green alone, red among neighbours.** ⛔ **That is NOT "not real" — it means
the failure needs a neighbour, and the neighbour is unknown.** The
store-deletion class was one such mechanism and is already fixed, so this is a
**different** one.

## 2. ⛔ THE DELIVERABLE IS AN ATTRIBUTION, NOT A FIX

⭐ **You are not asked to make anything pass. You are asked to NAME THE
NEIGHBOUR.** ⛔ **Do not fix, skip, tag, reorder or delete any test.**

**Produce: the MINIMAL SET OF TEST FILES that reproduces the failure.** Ideally
two — the victim and one culprit.

## 3. Method

### Step 1 — get a DETERMINISTIC reproducer (do this first)

Random seeds make bisection unreliable. ⭐ **`--seed 0` disables ExUnit's
shuffle**, giving a fixed order.

1. `mix test apps/commonplace/test --seed 0` — does either victim fail?
2. If yes ⇒ you have a deterministic reproducer; use `--seed 0` throughout.
3. If no ⇒ fall back to a seed where it DID fail (101 or 303) and **verify it
   reproduces at least twice at that seed before bisecting.** ⛔ Bisecting an
   unreproducible failure produces a confident wrong answer.
4. ⛔ **If neither victim reproduces at all in ≥3 attempts, STOP AND REPORT
   THAT.** It is a finding — the population may have shifted under the merges —
   and it is not something to force.

### Step 2 — bisect the FILE SET

With a reproducer in hand, `mix test` accepts an explicit list of files:

```bash
mix test <victim.exs> <file1.exs> <file2.exs> ... --seed 0
```

1. Confirm **victim alone** is green (it is; re-confirm in your tree).
2. Confirm **victim + all other files** is red at your chosen seed.
3. **Halve the neighbour set. Re-run. Keep the half that stays red.** Repeat.
4. ⚠️ If BOTH halves go green, the culprit is a **combination** — say so and
   report the smallest red set you reached rather than forcing it to one file.

### Step 3 — report the mechanism only if the code shows it

⭐ Once the set is minimal, look at what the culprit does: shared ETS, a named
process, app env, an on-disk path, a background timer that outlives its test.
⛔ **If the code does not make it obvious, report the MINIMAL SET and stop.**
The set is the deliverable; the mechanism is a bonus. ⛔ **Do not guess a
mechanism** — several plausible-and-wrong mechanisms were proposed and retracted
on this exact problem in the last 12 hours.

## 4. ⛔ Acceptance — artifacts

1. **The deterministic reproducer**: exact command + seed + pasted failure.
2. ⭐ **The minimal red set**, with the bisection steps shown (each step: files
   included, rc, count).
3. ⭐ **Both controls at the minimal set**: victim ALONE is green, and victim +
   culprit is RED. ⛔ Without the green half, "minimal" is unproven.
4. If Step 3 yields a mechanism, the code that shows it. Otherwise say
   **UNKNOWN** — that is an acceptable and expected outcome.
5. `mix compile --warnings-as-errors` rc=0.

## 5. ⛔ Out of scope

- ⛔ **Do not fix the failure.** Attribution only.
- ⛔ Do not touch `TrustConfigFailClosedTest` (class 1, deterministic, waits on
  CX-8wh1's helper) or `AuditChokePerfTest` (class 3, its own tickets).
- ⛔ Do not change any test's tags, timeouts or ordering.
- Any other defect: **one line, don't pursue it.**

## 6. Counts

⚠️ `apps/commonplace/test` reports **~3278 tests**. ⛔ A count in the HUNDREDS
means a subtree ran and **the run is VOID.** Sub-set runs during bisection will
legitimately report fewer — that is expected there and ONLY there.
⚠️ Main's failure set is unstable; ⛔ **do not read green/red as a verdict on
anything except your own bisection question.**
