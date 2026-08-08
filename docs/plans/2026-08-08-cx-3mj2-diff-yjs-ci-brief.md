# BUILD BRIEF — CX-3mj2: make `diff_yjs` runnable in CI

**For:** Sol (codex)
**Ticket:** **CX-3mj2** (p1/bug) — *"Make diff_yjs runnable in CI — de-hardcode
the yjs driver import AND assert 11 tests RAN (a count, never '0 failures');
skip guard must check the import resolves, not that node exists"*
**Design authority:** `/home/jes/commonplace-plan/docs/plans/2026-08-08-yelixer-extraction-queue.md`
§2, §2.1, §2.2.

---

## 0. Environment contract (standing — true of every Sol task)

- **Work in the named worktree**, on the named branch, off **current**
  `origin/main`.
- ⛔ **Git metadata is read-only. LEAVE YOUR CHANGES UNSTAGED.** Do not
  `git add`, do not commit, and **do not work around `index.lock`** — hitting
  it is the sandbox working correctly, not an obstacle to route around.
- ⛔ **No route to the live serve, and none is needed.** Do not attempt one.
- ⚠️ **You have network access** for this task (npm/deps will fetch rather
  than fail). That is deliberate and scoped to installing yjs.
- ⚠️ **Read the source for signatures.** Never infer an arity or return shape
  from a name, a docstring, or this brief.
- ⚠️ **Capture the return code from the command itself, never from a pipe.**
  A pipeline's status is the *tail's* status.
- ⚠️ **`tmp/test_data` is shared** — do not run overlapping suites.

## 1. ⛔ THE TWO INVARIANTS — state these back in your report

These are what the work must land, independent of how you get there. If your
implementation satisfies the task but violates either of these, it is wrong.

1. ⛔ **THE ACCEPTANCE IS A COUNT: CI must assert that 11 TESTS RAN.**
   Never an exit code. Never "0 failures". `setup_all` returns
   `{:skip, "node not found in PATH"}` — so a runner that loses node **skips
   all 11 and reports success with zero conformance coverage.** An exit-code
   check cannot tell that apart from a real pass.
2. ⛔ **A MISSING ORACLE MUST FAIL LOUDLY, NOT SKIP.** The guard must check
   that the driver's *import resolves*, not merely that `node` exists.

**Both halves are required, and neither substitutes for the other.** Invariant
2 alone still passes green on an empty run; invariant 1 alone leaves a
confusing failure when the oracle is legitimately absent.

⇒ These are stated as invariants because the tree moves under long-running
work. A conflict is survivable — it's loud. **The dangerous regression is the
one that produces no conflict at all.** A stated invariant survives a moved
base; a base does not.

## 2. The baseline you are protecting (measured, not assumed)

**`diff_yjs` is GREEN today: 11 tests, 0 failures, rc=0** — run on main
@1e4ae3b with `--include diff_yjs`, from the **umbrella root**. Verified
statically that 11 is the module's full extent: 4 describe blocks (text / map /
array / envelope), no properties, no per-test `@tag`s.

⇒ So this is **not** "establish an unknown." The port **does** agree with Yjs
today, and **nothing guards that**. The 4,749 lines of in-tree growth did not
break conformance — the single most reassuring fact available about the
yelixer extraction. You are installing a ratchet under a known green,
immediately before the step most likely to break it.

⚠️ **Two known ways to get a NON-ANSWER out of this suite. Both observed; do
not rediscover them:**
- From `apps/yelixer`, `mix test` dies on unfetched deps.
- From the umbrella root, **`mix test apps/yelixer` selects ZERO tests and
  exits 0** — no summary line, clean exit, indistinguishable from a pass. The
  working form is `mix test apps/yelixer/test`.
⇒ `bin/cp-test-guard` exists for exactly this. Use it:
`bin/cp-test-guard --min 11 --apps 1 -- mix test <paths> --include diff_yjs`.

## 3. The defect

`apps/yelixer/test/fixtures/yjs_diff_driver.mjs:29`:

```js
import * as Y from '/home/jes/yelixer/yjs/src/index.js'
```

An absolute path into one person's home directory, pointing at
**`/home/jes/yelixer`** — the stale standalone clone the yelixer extraction is
about to re-converge. Three consequences:

1. **The extraction target is currently load-bearing infrastructure for
   commonplace's conformance test.** Moving or re-cloning that directory
   silently breaks the one test nobody runs.
2. **The skip guard doesn't cover the actual dependency.** `setup_all` checks
   `System.find_executable("node")` — it does *not* check that the driver's
   import resolves. Node present + directory gone doesn't skip cleanly; it
   fails inside the port. A guard checking a **proxy** for the thing it means.
3. That directory holds Yjs **v14.0.0-rc.1** as a gitlink/submodule entry.

## 4. Work

⛔ **SEQUENCE-CRITICAL: de-hardcode the import and pin the version BEFORE
anything touches `/home/jes/yelixer`.** The green exists *because* the stale
clone happens to sit at that path with that gitlink. Lose this ordering and we
lose both the baseline and the ability to attribute a later break to the merge
versus the move. (Nothing in *this* ticket touches that clone — the ordering
constraint is why this ticket goes first in the queue.)

1. **De-hardcode `yjs_diff_driver.mjs:29`.** Vendor or npm-install yjs.
2. ⚠️ **Pin the yjs version DELIBERATELY, and say which and why in your
   report.** The current v14.0.0-rc.1 is **someone's old choice, not a
   considered one** — do not inherit it silently. If you pin it, say that you
   chose to; if you pin something else, say why.
3. **Fix the skip guard** so it checks the driver's import resolves.
4. **Add the node step to `.github/workflows/ci.yml`** and drop
   `--exclude diff_yjs`.
   ⚠️ Note the CI test step is already wrapped in `bin/cp-test-guard --min 4200
   --apps 6`. If dropping the exclusion changes the totals, **raise those
   numbers deliberately in the same commit** — never lower them to get green.

## 5. Acceptance — paste real output for each

1. CI runs `diff_yjs` unexcluded and **asserts 11 tests ran** (a count).
2. **Removing the yjs dependency makes it FAIL LOUDLY rather than skip** —
   demonstrate this: break the dependency on purpose, show the red, restore.
   ⭐ **A guard that has not been shown failing is not a guard.** This is the
   whole ticket; do not report it green without having seen it red.
3. `mix compile --warnings-as-errors` rc=0.
4. Test suites green **with counts**, via `bin/cp-test-guard`.
5. The version you pinned, and the reason.

## 5a. ⛔ PRE-DECLARED ACCEPTANCE CONTROL — is yjs still in the loop?

**Written 2026-08-08 17:26Z, BEFORE the diff exists**, deliberately: at
acceptance there will be a green suite and a finished run pulling toward
"it's fine," and that is exactly when a criterion invented on the spot bends.
This one is fixed in advance and is not negotiable at review time.

Sol's run has produced `apps/yelixer/test/fixtures/yelixer_oracle_{text,map,arr}.bin`.
Those may be entirely legitimate. The question that decides it is **not** "does
the suite pass", "is it faster", or "does the diff look right":

> ⛔ **CAN THIS TEST FAIL BECAUSE OF SOMETHING YJS DOES?**

- ✅ **Legitimate:** yjs executes on **every run**, and the `.bin` files are
  *inputs* — seeds, corpora, recorded edit scripts fed **through** the live
  library. A divergence introduced by yjs still surfaces.
- ⛔ **Not legitimate:** the `.bin` files are yjs's *outputs*, compared against
  ours, with yjs **no longer invoked**. Then upgrading yjs can never fail this
  test, and the conformance suite has become **a regression test against our
  own past behaviour, wearing the conformance name.** It would still report
  `11 tests, 0 failures`. It would still satisfy §1's count assertion. And the
  ratchet installed to protect the extraction would be measuring nothing about
  the thing it is named after.

⇒ That is the **non-diagnostic-signature failure promoted to a whole suite**:
the observable stays identical while what it discriminates quietly empties out.
Same family as the empty-DM red that this morning turned out to be a dropped
`Map.keys/1` — and as [[the zero-selection green]], where the output of a run
that tested nothing was indistinguishable from a pass.

### The falsifier (run this; do not settle it by reading the diff)

**Bump or corrupt the pinned yjs, and confirm the suite goes RED.**

```bash
# in the worktree, after the change lands
<perturb the pinned yjs — bump the version, or corrupt the installed package>
bin/cp-test-guard --min 11 --apps 1 -- mix test <diff_yjs paths> --include diff_yjs
# MUST be red. If it stays green, yjs is not in the loop, whatever the
# file layout suggests.
```

⚠️ **This is a better test than reading the diff**, because a vendored-oracle
design can be written to look exactly like a live one. Same move as the
boundary checker's tamper control: **prove it can fail for the reason it exists.**

### If it is a vendored oracle

A captured oracle may still be legitimate **as a speed-up — but only if the
live path is retained and actually run somewhere.** In that case acceptance has
**two counts, not one**: the fast path's and the live path's.

⛔ **If the live path has been traded away for speed, that is a scope change on
the ticket whose entire justification was that the live path exists.** Bounce
it — "report it, don't fix it" — rather than merging with a note.

## 6. Out of scope

- Anything touching `/home/jes/yelixer` (the stale clone) — later tickets.
- The extraction itself (CX-1mn4 → CX-fbah → CX-b6mz → CX-71m2 → CX-bx59).
- Any *other* defect you find: **report it, don't fix it.**
