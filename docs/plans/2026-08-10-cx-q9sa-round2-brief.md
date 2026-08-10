# BUILD BRIEF — CX-q9sa ROUND 2: the cleanup REMOVES the store instead of RESTORING it

**For:** Sol (codex) · **plan's #3, round 2** · **Worktree:** `/home/jes/sol-q9sa-pair/wt`
**branch:** `sol/cx-q9sa-pair` (your round-1 work is still there, UNSTAGED — keep it)
**Run log:** `/home/jes/sol-q9sa-pair/sol-run2.log`

---

## 0. Environment contract (standing)

⛔ Leave changes **UNSTAGED**, no `git add`, no commit, no push. ⛔ **No serve, no
live store** — the live store is `/home/jes/commonplace/workspace/.commonplace/commits/`,
**process-derived, NOT repo-root and NOT `data/`**. ⚠️ `mix deps.get` first.

⚠️ **rc from the command itself, never through a pipe.** ⛔ **NO BARE ZEROS** — any
`0` arrives with a positive control that the pattern matches something.
⚠️ Redirect long suites to a file; do not pipe `mix test` to `tail`.

⭐ **ESCAPE HATCH (standing, and it fired last round — use it again):** if the
remedy below does not fit what you measure, **that is a FINDING. Report it and
stop. Do not force the prescribed fix.** Last round §4 of the brief was wrong
and you were right not to follow it.

## 1. ⭐ WHAT ROUND 1 GOT RIGHT — KEEP ALL OF IT

Verified by the reviewer independently, not taken from your report:

- ✅ **The enumeration.** 58 offenders (mcp 21, web 20, CLI 17; process/trust/
  bots/yelixer 0), per-hit table with both paths. ⭐ **You reported 58 over the
  brief's prior of 41 and said so — correct, and the 17 CLI offenders had never
  been measured by anyone.** An independent run of mcp by the reviewer found the
  same 21 fires in the same two files.
- ✅ **The guard was not weakened.** All 8 restored files confirmed
  **byte-identical to `58718f2`** by md5, per file.
- ✅ **No test was deleted or skipped.**
- ✅ **The CLI fix shape is CORRECT and is the model for this round** (§3).
- ✅ The red control, and `--warnings-as-errors` rc=0.

## 2. ⛔ THE DEFECT: mcp/web REMOVE the production-named store and never put it back

Your mcp/web cleanup does:

```elixir
_ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
_ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
Application.put_env(:commonplace, :data_dir, prior_data_dir || "tmp/test_data")
File.rm_rf!(dir)
```

That correctly stops the store **before** the delete — the guard stops firing,
which is why it looks fixed. ⛔ **But `delete_child` REMOVES the child spec
permanently. For the rest of the run there is NO `Commonplace.Store.CommitStore`
at all**, so every later test file that uses the production-named store dies:

```
** (exit) exited in: GenServer.call(Commonplace.Store.CommitStore, {:create_commit, ...})
   ** (EXIT) no process: the process is not alive or there's no process
             currently associated with the given name
```

**Measured by the reviewer in YOUR worktree** — all 9 in `CatTest`, whose setup
needs that store:

| suite | seed | result |
|---|---|---|
| mcp | **839791** | **156 tests, 9 failures** |
| mcp | **839791** (repeat) | **156 tests, 9 failures** — deterministic at seed |
| mcp | 111111 | 156 tests, **0 failures** ⚠️ |
| mcp | **222222** | **156 tests, 9 failures** |

⭐⭐ **AND THIS IS WHY YOU REPORTED GREEN HONESTLY.** The failure is
**ORDER-DEPENDENT**: it only appears when a file needing the production store
runs *after* `bd_tools_test`/`bd_write_tools_test`. Your run drew a lucky seed.
⛔ **The reviewer made the SAME mistake first** — replicated your fix
independently, got mcp 156/0, and concluded the question was settled. One green
run is not a verdict for an order-dependent defect. **That is the same class as
the bug this whole ticket is about: the seed decides the order, and the order
decides the outcome.**

## 3. ⭐ THE REMEDY IS YOUR OWN CLI FIX — RESTORE, DON'T REMOVE

You already got this right for CLI:

```elixir
_ = Application.stop(:commonplace)
Application.put_env(:commonplace, :data_dir, "tmp/test_data", persistent: true)
File.rm_rf!(workspace); File.rm_rf!(sync_dir)
{:ok, _} = Application.ensure_all_started(:commonplace)   # <-- PUTS IT BACK
```

⇒ **Apply that principle to mcp and web: the teardown must leave the world as it
found it.** A test that replaces a supervised singleton owes a restoration, not
just a shutdown. Restart the child under the ORIGINAL `data_dir` after deleting
the scratch dir (either by re-adding the child spec, or the `Application.stop`/
`ensure_all_started` pattern above — your call, state which and why).

⚠️ **Ordering still matters and must not regress:** the store must be DOWN
before `rm_rf` (or the guard fires again) and back UP after (or later files die).
Both halves, in that order.

## 4. ⛔ THE SECOND DEFECT — web, 1 failure, a background writer racing the delete

```
1) test auth no token → 403 (CommonplaceWebWeb.FederationControllerTest)
   ** (File.Error) could not remove files and directories recursively from
      "/tmp/cp_fed_ctrl_797726650": file already exists
```

and in the same run, repeatedly:

```
[error] Commonplace.Trust.AuditDispatcher: FAILED to persist 3 denial audit
record(s) — denials are still being ENFORCED but are no longer being RECORDED
reason={:exit, {:noproc, ...}}
```

⇒ **`AuditDispatcher` is still writing into the directory while it is being
deleted** — `rm_rf` gets a directory that keeps becoming non-empty (surfacing as
the misleading "file already exists"). ⭐ **Measure whether stopping/draining the
dispatcher before the delete removes it.** ⛔ Do NOT paper over it with a retry
loop or by ignoring the rm_rf error. **Baseline web on main is 134/0, so this is
new.**

## 5. ⛔⛔ ACCEPTANCE — A SINGLE GREEN RUN IS NOT ACCEPTABLE THIS ROUND

⭐ **This is the whole point of round 2. The defect is order-dependent, so a
verification that runs one order proves nothing.**

1. ⭐⭐ **SEED SWEEP: every suite below, at FIVE seeds each, INCLUDING 839791 and
   222222** (both known-red today). **Report the count for every seed
   individually** — not "all green", the actual numbers, one line per seed.
2. ⭐ **Prove the restoration DIRECTLY, not just via green suites:** after a
   teardown that replaced the store, show `Process.whereis(Commonplace.Store.CommitStore)`
   is **alive again** and its `data_dir` is the ORIGINAL one. A green suite is
   circumstantial; this is the property.
3. ⭐ **The guard's RED CONTROL must still go red** after the cleanup — re-prove
   it, do not cite round 1.
4. **Guard files still byte-identical to `58718f2`** (they are now — keep it).
5. `mix compile --warnings-as-errors` rc=0.

## 6. SUITES — ALL SEVEN, and ⚠️ A NAMED SUITE WITHOUT A COUNT IS UNVERIFIED

| suite | on-main count |
|---|---|
| `apps/commonplace/test/commonplace/process` | 70 tests, 0 failures |
| `apps/commonplace/test/commonplace/trust` | 213 tests, 0 failures |
| `apps/commonplace_web/test` | 12 features, 134 tests, 0 failures, 12 excluded |
| `apps/commonplace_mcp/test` | 156 tests, 0 failures |
| `apps/commonplace_cli/test` | 97 tests, 0 failures |
| `apps/commonplace_bots/test` | 276 tests, 0 failures |
| `apps/yelixer/test` | 1 doctest, 33 properties, 390 tests, 0 failures, **11 invalid, rc=2** |

⭐ *(All measured by the reviewer on clean main `390433f`, load ~8–10.)*

⛔ **yelixer: use `mix test apps/yelixer/test` — the app-dir form
`mix test apps/yelixer` RUNS NOTHING AND EXITS 0** (measured: zero bytes of
output). Its `rc=2` + `11 invalid` is **PRE-EXISTING on main**, is NOT yours, and
must NOT be "fixed" here — just report the count so we can see it is unchanged.

⚠️ Load-marginal, one line each if seen then move on: `SandboxExecTest` (fixed
800ms sleep), `CommitHoistTest` (CX-qzbh), `GhostReaperLivenessTest` (did not
reproduce on the reviewer's bots baseline: 276/0).

## 7. ⛔ Out of scope

- ⛔ Do not weaken the guard; do not delete or skip any test. Unchanged.
- ⛔ Do not remove the test-env singleton — that is the root defect and a much
  larger separate project. This ticket makes deletion SAFE, not the singleton
  ABSENT.
- ⛔ Do not fix yelixer's 11 invalid, the CLAUDE.md yelixer command, or
  `GhostReaperLivenessTest`. Separately filed.
- Any other defect: **one line, don't pursue it.**
