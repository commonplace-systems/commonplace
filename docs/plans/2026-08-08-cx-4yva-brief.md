# BUILD BRIEF — CX-4yva: measure operations, not microseconds

**For:** Sol (codex)
**Ticket:** **CX-4yva** (p2/bug) — *"cx_xes3_dequadratic_test asserts a
WALL-CLOCK RATIO (< 3x) and goes red under concurrent load"*
**Why p2 and why now:** it is a **prerequisite**, not cleanup. jes ruled that
Yjs compat tracks **both** lines (CX-wzkr), which makes CI a two-oracle matrix —
two npm installs and two suite runs on a shared runner, stacked on the
conformance step CX-3mj2 just added. **Landing that while this test is
load-sensitive makes the flake routine.**

---

## 0. Environment contract (standing)

- **Work in the named worktree**, on the named branch, off **current**
  `origin/main`.
- ⛔ **Git metadata is read-only. LEAVE CHANGES UNSTAGED.** Do not `git add`,
  do not commit, **do not work around `index.lock`** — hitting it is the
  sandbox working correctly.
- ⛔ **No route to the live serve or live store.** None needed here.
- ⚠️ **`mix test apps/<app>` selects NOTHING** and exits 0. Use
  `bin/cp-test-guard --min N --apps N -- <cmd>` and report counts.
- ⚠️ **Run the named suites ONE AT A TIME** — they share `tmp/test_data`.
- ⚠️ **Capture rc from the command itself, never through a pipe.**
- ⚠️ **Read the source for signatures.** Never infer.

## 1. ⛔ THE INVARIANT — restate it in your report

> **The replacement must be load-independent BY CONSTRUCTION, not merely less
> flaky.**

⛔ **Widening the threshold is NOT a fix.** A ratio of `< 5` instead of `< 3` is
the same test with more tolerance: it still measures the machine, it still goes
red on a busy runner, and **it will go red again the day CI gets heavier — which
is scheduled, right behind this ticket.** If your change would still fail when
the box is loaded, it is not this ticket's fix.

## 2. The defect

`apps/yelixer/test/yelixer/cx_xes3_dequadratic_test.exs:69`:

```elixir
ratio = large_us / max(small_us, 1)
assert ratio < 3,
  "map-heavy replay scaling ratio #{...}x (5k=#{small_us}us, 10k=#{large_us}us) " <>
    "suggests quadratic behavior reintroduced"
```

It times a 5,000-update replay and a 10,000-update replay and asserts the
second is under 3× the first — a proxy for *"no quadratic behaviour has been
reintroduced"* (the CX-xes3 de-quadratic work).

**MEASURED 2026-08-08:** red at **ratio 3.12x** (5k=91,754µs, 10k=286,494µs)
with two other suites running on the same box; then **3/3 GREEN in isolation**
minutes later. Roughly **4% of headroom** at the observed value.

⭐ **THE DEEPER PROBLEM, and the reason this is a bug rather than a nuisance: a
wall-clock ratio can be wrong in BOTH directions.** It goes red on a busy runner
with the code perfectly correct, and it would go **green on a fast one with
quadratic behaviour restored**, if the constant factors were small enough at
these sizes. ⇒ **A guard that can be wrong in both directions teaches people to
re-run rather than to look — which is how a real regression gets muted by the
very test built to catch it.**

## 3. The work

**Count the work done, not the time taken.** The quadratic behaviour this test
exists to catch is visible in *operations* — and operations are load-independent
by construction, which is the whole point.

Some candidate signals, in rough order of preference — **pick one, justify it,
and say what it would MISS**:
- a counter incremented at the site where the quadratic scan lived (the
  de-quadratic work knows where that is — read CX-xes3's commit, `5a308db`)
- items/blocks visited during replay, via an existing telemetry event or a
  new one
- reductions (`Process.info(pid, :reductions)`) around the replay — machine-
  independent, though it counts everything the process does

⚠️ **Whatever you choose, the assertion must be about GROWTH, not an absolute.**
Doubling the input should roughly double the count; quadratic behaviour makes it
roughly quadruple. Assert the ratio **of counts**, which no amount of CPU
contention can move.

⚠️ **If you conclude no faithful operation counter is reachable without changing
production code more than this ticket warrants — say so and stop.** A ticket
that turns into a yelixer refactor is a different ticket. Report the finding.

## 4. Acceptance — red-first, and paste real output

1. ⭐ **Demonstrate the new assertion RED by reintroducing quadratic
   behaviour**, not by asserting an impossible number. The de-quadratic fix is
   in `5a308db` (CX-xes3, *"de-quadratic delete application + map-key conflict
   resolution"*) — revert or defeat that path locally, show the new test catch
   it, restore. **That is the whole ticket: a guard that has not been shown
   catching the thing it names is not a guard.**
2. ⭐ **Demonstrate it is LOAD-INDEPENDENT.** Run it green while the box is
   deliberately busy — e.g. another suite running concurrently, or a CPU
   burner. The old assertion goes red under exactly that condition; yours must
   not. **Paste both.**
3. Named suites green, with counts, one at a time:
   - `apps/yelixer/test/yelixer/cx_xes3_dequadratic_test.exs` — **5 on main**
   - `apps/yelixer/test` — **1 doctest, 33 properties, 390 tests on main**
4. `mix compile --warnings-as-errors` rc=0.
5. **Say which criteria you could not verify in-sandbox**, and stop rather than
   approximating.

## 5. Out of scope

- The de-quadratic implementation itself — you are fixing its **guard**, not
  its code. Touch `5a308db`'s logic only to demonstrate the red in §4.1, then
  restore it.
- The other describe block in that file (conflict-resolution correctness) —
  leave it alone.
- Any other defect: **report it, don't fix it.**
