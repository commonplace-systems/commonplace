# BUILD BRIEF — CX-wzkr: the two-oracle conformance matrix

**For:** Sol (codex)
**Ticket:** **CX-wzkr** (p2/bug)
**Ruling being implemented — jes, 2026-08-08, verbatim:**

> *"Yjs compat should track both, if they disagree then 'stable' wins, but new
> features track the preview release"*

**Prerequisite discharged:** CX-4yva (merged @4de34b6) made the de-quadratic
guard load-independent, because this ticket makes CI heavier.

---

## 0. Environment contract (standing)

- **Named worktree**, named branch, off **current** `origin/main`.
- ⛔ **Git metadata read-only. LEAVE CHANGES UNSTAGED.** No `git add`, no
  commit, **do not work around `index.lock`.**
- ⛔ **No route to the live serve or live store.** None needed.
- ⚠️ **`mix test apps/<app>` selects NOTHING** and exits 0 — use
  `apps/yelixer/test`, and `bin/cp-test-guard --min N --apps N -- <cmd>`.
- ⚠️ **Run named suites ONE AT A TIME** (shared `tmp/test_data`).
- ⚠️ **rc from the command itself, never through a pipe.**
- ⚠️ **Read the source for signatures.**

## 1. ⛔ THE TWO INVARIANTS — restate them in your report

These are the parts that erode under implementation pressure. They sit above
the task because a matrix that violates either is worse than no matrix.

1. ⛔ **"STABLE WINS" MUST NOT BECOME "STABLE IS THE ONLY ONE WE LOOK AT."**
   A run where **stable passes and preview fails is NOT a pass and NOT a
   failure — it is a FINDING, and it must reach a human.** Disagreement between
   the lines is the single most valuable signal this suite can produce: advance
   warning of what breaks when v14 ships, months before it is forced on us.
   **A policy that resolves conflicts silently converts an early-warning system
   into a rubber stamp.**

2. ⛔ **A FIRST RED ON THE v14-ONLY PATH IS A SUCCESS, NOT A REGRESSION.**
   `Yelixer.Types.sub_type_to_json/2`'s `:xml_fragment` branch is v14-specific
   (per `3ce764f`: *"Yjs v14's unified YType encodes all nested types as typeref
   4"*). **Nothing has ever exercised it end-to-end.** If the preview oracle
   lights it up and it fails, that is this ticket working. ⛔ **Nobody may drop
   the preview oracle because it inconveniences a merge.**

## 2. Where things stand

- `apps/yelixer/test/fixtures/package.json` pins **one** oracle: `yjs 13.6.32`.
- `yjs_diff_driver.mjs:29` does a **static** `import * as Y from 'yjs'`, and
  `--check-import` (`:33`) exists so `setup_all` can verify that import
  resolves **by executing this exact module**.
- `diff_yjs_test.exs` runs **11 tests**; CI asserts that count
  (`.github/workflows/ci.yml:65-66`).
- ⚠️ **Measured, and the reason this ticket exists:** `diff_yjs` uses **scalar
  values only** — **zero occurrences of `__sub:`** in the test file — so
  `xml_fragment_to_json` is unreached under **either** oracle today. The port
  passes **11/0 against both** 13.6.32 and 14.0.0-rc.1.

## 3. The work

**Run the conformance suite against BOTH oracles.** Shape is yours; npm aliases
in one `package.json` (`"yjs": "13.6.32"`, `"yjs-preview": "npm:yjs@<version>"`)
plus oracle selection in the driver is one clean option, two install prefixes is
another. **Choose, and say why.**

⚠️ **Three traps, each of which produces a green that means nothing:**

1. ⛔ **The import guard must check THE ORACLE ACTUALLY IN USE.** Today
   `--check-import` executes the driver's own static import — which is right
   *because* there is one oracle. **If the driver gains a selection mechanism
   and the guard still checks the default, it is a proxy for the thing it
   means** — the exact defect CX-3mj2 fixed (`setup_all` checked for `node`
   rather than for the import resolving). **Whatever selects the oracle must be
   what the guard exercises.**
2. ⛔ **THE COUNT MUST BE PER-ORACLE.** CI asserts 11 tests ran. **A matrix that
   runs 11 once and reports success is the vacuous green with two oracles
   installed.** ⇒ **11 against stable AND 11 against preview — two counts, both
   asserted.**
3. ⚠️ **Pin the preview version deliberately and say which and why.** All v14
   releases are prereleases; the stale clone held `14.0.0-rc.1`. jes's *"new
   features track the preview release"* argues for the newest prerelease, but
   **inherit nothing silently** — CX-3mj2's lesson.

## 4. ⚠️ The dark branch — REPORT, don't necessarily fix

This ticket was filed because `:xml_fragment` is structurally unreachable under
a v13-only oracle. **Adding the preview oracle is what can light it up.**

⇒ **Establish and report: with the preview oracle in place, is
`xml_fragment_to_json` reachable by the existing 11 tests?** Almost certainly
**not** — they use scalars — so answer explicitly rather than assuming.

⇒ **Then: adding nested-sub-type coverage (a map whose value is a nested Y type)
is IN SCOPE ONLY IF IT IS CHEAP.** If it turns into a driver redesign, **stop
and report** — the matrix is this ticket's deliverable and the coverage can be
its successor. ⭐ **And if you do add it and it goes RED against preview, that
is a SUCCESS: report it as a finding, do not fix the port, do not drop the
oracle.**

## 5. Acceptance — paste real output

1. **Two counts: 11 tests ran against stable AND 11 against preview.** Not one
   number.
2. ⭐ **Removing EACH oracle in turn fails loudly** — demonstrate both, since a
   guard that only covers the default is the trap in §3.1.
3. ⭐ **Demonstrate the disagreement path reaches a human.** Force one oracle to
   disagree (e.g. perturb the installed preview package so it answers
   differently), and show the run **surfaces it as a finding while stable stays
   green** — a distinct status, a named non-blocking report, whatever you
   choose. ⛔ **If disagreement is silent, invariant 1 is violated no matter
   what the tests say.**
4. Named suites green, with counts, one at a time:
   - `apps/yelixer/test/yelixer/diff_yjs_test.exs --include diff_yjs` — **11 on main**
   - `apps/yelixer/test` — **1 doctest, 33 properties, 390 tests on main**
5. `mix compile --warnings-as-errors` rc=0.
6. **CI honestly reflects the matrix**, and if totals move, raise
   `bin/cp-test-guard`'s numbers **deliberately, in the same commit**.
7. **Say which criteria you could not verify in-sandbox** and stop rather than
   approximating.

## 6. Out of scope

- Fixing the port to satisfy the preview oracle — **report disagreements.**
- `Identity.converge/2` (CX-ged4), the yelixer extraction queue.
- Any other defect: **report it, don't fix it.**
