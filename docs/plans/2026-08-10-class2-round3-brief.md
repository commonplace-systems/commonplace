# BUILD BRIEF — class 2 round 3: is the variable CONCURRENCY? (measurement only)

**For:** Sol (codex) · **Worktree:** `/home/jes/sol-class2/wt` · **branch:** `sol/class2-attribution`
**Run log:** `/home/jes/sol-class2/sol-run3.log`

## 0. Standing contract

⛔ UNSTAGED only, no commit/push. ⛔ No serve, no live store. ⚠️ `mix deps.get` first.
⚠️ rc from the command itself. ⛔ NO BARE ZEROS.
⛔⛔ **:4002 PRE-FLIGHT BEFORE EVERY RUN** — umbrella runs are mutually exclusive:
```bash
h=$(ss -ltnp 2>/dev/null | grep -c ":4002"); [ "$h" -eq 0 ] || { echo "ABORT: :4002 busy"; exit 3; }
```
⚠️ An `:eaddrinuse` run exits **rc=1 with an EMPTY summary** — that is an ENVIRONMENT
error, **never** a result.
⭐ **ESCAPE HATCH:** if the method doesn't fit, say so and stop. ⭐ **You did this
twice and both refusals were correct** — round 1's method couldn't see the
variable, round 2's baseline wasn't there. **Refusing IS the deliverable when the
method is inapplicable.**

## 1. What is established (measured, not assumed)

Same tree, **same seed 303, same invocation form**, repeated:

    5 · 3 · 4 · 1 failures   (and one run with the victim green)

⇒ ⛔ **Seed + invocation form FIX THE ORDER, and the outcome still varies.**
**THE VARIABLE IS NOT ORDER**, so no bisection over files or populations can find
it. (That is why both your refusals were right.)

Also measured: all three victims are **`async: false`** — `green/bursar_test.exs`,
`tree/doc_builder_bounded_walk_test.exs`, `mud/bot_presence_cert_test.exs`.
**60 of 370** files are `async: true`.

⇒ The victims do not race each other. **The live hypothesis is RESIDUE** —
background processes, timers or shared state left by concurrently-run async
modules, whose timing varies run to run.

## 2. ⛔ THE TASK — one measurement, no fix

**Does serialising the suite collapse the spread?**

Run **`mix test apps/commonplace/test --seed 303 --max-cases 1`**, **FIVE times.**
Report **per run**: rc, test count, and the **full failure list**.

⚠️ **FIVE RUNS IS THE POINT, NOT CEREMONY.** The baseline spans 1–5 failures, so a
single serialised run proves nothing in either direction — a low draw is inside
the existing distribution. ⛔ **Do not stop early because the first run looks
clean.**

⚠️ These runs will be **much slower** (no parallelism). That is expected. If a
run exceeds ~60 min, report it and continue rather than killing it.

## 3. ⛔ Acceptance

1. **Five serialised runs**, each with rc + count + failure list.
2. ⭐ For comparison, **THREE MORE runs at the default `--max-cases`**, same seed,
   interleaved with the above if you like — ⛔ **do not reuse my numbers**; the
   machine's load today is not the machine's load when I measured.
3. ⭐ **State the two distributions plainly** (serialised vs default) — counts and
   which tests. ⛔ **Do NOT conclude a mechanism.** Report the distributions.
4. `mix compile --warnings-as-errors` rc=0.

## 4. ⛔ Out of scope

- ⛔ **Change nothing.** No `async:` flag edits, no timeouts, no skips, no fixes.
  ⭐ Setting `async: false` broadly would hide the variable and cost suite
  wall-clock permanently — **identification first.**
- ⛔ Do not touch `TrustConfigFailClosedTest` (class 1). ⚠️ It will fail in EVERY
  run — that is expected and it is your **constant**: if it ever passes, something
  about your invocation changed.
- ⛔ Do not name a mechanism. Distributions only. Several plausible-and-wrong
  mechanisms have already died on this problem.
