# BUILD BRIEF — CX-5gkw fix half: explicit sized budgets for the four inherited-default victims

**For:** Sol (codex) · **plan's #1 (suite reliability) — jes 16:57: "simple test fixes are top priority"**
**Worktree:** `/home/jes/sol-budgets/wt` · **branch:** `sol/cx-5gkw-budgets`
**Run log:** `/home/jes/sol-budgets/sol-run.log`

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ **UNSTAGED** only — no `git add`,
no commit, no push. ⛔ **No serve, no live store** (live store is
`/home/jes/commonplace/workspace/.commonplace/commits/`, process-derived).
⚠️ `mix deps.get` first. ⚠️ **rc from the command itself, never through a pipe.**
⛔ **NO BARE ZEROS** — any 0 arrives with a positive control.

⛔⛔ **:4002 PRE-FLIGHT BEFORE EVERY SUITE RUN — umbrella runs are mutually
exclusive on this box:**

```bash
h=$(ss -ltnp 2>/dev/null | grep -c ":4002"); [ "$h" -eq 0 ] || { echo "ABORT: :4002 busy"; exit 3; }
```

⭐ **ESCAPE HATCH:** if a target's budget genuinely cannot be sized a priori
(its workload is unanalysable), **report that for that target and leave it
unchanged.** A skipped target with a reason beats an invented number.

## 1. What is established (CX-5gkw — do not re-derive, do not re-litigate)

All 16 non-constant failures across 8 fixed-seed runs of
`apps/commonplace/test` were **wall-clock budget crossings**: 14× the
**inherited ExUnit default 60s test timeout**, 1× a `Task.await 10_000`,
1× the AuditChokePerf ratio (not yours — §3). Zero behavioural assertions
failed. The failing tests are slow-by-construction (hundreds of synchronous
durable ops) and their cost under suite load sits near the default budget,
crossing it stochastically.

⭐ **The fix pattern already exists IN-FILE**: `green/bursar_test.exs` lines
~475–520 — two sibling tests carry `@tag timeout: 300_000` / `600_000` with
basis comments that (a) state the workload in ops, (b) state why it is slow
under load, and (c) argue **why the raise masks nothing** (the deliverable is
a SIZE assertion, unaffected by duration). **That comment shape is the
required form for every budget you add.**

## 2. ⛔ THE DELIVERABLE — budgets with an A PRIORI basis, four targets, nothing else

⛔⛔ **FIX ≠ MAKE THEM PASS.** A budget widened until green is the instrument
silenced. Every number you write must be **derived from a stated workload
analysis written into the comment BEFORE you run the full suite**, never
tuned against a red run. Generous-but-finite is correct — the budget's job is
to catch HANGS, not to race the scheduler. A 10× headroom over the workload
estimate is acceptable **if stated**. ⛔ `timeout: :infinity` is forbidden.

⛔ **No behavioural change anywhere**: every assertion stays byte-identical,
every iteration count stays (the 200s, the 50, the 1..400s), no `async:`
edits, no `:skip`/`@tag :skip`, no `lib/` change, no fixture edits.

### T1 — `green/bursar_test.exs` · "a large permanent table stays bounded and survives restart at scale"

Workload: 200 distinct durable acquires (each a real commit) + a restart +
200-token reload — the same >200-synchronous-durable-ops class as its sibling
that already carries `600_000` for exactly this reason ("green at 44/0 in
isolation, blows the 60s default under a parallel suite run — observed
twice"). Same-class budget, same comment shape. The does-not-mask argument:
the deliverables are the reload-count and snapshot-size assertions, which do
not depend on duration.

### T2 — `tree/doc_builder_bounded_walk_test.exs` (module has NO timeout tags)

Every test here builds a 250–470-commit fixture chain via per-commit
`GenServer.call` — the observed 60s crossings die inside `build_chain`
**before any assertion runs**. Property required: every test whose fixture is
O(hundreds of commits) gets an explicit budget with a per-commit cost basis
in the comment. A `@moduletag timeout:` is acceptable if the comment covers
the module's shared fixture shape. Does-not-mask argument: the deliverables
are walk-COUNT and byte-equality assertions — work bounds, not time bounds.
⛔ Do NOT optimise the fixture itself — fixture cost is filed separately
(CX-5gkw residual, investigation-shaped, ruled out of this lane).

### T3 — `mud/bot_presence_cert_test.exs` · "stop immediately followed by send_input never hits a dead session pid"

Workload: 50 iterations × (session spawn + verb round-trip + stop + respawn
round-trip), each with real doc writes. ⛔ **The 50 stays** — the deliverable
is the race assertion inside the loop, and it has never been observed firing;
every recorded failure of this test is the 60s default expiring mid-loop.
Budget with a per-iteration basis. Does-not-mask argument: a real dead-pid
hit fails the in-loop assertion regardless of how long the loop may run.

### T4 — `store/commit_hoist_test.exs` · "retry-exhaustion fallback …" (the `Task.await(hammer, 10_000)` near line 304)

The one target with a MEASURED basis already on file: **CX-qzbh measured this
workload at 9.9–13.9s against the 10s await** — a budget sitting inside its
own workload's distribution. Size the await (and the test's own timeout if
your analysis says the default is also within range) from that measurement
with a stated margin, citing CX-qzbh in the comment. Also check the
`Task.await_many(tasks, 10_000)` near line 84: apply the same analysis; if
its workload is comfortably inside 10s, **leave it and say so** — only
budgets near their workload get resized.

## 3. ⛔ OUT OF SCOPE — each of these is a named trap

- ⛔ **`trust/audit_choke_perf_test.exs` — DO NOT TOUCH.** Its ratio budget IS
  its deliverable; CX-d0sc/CX-dsqc own it and widening is forbidden there.
- ⛔ **`trust_config_fail_closed_test.exs` — leave RED.** Class 1, CX-a2eb,
  gated on a pending plan decision. It fails by `==` assertion, not timeout —
  it is not in your class, and it is your CONSTANT: it must fail in every
  acceptance run. If it ever passes, your environment changed — report that.
- ⛔ **No fixture hand-seeding** (CX-8wh1's one-helper constraint stands).
- Any other defect you notice: **one line, don't pursue.**

## 4. ⛔ Acceptance — artifacts

1. **The diff**: exactly the four targets, each budget carrying the in-file
   comment shape — workload basis, load sensitivity, does-not-mask argument.
2. `mix compile --warnings-as-errors` rc=0, direct.
3. **THREE full runs** of `mix test apps/commonplace/test --seed 303`
   (default max-cases; seed 303 on purpose — today's baseline at this seed is
   5/3/4 failures with known sets, so your runs are directly comparable).
   Per run: `:4002` pre-flight, `cat /proc/loadavg` and `df -h .` **at start
   AND end**, rc direct, full counts, and **the full failure list WITH the
   FAILURE MODE of each failure** (TimeoutError vs assertion vs exit —
   quoted, not summarised). ⚠️ Redirect each run to its own file; never pipe
   `mix test` through anything.
4. **PASS =** across all three runs, **zero timeout-mode failures among the
   four targets**, with the quoted failure lists as the positive control that
   the runs were actually parsed. TrustConfigFailClosed red ×3 (the
   constant). AuditChokePerf may fail by ratio — report it, untouched.
5. **Population check**: ~3283 tests per run. ⛔ A count in the HUNDREDS means
   a subtree ran and THE RUN IS VOID.

## 5. Notes

- A default-max-cases full run is ~8–18 min depending on load; three runs
  plus compile fits well inside your window. Serialised runs are NOT needed.
- The comparison you must NOT make: do not tune any number because a run was
  red. If a target still crosses its NEW budget in your acceptance runs, that
  is a FINDING (the a-priori basis was wrong or the mechanism isn't load) —
  report it with the numbers and stop. Do not iterate the budget.
