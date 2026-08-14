# CX-3zzx build brief: a `bd` guard that knows WHICH REPO it is standing in

> **The work's ticket is CX-3zzx.** Base: **the commit that adds this brief**
> — ⚠️ *not a sha; committing a brief moves HEAD past any sha it records.*

## ⛔⛔ READ THE SCOPE FIRST — YOU ARE BUILDING AN ARTIFACT, NOT INSTALLING ONE

**Installation on the host `PATH` is EXPLICITLY OUT OF SCOPE and will not be
performed by this round.** ⭐ *Say where the guard belongs; do not put it there.*

⚠️ **AND YOU ARE OWED THE HONEST VERSION OF THAT, because a round building
toward an install nobody will perform has done half-useful work and cannot tell
from inside:** the artifact's purpose is to make the decision **concrete and
testable** — a guard whose discrimination is demonstrated is a thing the host
owner can evaluate and install deliberately. ⛔ **A guard that merely exists is
not.** ⇒ **So the DEMONSTRATION is the deliverable, not the file.**

## The finding

```
command -v bd            →  /home/jes/.local/bin/bd   (a 178 MB real binary)
repo bin/ on PATH?       →  NO
```

⇒ ⭐ **This repo's `bin/bd` IS a refusal wrapper and has been since 2026-08-08 —
but it is only consulted by someone who already types `bin/bd`.** ⛔ **THE
GUARDRAIL BUILT TO CATCH THE REFLEX ONLY FIRES IF YOU ALREADY KNOW TO TYPE IT.**
⚠️ *And the stale plugin hooks actively teach the bare form at session start, so
the environment recommends the unprotected path.*

**Verified both positions with `bin/check-bd-archive-reflex`:** inside the Sol
fence → `PASS(0)` (a shadow guard is bound over `bd`); on the host → `FAIL(1)`,
naming the unguarded binary. ⭐ **The sandbox is the protected party; the host is
the exposed one.**

## ⛔⛔ THE OBVIOUS FIX IS RULED OUT, ON MEASUREMENT — do not propose it again

**Putting this repo's `bin/` ahead of `~/.local/bin` is DECLINED by the host
owner and stays declined.**

```
/home/jes/hermes/.beads/dolt      EXISTS — 50 paths modified since 2026-08-01   ← LIVE
/home/jes/commonplace/.beads      issues.jsonl untouched since 2026-06-13       ← FROZEN
```

⇒ ⭐⭐ **`bd` IS FROZEN FOR COMMONPLACE AND LIVE FOR HERMES: ONE COMMAND NAME,
TWO ARCHIVES, OPPOSITE POLICIES.** ⛔ **A host-wide `PATH` change silently
repoints hermes's live ticket tooling and refuses writes to an archive that is
supposed to take them.** ⚠️ *"`bd` is the only name collision" is TRUE and is
exactly the problem — the collision is with a LIVE tracker, not with nothing.*

⭐⭐ **THE CONSTRAINT THAT SURVIVES THE VETO, AND IT IS THE WHOLE TICKET: A
HOST-SIDE GUARD MUST KNOW WHICH REPO IT IS STANDING IN. `PATH` STRUCTURALLY
CANNOT — PATH HAS NO IDEA WHERE YOU ARE.**

## ⭐ What to build

**A guard whose refusal is a function of WHERE IT IS INVOKED, not of what is
first on `PATH`.**

⇒ ⭐⭐ **PRESCRIBING THE PROPERTY, NOT THE MECHANISM — the design is yours:**

1. **It must REFUSE where the archive is frozen** and **PERMIT where it is
   live**, deciding at invocation time.
2. ⭐ **PREFER A DECLARED FACT OVER A HEURISTIC.** *A marker the frozen repo
   states about itself beats sniffing paths, remotes or directory names — a
   heuristic is wrong the first time someone moves or clones a directory.*
   *(This repo has form here: an earlier detector was rewritten to key on a
   declared fact and a 257-false-positive class became a named regression.)*
3. ⛔ **STATE ITS FAILURE DIRECTION AND JUSTIFY IT.** *What does it do in a repo
   it cannot classify?* ⚠️ **Both directions have a real cost: refusing
   everywhere breaks a live tracker; permitting everywhere is today's bug. Pick
   one, say which, and say why.**
4. **The refusal must NAME what it refused and where it decided it was** — *"bd
   is frozen here" is actionable; "refused" is not.*

## ⛔ Acceptance — and the decisive arm must NOT touch a live archive

1. ⭐⭐ **DISCRIMINATION DEMONSTRATED AGAINST FIXTURE DIRECTORIES YOU CREATE:**
   a frozen-marked tree → **REFUSES**; an unmarked/live-shaped tree →
   **PERMITS**. **Both verbatim.**
2. ⛔⛔ **DO NOT INVOKE `bd` AGAINST `/home/jes/hermes` OR ANY REAL ARCHIVE.**
   ⚠️ **Not even a read.** *Measured today: a `bd` READ in a database-less
   directory CREATES `.beads/dolt` and starts Dolt runtime state.* ⇒ ⭐ **Test
   the DECISION, not the delegation** — the guard's classify-this-directory
   step is a pure function and is the part under test.
3. ⭐ **A POSITIVE CONTROL ON THE FIXTURES THEMSELVES**: prove your "frozen"
   fixture is actually detected as frozen and your "live" fixture is actually
   detected as live, **before** trusting either verdict. *Two fixtures that both
   classify the same way would pass a careless discrimination test.*
4. **The failure message names the repo and the reason.**
5. **Lands as a file with its own count from the tree.**

## ⚠️ If you construct a state, construct ALL of it

⭐ *Earned today at the cost of a round's numbers:* a one-file fixture produced a
world **that exists nowhere** and 106 meaningless failures. ⛔ **A "frozen repo"
fixture is not a single marker file if your detector looks at more than one
thing — build what your own design actually reads, and say what you built.**

## Suites

⛔ **Do not quote a remembered number — run `bin/cp-suite-baseline apps/commonplace`
and report ITS BLOCK.** ⭐ **Read the `BEFORE` line: that is what explains the
counts.**

**Reviewer's host measurements today, for comparison only:**

```
host DIRTY (tmp/test_data/root present)   3505 tests, 0 failures   seed 117514
host CLEAN (root absent)                  3505 tests, 0 failures   seed 117514
```

⚠️ **A SANDBOX RUN MEASURED `3505 / 2` — two failures in
`chat_view_compute_supervisor_test.exs` (`:172`, `:143`) that are ATTRIBUTED TO
THE SANDBOX ENVIRONMENT, not to your change and not to test-data state.** ⇒ ⭐
**If you see those two, they are KNOWN and NOT YOURS. Report them; do not chase
or fix them.** ⛔ **Anything else is yours and must be reported.**
⚠️ **`mix format --check-formatted` is ALREADY RED on main from pre-existing
files (`CX-y8j6`) — not yours.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact.** *Live
  store: `/home/jes/commonplace/workspace/.commonplace/commits/` —
  workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **NEVER `bd create|update|close`, in any directory, for any reason.**
- ⛔ **Do not change `PATH` permanently. Do not edit `sol-egress-run.sh`.**
- ⛔ **Do not run `mix format` or `mix precommit`.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES
  rather than satisfying it.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to test by invoking
  `bd` somewhere real, or to propose the `PATH` reorder that is already declined.
- ⭐⭐ **REQUIRE THE FAILURE TO BE READABLE, NOT MERELY DETECTABLE.** *Ask each
  arm: when this fails, WHAT PRINTS?* ⚠️ *A verdict that vanishes while the exit
  code stays right is a check nobody can act on — that shipped today.*

## Review criteria

Discrimination demonstrated on fixtures with a positive control on the fixtures
themselves; no real archive touched; the failure direction chosen and justified;
the refusal naming repo and reason; and installation correctly left undone.
