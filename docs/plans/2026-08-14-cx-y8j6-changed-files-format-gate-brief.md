# CX-y8j6 build brief: a format gate that checks ONLY what a commit touches

> **The work's ticket is CX-y8j6.** Base: **the commit that adds this brief**
> — ⚠️ *not a sha; committing a brief moves HEAD past any sha it records.*
>
> ⛔⛔ **THE TICKET'S OWN DESCRIPTION IS WRONG AND THE LABELS SAY SO. It says
> "the one offending file."** ⭐ **Measured: 331 of 957 tracked `.ex`/`.exs`
> files are unformatted — 35%.** ⚠️ *The author reported the head of a truncated
> list as the list; a `head` is a view, not a count.* ⇒ **BUILD AGAINST THIS
> BRIEF, NOT AGAINST THE TICKET BODY.**

## What is actually true

```
tracked .ex/.exs files                         957
unformatted                                    331   (35%)
format step in .github/workflows/ci.yml        NONE
```
*Controls: three random spot-checks all unformatted; a known-clean file returns
FORMATTED; the workflows dir exists and `ci.yml` matches a positive control.*

⭐⭐ **35% IS NOT DRIFT — IT IS A CODEBASE THAT HAS NEVER HAD A FORMAT GATE.**
⇒ **So there is NO REGRESSION TO REPAIR, only A FLOOR TO ESTABLISH.**

## ⛔ The two things you must not do

1. ⛔⛔ **DO NOT RUN A REPO-WIDE `mix format`.** *An unreviewable diff across 957
   files is exactly what the standing rule exists to prevent, and **"the gate
   made me" is not an exemption.***
2. ⛔⛔ **DO NOT ADD A TREE-WIDE `mix format --check-formatted` GATE.** ⚠️ **It
   would be RED ON CORRECT STATE from the moment it lands** — that is `CX-h062`
   at **331×** scale, and this project shipped that defect once already today.

## ⭐ What to build

**A CI check that formats-checks ONLY the files a commit touches.**

⇒ **Green today, catches new drift immediately, never demands a mass reformat,
and the 331 shrinks whenever someone touches one of those files.**

⚠️ **Wire it into `.github/workflows/ci.yml` alongside the existing
`bin/cp-test-guard --min 4100 --apps 5 -- mix test` step** *(that step is the
house style for "a gate with a floor" — read it before designing yours)*.

## ⛔⛔ THE FAILURE MODE THAT WOULD MAKE THIS WORTHLESS — design against it FIRST

**Your file list comes from a diff, and a diff can return EMPTY FOR REASONS THAT
HAVE NOTHING TO DO WITH THE COMMIT:**

- a **shallow clone** (`fetch-depth: 1`) — no merge-base exists
- the wrong base ref on a push vs a pull_request event
- a first commit, a force-push, a re-run on a stale ref

⇒ ⭐⭐ **AN EMPTY FILE LIST MUST NOT BE A SILENT PASS.** ⛔ **A gate that checks
zero files and reports success is a check that cannot fail — the single most
common defect in this repo's history.** ⇒ **It must either REFUSE (non-zero,
saying it could not determine the file list) or report the count it checked so
a zero is VISIBLE.** ⭐ *State which you chose and why.*

⚠️ **AND SAY WHERE THE BASE COMES FROM.** *"Files this commit touches" is
underspecified until you name the two refs being compared.*

## ⛔ Acceptance — all three arms, verbatim

1. ⭐⭐ **GREEN: a commit touching only already-formatted files PASSES.**
2. ⭐⭐ **RED: a commit touching an UNFORMATTED file FAILS, and NAMES THE FILE.**
   *(You have 331 to choose from — pick one and construct the commit.)*
3. ⭐⭐ **GREEN AGAIN after formatting just that one file** — proving the escape
   is per-file and does not require touching the other 330.
4. ⭐ **THE VACUOUS CASE: an empty/underivable file list does NOT silently
   pass.** Demonstrate it.
5. **The check never format-checks the whole tree.** *Show the command it
   actually runs.*
6. **Lands as files with their own counts from the tree.**

## ⚠️ Scope

- **MAY touch**: `.github/workflows/ci.yml`, a new script under `bin/`, and
  **at most ONE `.ex`/`.exs` file** — solely to demonstrate arm 3.
- ⛔ **MUST NOT**: reformat anything else; change `mix format`'s configuration to
  make files pass; add a `.formatter.exs` exclusion list.
  ⭐ *Making the checker agree with unformatted code is the un-failable-gate move.*

## Suites

⛔ **Run `bin/cp-suite-baseline apps/commonplace` and report ITS BLOCK.** ⭐ **Read
the `BEFORE` line — that is what explains the counts.**

**Reviewer's host measurements today, comparison only — report YOUR block:**

```
host DIRTY (tmp/test_data/root present)   3505 tests, 0 failures   seed 117514
host CLEAN (root absent)                  3505 tests, 0 failures   seed 117514
```

⚠️ **Two sandbox runs disagree with each other:** one measured `3505/2`
(`chat_view_compute_supervisor_test.exs` `:172`, `:143`), the next measured
`3505/0`. **Filed as `CX-s9kc`, NOT deterministic, NOT yours.** ⇒ **If you see
those two, report and move on; anything ELSE is yours.**
⚠️ **`mix format --check-formatted` is red on main by construction here — that
is the subject of this ticket, not a failure of your round.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact.** *Live
  store: `/home/jes/commonplace/workspace/.commonplace/commits/` —
  workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run `mix format` (tree-wide) or `mix precommit`.** ⭐ *Formatting
  ONE named file to demonstrate arm 3 is permitted and is the only exception.*
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION** — *and the ticket it
  supersedes was mis-sized by its own author today.* ⛔ **REPORT DISCREPANCIES.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to reformat more than
  the one demonstration file, or to make the gate pass by narrowing what it
  checks.
- ⭐⭐ **REQUIRE THE FAILURE TO BE READABLE:** *when the gate fails, WHAT
  PRINTS?* **Name the files and the count.**

## Review criteria

All three arms plus the vacuous case demonstrated; the base refs stated; the
check provably scoped to changed files; no mass reformat; and an empty file list
that cannot pass silently.
