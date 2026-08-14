# CX-hzad build brief: make `application.ex`'s comment TRUE

> **The work's ticket is CX-hzad.** Base: **the commit that adds this brief**
> — ⚠️ *not a sha; committing a brief moves HEAD past any sha it records.*

## ⛔⛔⛔ READ THIS FIRST — **YOUR SANDBOX CANNOT REPRODUCE THE BUG. YOU MUST BUILD THE BROKEN STATE.**

**The defect only appears on a checkout that has ALREADY RUN TESTS.** Your
worktree is fresh, so `apps/commonplace/tmp/test_data/` does not exist and
**everything will look fine before you change anything.**

⇒ ⭐ **CONSTRUCT THE DIRTY STATE FIRST, and confirm you have reproduced the
failure BEFORE you fix it:**

```
mkdir -p apps/commonplace/tmp/test_data
printf 'cc70aa0d-3cbe-4b4c-a16e-b91d9414c10f\n' > apps/commonplace/tmp/test_data/root
cd apps/commonplace && mix test test/commonplace/chat/compute_rehydrator_test.exs
   EXPECT: 5 tests, 1 failure
       ** (MatchError) ... {:error, {:already_started, #PID<...>}}   at :104
```

⛔ **IF THAT DOES NOT GO RED, STOP AND REPORT — do not "fix" a bug you have not
seen.** ⚠️ *An absent `tmp/test_data` and a working gate produce the same green.*

## What is actually wrong

`Commonplace.Application.compute_rehydrator_children/0` starts the rehydrator
when `Workspace.root_uuid()` resolves. Its comment says:

> *"Workspace-gated like the presence Reaper — **no rehydrator on test runs** /
> fresh installs."*

⛔ **THE CODE DOES NOT ENFORCE THAT.** `root_uuid/0` is a plain **file read** of
`<data_dir>/root`; under test `data_dir` is `tmp/test_data`, so a **leftover
`root` file makes it succeed** and the rehydrator starts — then the test's own
`start_link` collides.

⭐ **Measured on the host, both directions, fixture mtime preserved:**

```
tmp/test_data/root moved AWAY  → 5 tests, 0 failures
moved BACK (same bytes)        → 5 tests, 1 failure
the file's mtime: 2026-04-27   ← a four-month-old leftover
```

⇒ ⭐⭐ **SO THE PROTECTION IS HOLDING BY ACCIDENT: it is a root lookup that
HAPPENS to fail on clean checkouts.** ⛔ **THE FIX IS TO MAKE THE COMMENT TRUE,
NOT TO SOFTEN THE COMMENT.**

## ⭐ The fix, as ranked

**Gate the rehydrator on an EXPLICIT config flag set for serves in
`config/runtime.exs` — exactly the `deploy_gap_monitor_on_boot` pattern that
shipped today** (`application.ex` `deploy_gap_monitor_children/0`, and the
`if serving? && data_dir do` block in `runtime.exs`). ⇒ **Convert an accident
into a DECLARATION.**

⛔ **THE FLAG'S ABSENCE MUST NOT SILENTLY RE-ENABLE.** ⚠️ **A serve without the
flag is a NAMED refusal or a LOUD default — never a quiet one.** *State which
you chose and why.*

## ⛔ Acceptance

1. ⭐⭐ **RED-FIRST, CONSTRUCTED: the fixture-present case reproduces the failure
   BEFORE the fix** (recipe above), **and goes GREEN after.** Report both
   verbatim.
2. ⭐ **The gate reads BOTH WAYS**: flag set ⇒ child present; flag absent ⇒ no
   child. ⚠️ *A gate only ever seen in one position is not known to work — we
   shipped one of those today.*
3. ⭐ **The fixture-present case must ALSO be green** — that is the whole point.
   *Do not make it pass by deleting `tmp/test_data`; the fix must work on a
   checkout that has run tests, because that is every real checkout.*
4. **Tests land as files with their own counts from the tree.**

## ⭐⭐ RIDER, IN THIS ROUND — the baseline, WITH ITS ENVIRONMENT

⛔ **A BARE COUNT IS AN ACCEPTANCE FAILURE ON THIS TICKET, not a formatting
nit.** The reviewer will bounce it.

**Use the tool that exists for this — `bin/cp-suite-baseline`, landed today:**

```
bin/cp-suite-baseline --stamp-only          # the environment fingerprint
bin/cp-suite-baseline apps/commonplace      # runs the suite, emits a stamped baseline
```

⇒ **Report the block it prints, not the numbers out of it.**

⚠️ **AND KNOW WHICH CASE YOU ARE: your worktree is the CLEAN case.**

| where | state | expected |
|---|---|---|
| your sandbox (before you build the fixture) | `tmp/test_data` **absent** | **3,502 tests / 0 failures** |
| the host today | `tmp/test_data` **populated** | **3,502 / 1** |

⭐ **Both are falsifiable — measure your own and report the stamp.** ⛔ **If your
clean number differs from 3,502/0, REPORT THE DISCREPANCY rather than matching
it.**

## ⚠️ Why this ticket outranked the rest

**Not the failing test.** Six briefs today quoted `3,494 / 0` as the baseline
rounds must match. **All six came from sandboxed runs.** ⇒ ⛔ **A round that
measured honestly where it stood and reported `3,502/1` would have looked WRONG
against the briefed baseline — and the natural reaction is to suspect the
round.** ⭐ ***A wrong baseline does not produce wrong answers; it produces
distrust of correct ones,*** *and it is invisible because every round that
shares the environment agrees with it.*

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact.**
  ⚠️ **The live store is `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.**
- ⛔ **Do not run `mix format` or `mix precommit`**; use
  `mix format --check-formatted`. ⚠️ *It is ALREADY RED on main from a
  pre-existing file (`CX-y8j6`) — not yours.*
- ⛔ **Do not edit `sol-egress-run.sh`.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES
  rather than satisfying the claim.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to fix this by
  deleting `tmp/test_data`, or to soften the comment instead of the code.

## Review criteria

The failure reproduced before being fixed; the gate demonstrated in both
positions; the fixture-present case green afterwards; the comment made true
rather than weakened; and a baseline reported WITH its environment stamp.
