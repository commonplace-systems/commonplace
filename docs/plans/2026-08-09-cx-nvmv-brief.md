# BUILD BRIEF — CX-nvmv: make an absence assertion say what it received

**For:** Sol (codex)
**Ticket:** **CX-nvmv** (p3/bug)
**Worktree:** `/home/jes/sol-nvmv/wt` · **branch:** `sol/cx-nvmv`
**Test:** `apps/commonplace/test/commonplace/store/commit_store_telemetry_test.exs`
— *"a read (commit_log) emits no :call event"*

---

## 0. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ git metadata read-only, **leave
changes UNSTAGED**, no `git add`, no commit, **do not work around
`index.lock`**; ⛔ no serve/store route; every suite via
`bin/cp-test-guard --min N --apps N -- <cmd>`, **one at a time** (shared
`tmp/test_data`); ⚠️ **rc from the command itself, never a pipe**; ⚠️ **a count
from a piped listing is not a count.**

## 1. ⛔ THE DELIVERABLE IS THE DIAGNOSTIC, NOT NECESSARILY THE FIX

> **An absence assertion must name what it RECEIVED.**
> *"Expected none, got X from Y"* is minutes. *"Expected none, got some"* is
> months.

⇒ **Even if you cannot reproduce the flake, shipping the improved failure
message is a complete result.** The next person to hit it should learn the
cause from the red, not from an investigation.

## 2. What is known, measured

- Full store suite, fresh worktree off main, no local changes:
  **`5 doctests, 448 tests, 1 failure`** — this test.
- **Same file alone: 3 consecutive runs, 6 tests, 0 failures.** Same file on
  main: 0 failures. The same full suite ran **448/0** earlier the same night.
- ⇒ **Order- or load-dependent, not a defect in the code under test.**

**The shape:** the test asserts a READ emits **no** `:call` telemetry. A false
failure means an event arrived that the test did not expect — i.e. **another
test's handler, or another process's activity, leaked into the window.** That
is cross-test contamination (a handler not detached, a singleton surviving into
the next test), not a timing race in the subject.

⚠️ **`CommitStoreTelemetryTest` is not the only suspect** — any test in the
store directory that attaches a `[:commonplace, :commit_store, :call]` handler
or leaves a store running is a candidate. **Look at who else attaches.**

## 3. ⛔ Two things that are NOT acceptable resolutions

1. ⛔ **Muting, skipping, or loosening the assertion.** It guarantees that read
   paths do not emit write telemetry. **Removing it removes the guarantee, and
   nothing would ever report its absence.**
2. ⛔ **"It passes alone" as the diagnosis.** ⚠️ **That statement is TRUE and
   non-explanatory, which is the combination that terminates an investigation
   while feeling like a conclusion.** It is the observation that starts the
   work, not the answer.

## 4. Acceptance

1. ⭐ **The failure message names the offending event: its name, its metadata,
   and where it came from if determinable.** Demonstrate the new message by
   forcing an unexpected event during the assertion window — **paste the red.**
2. **If you find the contaminating source, fix that** (detach the handler, scope
   the store, isolate the test) and show the full store suite green **with
   counts**.
3. ⭐ **If you CANNOT reproduce it, that is a legitimate result** — say so, and
   report **what you tried and how many times**: seed variation, `--max-cases`,
   running the store directory repeatedly, running under load. ⛔ **A
   "could not reproduce" without its attempt count is not a result.**
4. Named suites, one at a time, with counts:
   - `apps/commonplace/test/commonplace/store` — **5 doctests + 448 tests on
     main; expect the 1 failure INTERMITTENTLY.** Report how many runs you did
     and how many were red — that ratio is itself data nobody has collected.
   - `apps/commonplace/test/commonplace/store/commit_store_telemetry_test.exs`
     — **6 tests, 0 failures on main.**
5. `mix compile --warnings-as-errors` rc=0.
6. **Name anything you could not verify in-sandbox** and stop rather than
   approximating.

⚠️ **Adjacent, check before treating separately:** **CX-wxxc** (singleton
whereis/start_link race in crypto+store+chat tests) may share a root cause.

## 5. Out of scope

- Changing what telemetry the store emits.
- Any other defect: **report it, don't fix it.**
