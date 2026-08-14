# CX-q8f1 build brief: two stacked protections, one verdict — split them

> **The work's ticket is CX-q8f1.** Base: **the commit that adds this brief**
> — ⚠️ *not a sha; committing a brief moves HEAD past any sha it records.*

## The state today

`bin/check-pidns-environ-isolation` (landed @`a453493c`) asks one question —
*can this namespace read another live process's `environ`?* — and **two
independent protections can answer it.**

| # | layer | why it blocks | named by |
|---|---|---|---|
| **A** | **user namespace** | `environ` needs `PTRACE_MODE_READ`, which fails across a userns; unprivileged bwrap **always** creates one | ⛔ **NO FLAG AT ALL** |
| **B** | **pid visibility** | with `--unshare-pid` + `--proc /proc` the target **is not in `/proc`** at all | those two flags |

⭐ **Measured on the host 2026-08-14, same uid both sides, `uid_map` identity-mapped
1000→1000 — so this is not a uid mismatch:**

```
no bwrap                          cmdline R  status R  environ R        → FAIL(1)
bwrap --unshare-pid --proc /proc  target ABSENT from procfs             → PASS(0)
bwrap, --unshare-pid DROPPED      cmdline R  status R  environ EACCES   → CANNOT VERIFY(2)
bwrap, --proc /proc DROPPED       cmdline R  status R  environ EACCES   → CANNOT VERIFY(2)
```

⛔⛔ **THE DEFECT: DROPPING EITHER PID FLAG LOSES LAYER B ENTIRELY, AND THE
CHECK CANNOT SAY SO — because layer A is still standing, so the read still
fails and the verdict collapses to `CANNOT VERIFY`.** ⇒ ⭐ *A real degradation
of a real protection is indistinguishable from "the instrument couldn't tell."*

## ⛔ What to build

**Assert the two layers SEPARATELY, so each fails on its own terms.**

- ⭐ **Layer B must be assertable WITHOUT reading `environ` at all** — the
  question is *is the target present in this namespace's `/proc`?* ⚠️ **That
  question has an answer even when layer A is blocking everything.**
- **Layer A keeps its current form** (can the `environ` be read).
- ⛔ **The combined verdict must still exist**, but a loss of B must now read as
  **B FAILED**, never as `CANNOT VERIFY`.

⚠️ **Keep `CANNOT VERIFY` for what it is actually for**: the instrument could not
establish the fact — no target pid, a dead target, a probe that errored. ⛔ **Do
not let it absorb a real finding.**

## ⭐⭐ WHERE EACH ARM RUNS — and this time one of them IS yours

⛔ **You are inside the fence you are testing.** Measured in a previous round:
perturbing a scratch bwrap and dropping either flag made **`/proc/4` VISIBLE**,
but the `environ` read still returned `EACCES` **from the OUTER fence's user
namespace**, so no layer-A red was obtainable from inside.

⇒ ⭐ **THAT IS EXACTLY WHY THE SPLIT IS TESTABLE BY YOU:**

| arm | runs where | evidence |
|---|---|---|
| **B red** — drop `--unshare-pid`; drop `--proc /proc` (separately) → **target becomes VISIBLE** | ✅ **IN YOUR SANDBOX** | `/proc/<pid>` appears |
| **B green** — both flags present → target absent | ✅ **IN YOUR SANDBOX** | |
| **A red** — no user namespace at all | ⛔ **NOT YOURS** — the outer fence dominates | **report as OWED** |

⛔ **DO NOT REPORT A LAYER-A RED YOU COULD NOT HAVE TAKEN.** ⭐ *Name it as owed;
the reviewer runs it on the host.*

## ⛔ Acceptance

1. ⭐⭐ **BOTH B ARMS, CONSTRUCTED, AGAINST A SCRATCH BWRAP INVOCATION YOU
   BUILD** — drop `--unshare-pid` alone, and drop `--proc /proc` alone. **Each
   must produce a B-FAILED verdict, not `CANNOT VERIFY`.** Report verbatim.
2. ⭐ **THE QUIET HALF: with both flags present, B PASSES** — and its corpus is
   proven. ⛔ **A check that finds no target pid also "passes".** ⇒ **Assert you
   HAD a live target before asserting it was invisible.** *The existing script's
   `flock` witness does this; keep that property.*
3. **`CANNOT VERIFY` still reachable for its real cause** — kill the target,
   re-run, and show it returns CANNOT VERIFY rather than PASS. *(Measured
   previously: `rc=2`, not 0. A dead target is also unreadable.)*
4. ⛔ **DO NOT EDIT `/home/jes/boss-clod/sol-egress-run.sh`** — it is the
   mechanism that contains you. ⭐ *A test OF a fence is not an EDIT TO it;
   perturb a SCRATCH invocation.*
5. **Lands as a file with its own count from the tree.**

## ⚠️ If you construct a state, construct ALL of it

⭐ **Earned today and it cost a round's numbers:** a previous brief told a round
to create a fixture consisting of ONE file. That produced a world **that exists
nowhere** and 106 meaningless failures. ⇒ ⛔ **If you build a scratch fence, build
a COMPLETE one, and say exactly what you built.**

## Suites

⛔ **Do NOT quote a remembered number. Run the tool:**

```
bin/cp-suite-baseline --stamp-only          # point-in-time; take it BEFORE
bin/cp-suite-baseline apps/commonplace      # runs, emits a stamped block
```

**Reviewer's own measurement, on the host, for comparison — report YOUR block,
not this one:**

```
  5 doctests, 3505 tests, 0 failures, 12 excluded, 1 skipped  (seed 117514, rc=0)
  sha:        635b8e3c (clean vs HEAD)
  test state: DIRTY — tmp/test_data/root present (written 2026-04-27)
  deps:       repo deps/          cwd: /home/jes/commonplace/apps/commonplace
```

⚠️ **Your sandbox is the CLEAN case and has NO repo `deps/`, so both of those
lines will differ — that is expected, not a discrepancy.** ⭐ **The suite MUTATES
`tmp/test_data` as it runs, so the stamp is a point-in-time reading; the tool
now reports the BEFORE state and flags drift.**
⚠️ **`mix format --check-formatted` is ALREADY RED on main from pre-existing
files (`CX-y8j6`) — not yours; do not fix it.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact.** *Live
  store is `/home/jes/commonplace/workspace/.commonplace/commits/` —
  workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run `mix format` or `mix precommit`.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION** — *its author has been wrong
  about this fence's mechanism twice, in writing, both times with a supporting
  measurement.* ⛔ **REPORT DISCREPANCIES rather than satisfying the claim.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to assert a flag rather
  than a capability. ⚠️ *A flag grep would have been wrong twice here.*

## Review criteria

Layer B failing as B rather than as CANNOT VERIFY, both drops demonstrated in
your sandbox; the quiet half with a proven corpus; CANNOT VERIFY still reachable
for a dead target; layer A's red named as owed rather than reported; and a
baseline block from the tool.
