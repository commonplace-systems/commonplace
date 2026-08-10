# BUILD BRIEF — class 2 round 2: bisect WITHOUT changing the invocation form

**For:** Sol (codex) · **plan's #1 (suite reliability), class 2**
**Worktree:** `/home/jes/sol-class2/wt` · **branch:** `sol/class2-attribution`
**Run log:** `/home/jes/sol-class2/sol-run2.log`

---

## 0. Environment contract (standing)

⛔ **UNSTAGED** only — no `git add`, no commit, no push. ⛔ No serve, no live
store. ⚠️ `mix deps.get` first. ⚠️ rc from the command itself, never through a
pipe. ⛔ **NO BARE ZEROS.**

⛔⛔ **:4002 PRE-FLIGHT BEFORE EVERY RUN — umbrella runs are mutually exclusive:**

```bash
h=$(ss -ltnp 2>/dev/null | grep -c ":4002"); [ "$h" -eq 0 ] || { echo "ABORT: :4002 busy"; exit 3; }
```

⚠️ An `:eaddrinuse` run exits **rc=1 with an EMPTY summary** and looks like
catastrophe. **A run with no counts is an ENVIRONMENT error, never a result.**

⭐ **ESCAPE HATCH:** if the method doesn't fit what you measure, **report it and
stop.** ⭐ **You did exactly this in round 1 and it was the right call —
"UNKNOWN, and here is why the method cannot work" was more valuable than a
bisection would have been.**

## 1. ⭐ WHAT ROUND 1 ESTABLISHED — you were right and the method was wrong

You found, and the reviewer independently re-derived:

```
mix test apps/commonplace/test --seed 303        → 3283 tests, 5 FAILURES
mix test <victim> <the same 370 files> --seed 303 → 3283 tests, 1 FAILURE
```

⇒ **SAME SEED, SAME TREE, SAME 3283 TESTS — 5 failures vs 1.** A seed shuffles a
STARTING ORDER, and Mix's directory glob is not the same input as an explicit
file list. **`--seed N` is one order PER INVOCATION FORM.**

⇒ ⛔ **File-list bisection cannot attribute these failures — the variable is not
a member of any file set.** Refusing to bisect was correct.

## 2. ⭐ THE METHOD THAT WORKS: change the POPULATION, not the INVOCATION

Keep running **exactly** `mix test apps/commonplace/test --seed 303` every time.
Shrink the population by **temporarily MOVING test files out of the tree**.

```bash
HOLD=/tmp/class2_held.$$; mkdir -p "$HOLD"
trap 'cd <wt>; for f in "$HOLD"/*; do ...restore to recorded path...; done' EXIT INT TERM
```

⛔ **RESTORE IS MANDATORY AND MUST SURVIVE A CRASH** — record each file's
original path, restore via `trap`. ⚠️ A half-restored tree is worse than no
result: it silently changes every later measurement.

### The loop

1. **Confirm the red baseline**: full directory, seed 303 → expect the 5
   failures above (`bounded persistence` ×2 is the victim pair).
2. **Move out half the OTHER test files.** Re-run the SAME command.
3. **Keep the half that stays RED.** Repeat.
4. ⛔ **REPORT THE TEST COUNT AT EVERY STEP.** A shrinking population legitimately
   reports fewer tests — but **a count that collapses to near-zero means your
   move went wrong and the "green" is vacuous.** This is the denominator trap
   that voided an entire round of CX-q9sa.
5. ⚠️ **If BOTH halves go green, the culprit is a COMBINATION** — say so and
   report the smallest red set reached. **Do not force it to one file.**

## 3. ⛔ Acceptance — artifacts

1. **The red baseline**, pasted, with its count.
2. ⭐ **Per-step table: files moved out (count), files remaining (count), TEST
   COUNT, rc, and whether the victim was red.**
3. ⭐ **The minimal red set**, plus the CONTROL that the victim ALONE (same
   directory-form invocation, only the victim present) is **GREEN** — without
   the green half, "minimal" is unproven.
4. ⭐⭐ **PROOF THE TREE IS RESTORED**: `git status --porcelain` clean at the
   end, and the full-directory run reproducing the ORIGINAL 5-failure baseline.
   ⛔ Without this, every later measurement on this worktree is suspect.
5. `mix compile --warnings-as-errors` rc=0.

## 4. ⛔ Out of scope

- ⛔ **Do not fix anything.** Attribution only — no test is skipped, tagged,
  reordered, deleted or repaired.
- ⛔ **Do not assert whether the invocation difference is ORDER or CONCURRENCY
  GROUPING** (`async` batching / `max_cases`). That is recorded as **UNKNOWN**
  and is not this ticket's question. ⭐ Several plausible-and-wrong mechanisms
  were proposed and retracted on this problem within twelve hours; do not add
  another.
- ⛔ Don't touch `TrustConfigFailClosedTest` (class 1) or `AuditChokePerfTest`
  (class 3). `TrustConfigFailClosed` will stay red throughout — **that is
  expected and correct**, and it is a useful constant: if it ever goes green,
  your population changed in a way you did not intend.
