# BUILD BRIEF — CX-q9sa: stop a test deleting the live singleton store's directory

**For:** Sol (codex)
**Ticket:** **CX-q9sa** (p1/bug) · **Worktree:** `/home/jes/sol-q9sa/wt` · **branch:** `sol/cx-q9sa`
**Run log:** `/home/jes/sol-q9sa/sol-run.log`

---

## 0. ⛔ READ THIS BEFORE ANYTHING ELSE — HOW THIS GETS FALSELY ACCEPTED

⛔ **DO NOT VERIFY THIS FIX BY RUNNING THE SUITE AND SEEING GREEN.**

**8 of the last 28 CI runs were ALREADY GREEN, by luck.** The failure depends on
test ORDER, so a green run after your change is **indistinguishable from a lucky
interleaving.** ⭐ *"The suite passes now"* is what finishing looks like, which is
exactly why it is the trap.

⇒ **VERIFY STRUCTURALLY:** prove that *no test **can** delete a directory the live
shared store holds* — not that no test *did* on one run.

⭐ **AND THE GUARD ITSELF NEEDS A POSITIVE CONTROL** (§4.2). An assertion that has
never been observed to fail is not evidence. **That is the defect class this whole
investigation was about; do not reproduce it in the fix.**

## 1. Environment contract (standing)

Named worktree off **current** `origin/main`; ⛔ leave changes **UNSTAGED**, no
`git add`, no commit, no push; ⛔ **no serve, no live store** — the live store is
`/home/jes/commonplace/workspace/.commonplace/commits/`, **process-derived, NOT
repo-root and NOT `data/`** (a stale decoy). ⚠️ **Fresh worktree needs `mix
deps.get` first** (you have network).

Suites via `bin/cp-test-guard`, one at a time; ⚠️ **rc from the command itself,
never through a pipe** — `mix test … | tail` returns `tail`'s rc.
⛔ **NO BARE ZEROS**: any `0` arrives with a positive control that the pattern
matches something.

## 2. THE MECHANISM — ESTABLISHED FACT, NOT SOMETHING TO DERIVE

⭐ **This is measured and settled. You have nothing to work out here, only
something to build. Do not re-investigate it, and do not explain it back.**

1. `config/test.exs` starts the **production-named singleton**
   `Commonplace.Store.CommitStore` via `Application.start`. **176 test files call
   it.**
2. `application.ex:64` — `data_dir = Application.get_env(:commonplace, :data_dir,
   "data")` is read **ONCE AT BOOT and never re-read.**
3. `commit_store.ex:1602` **and `:1643`** open CubDB with **`auto_compact: true`**
   (`:1069` is deliberately `false` — the corrupt-dir path).
4. **150 test files** call `Application.put_env(:commonplace, :data_dir, …)`:
   swap the env, do work, delete a derived path, restore.
5. ⇒ A test deleting a path that **is, or contains,** the boot-captured directory
   removes it **out from under a live store** — while correctly believing it only
   touched its own.
6. **Of those 150 files, ZERO are `async: true`** (138 explicit `async: false`, 12
   unspecified — ExUnit's default is false). ⇒ ⭐ **This is NOT a race. It is
   SEQUENTIAL state damage.** The seed decides the **order**, which decides
   whether the deletion lands before or after something touches the store.

**The CI signature:**

    GenServer.call(Commonplace.Store.CommitStore, {:create_commit, ...}) EXITs
    ** (MatchError) no match of right hand side value: {:error, :enoent}
        (cubdb 2.0.2) lib/cubdb.ex:1499: CubDB.trigger_compaction/1

⚠️ **AND BECAUSE `auto_compact: true`, THE ACTOR THAT TRIPS CAN BE THE STORE'S OWN
BACKGROUND TIMER — there need be no next caller at all.** The failure lands on its
own schedule, arbitrarily far from the cause.

## 3. What to build

**A structural guard that fires AT THE MOMENT OF DELETION.**

⭐ **Placement is the whole design, not a convenience:** a tripwire that waits to be
noticed (a broken store observed later) **inherits exactly the luck the 8 green
runs had** — compaction may fire, or may not, and the interval decides.

⇒ **Shape:** at the point a test deletes a directory, assert that the path is not
an ancestor-of-or-equal-to the directory the singleton captured at boot. It must
fail **loudly, at the offending site**, naming both paths.

- Put it somewhere **shared** — a case template or test helper — so it is not 150
  edits.
- The boot-captured dir must be read from **the store itself**, not re-read from
  app env. ⚠️ **Re-reading the env reproduces the bug inside the guard**, because
  the env is exactly what the offending test has swapped.

⛔ **DO NOT take the per-site path.** 517 `File.rm_rf` sites fixed individually is
150+ edits that **each look like they worked**. ⭐ **The singleton's existence in
test env is the defect, not the teardowns.**

## 4. ⛔ ACCEPTANCE — artifacts, and one of them must go RED

1. **The guard exists and is shared** — state where, and how many test files it
   covers without per-site edits.
2. ⭐⭐ **POSITIVE CONTROL, MANDATORY:** a test that points an `rm_rf` at the
   captured dir and **MUST FAIL the guard.** ⛔ **Paste the red.** Without it you
   have shipped an assertion nobody has ever seen fire.
3. ⭐ **NEGATIVE CONTROL:** an ordinary test that deletes its own tmp dir **passes
   untouched.** A guard that refuses everything passes every test in §4.2.
4. **Name any real offender the guard catches** — one line each, path + test.
   ⚠️ **Report them; do not go fix 150 files.**
5. `mix compile --warnings-as-errors` rc=0, and — **baseline first, both numbers,
   one suite at a time:**
   - `apps/commonplace/test/commonplace/trust` — **206 tests, 0 failures on main**
     *(measured 2026-08-09 16:0x; not 195/196/197/201, all stale in older briefs)*
   - `apps/commonplace/test/commonplace/view_action_dispatch_test.exs` —
     **14 tests, 0 failures on main**

⚠️ **`CommitHoistTest` fails ~50% of the time under load and is UNRELATED
(CX-qzbh — a 10s budget inside a 9.9–13.9s workload). If you see it, say so in one
line and move on.**

## 5. ⛔ Out of scope

- ⛔ **Do not re-investigate the mechanism, and do not explain it back to me.**
  §2 is established; build against it.
- ⛔ Do not fix individual teardowns. Do not change what any test deletes.
- ⛔ Do not change `auto_compact`, the singleton's boot, or `config/test.exs`'s
  `data_dir` — **those are the real fix and they are a separate, larger decision.**
  This ticket makes the damage **impossible to do silently**; it does not remove
  the singleton.
- Any other defect: **one line, don't pursue it.**

## 6. What you cannot verify in-sandbox

- ⛔ **Anything requiring the live serve** — report **UNVERIFIED** and stop.
- ⛔ **CI behaviour.** You cannot run CI, and per §0 a green run would not be
  evidence anyway. **Do not approximate it.**
