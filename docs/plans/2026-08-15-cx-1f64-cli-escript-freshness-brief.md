# CX-1f64 build brief: the CLI escript has no freshness check — and the red fixture is real

> **The work's ticket is CX-1f64.** Base: **the commit that adds this brief**
> — ⚠️ *not a sha; committing a brief moves HEAD past any sha it records.*

## ⛔ Why this is #1, and it is not tidiness

**A stale CLI escript executed an already-fixed defect for four days and cost
nine hours last night.**

```
STALE escript, built 2026-08-11 20:12  →  "Created CX-mzkq"                       rc=0  ← PHANTOM
FRESH escript, rebuilt 2026-08-15      →  "Create failed: {:trust_rejected, …}"   rc=1  ← correct
```

⇒ **The escript BUNDLES its own `Elixir.Commonplace.Bd.Issue.beam`**, and that
copy predated the fix (`84475d91`, *"the discarded-return class is now closed at
six"*) **by two days**. ⭐ **The reviewer spent an evening hunting a defect he had
already closed, preserved in amber.**

⛔⛔ **AND THAT IS THE ARGUMENT FOR THIS TICKET, NOT AN ANECDOTE: A FIX THAT
LANDS AND A FIX THAT IS RUNNING ARE DIFFERENT FACTS, AND NOTHING ON THIS BOX
CHECKS THE SECOND FOR THE CLI.**

**THIRD OCCURRENCE** — and one of them is implicated in the **2026-08-06
corruption incident** (the ticket's own body), which makes this hazard-class,
not annoyance-class:

| when | how stale | cost |
|---|---|---|
| Aug 3 | stale before `CX-hrbn`/`CX-t3xv`/`CX-6scm`/`CX-xxav` | implicated in the corruption incident |
| Aug 11 | 3 days | rebuilt at `99d842ee` — *"CX-1f64 owns the check"* |
| Aug 11→15 | 4 days | **nine hours, three wrong loci, an authorised live-serve probe session** |

## ⭐⭐ THE RED FIXTURE IS PROVIDED — DO NOT MANUFACTURE ONE

```
/home/jes/commonplace-fixtures/commonplace_cli.STALE-2026-08-11.for-CX-1f64
  mtime 2026-08-11 20:12:40   ← LOAD-BEARING, see below
  README-CX-1f64-red-fixture.md alongside it
```

⭐ **This is a NATURALLY OCCURRING stale binary — the one that actually caused
harm.** ⇒ ⛔ **A manufactured stale binary is a WEAKER fixture, because it proves
the check fires on what we BUILT rather than on what actually happens.**

⚠️⚠️ **ITS MTIME IS THE EVIDENCE AND IT IS EASY TO DESTROY.** *It was nearly lost
once already: copied with `cp` instead of `cp -p`, which stamped it with the copy
time.* ⇒ ⛔ **NEVER COPY IT WITHOUT `-p`. VERIFY BEFORE USE:**

```
stat -c %y /home/jes/commonplace-fixtures/commonplace_cli.STALE-2026-08-11.for-CX-1f64
# must read 2026-08-11 20:12:40
```
⛔ **If it does not, STOP AND SAY SO — a red fixture that cannot produce a red is
this ticket's own defect wearing the cure's clothes.**

## ⭐ What to build

**A freshness check for the CLI escript, with the SAME CONTRACT as the existing
one.** ⇒ **`bin/check-mcp-fresh` exists (9,799 bytes, 2026-08-05) and mentions
`commonplace_cli` ZERO times — the gap is verified open, not inferred.**

⚠️ **The ticket names both options and leaves the choice to you: WIDEN
`check-mcp-fresh` to sweep both escripts, OR add a sibling check.** ⇒ ⭐ **READ
IT FIRST and follow its contract — exit `0`/`1`/`2`, module-level comparison,
coverage stated in the output.** *State which you chose and why.*

⛔ **DO NOT invent a new contract.** ⚠️ *A second freshness tool with different
exit semantics is how the next person reads the wrong one's zero.*

## ⛔ Acceptance — the red arm is the ticket

1. ⭐⭐ **RED ON THE REAL FIXTURE**: point the check at the provided stale binary
   and show it **fails, naming what is stale and by how much.** Verbatim.
   ⛔ **This is the arm the ticket exists for — `CX-1f64` HAS NEVER BEEN SEEN TO
   FIRE, and a check never seen red is not known to work.**
2. ⭐⭐ **GREEN ON THE CURRENT ESCRIPT** (`apps/commonplace_cli/commonplace_cli`,
   rebuilt at HEAD `69643ef2`). ⚠️ **A check that is red on correct state is
   worse than no check — that shipped once this week already.**
3. ⭐ **THE THIRD OUTCOME IS NOT A FAILURE**: exit `2` when it **cannot
   determine** freshness (no escript, no `_build`, unreadable). ⛔ **"Cannot tell"
   must not report "fresh"** — *that is the same silent-pass that let a 4-day-old
   binary run.*
4. ⭐ **COVERAGE STATED IN THE OUTPUT** — how many modules it compared. ⚠️ *A
   passing check that prints nothing is the defect wearing silence; and a
   6-module probe once reported "N of 6 differ" as if 6 were the universe.*
5. **Lands as a file with its own count from the tree.**

## ⚠️ The spine, earned the hard way last night

⭐⭐ **ASK WHAT THE ARTIFACT WAS BUILT FROM, NOT WHAT THE SOURCE SAYS.**

**Five measurements were taken during that investigation and ALL FIVE WERE
CORRECT AND USELESS** — the CLI's error branches, `Issue.create`, both remote
store hops, `create_text_doc_checked`, and the CLI's exact execution context
reproduced under `mix run --no-start`. ⇒ ⛔ **Every one measured the SOURCE. The
question was about the BINARY. The discriminator was a FILE MTIME.**
⭐ *That is why it survived five reviews: nothing about a correct measurement
announces that its referent is wrong.*

## Suites

⛔ **Run `bin/cp-suite-baseline apps/commonplace` and report ITS BLOCK; read the
`BEFORE` line.** `host DIRTY 3505/0` · `host CLEAN 3505/0`, seed 117514.
⚠️ **Two sandbox runs disagree — one `3505/2`
(`chat_view_compute_supervisor_test.exs` `:172`, `:143`), the next `3505/0`;
filed `CX-s9kc`, non-deterministic, NOT yours.** ⛔ **Anything else IS yours.**
⚠️ **In a fresh worktree `mix format --check-formatted` exits `rc=1` with
"Unknown dependency :phoenix" — the SAME CODE as "files are not formatted".**
⇒ **Never branch on `rc` alone: a real format failure LISTS FILE PATHS.**
⭐ **A format gate now exists (`bin/cp-format-changed`) and checks only files a
commit touches — so format the files you add.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not modify or move the fixture.** ⭐ *Read it, never write it.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to manufacture a stale
  binary instead of using the real one, or to let "cannot determine" pass as
  "fresh".

## Review criteria

Red demonstrated against the provided real fixture with its mtime verified
first; green on the current escript; a distinct "cannot determine" exit; coverage
stated in the output; and the existing contract followed rather than a new one
invented.
