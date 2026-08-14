# CX-v1zh instance 2 of 3: make the sandbox's credential protection NOISY

> **The work's ticket is CX-v1zh.** Base: **the commit that adds this brief**
> — ⚠️ *not a sha; committing a brief moves HEAD past any sha it records.*
> Verify with `git ls-remote origin main` before cutting.
>
> ⛔⛔ **ONE INSTANCE THIS ROUND, THEN STOP AND REPORT.** Plan ruled this
> explicitly and it has now paid twice. ⛔ **Do not build instance 3 even if it
> looks easy once this one is done.**

## ⭐ The class

**A safety property that holds BY ACCIDENT expires QUIETLY, WITH NO EVENT.**
The protection is real and currently holding, so nothing is broken and nothing
will look broken until it stops — and the change that removes it will be a
change made for a good reason about something else.

## ⛔⛔ READ THIS FIRST — INSTANCE 1 SHIPPED A GATE THAT WAS RED ON CORRECT STATE

**`15384245` was this ticket's instance 1, and it had to be removed the same
day** (`CX-h062`, re-landed @`711f561d`). ⚠️ **Its acceptance was HALF A
CONTROL: red-first by perturbation proved the gauge COULD fire, and nothing
proved it fires ONLY when it should.** ⇒ **It fired on correct state, and
`--no-compile` was circulating as the workaround within the hour.**

⭐⭐ **SO THIS ROUND'S ACCEPTANCE IS A PAIR, AND THE QUIET HALF IS THE ONE THE
ROUND EXISTS FOR.** ⛔ *A check that has only ever been seen green is the
species this ticket is about — and a check that has only ever been seen RED is
the species its own instance 1 shipped.*

## The instance

**THE SANDBOX'S PID NAMESPACE HIDES OTHER PROCESSES' CREDENTIALS — and that was
never why it was added.** `--unshare-pid` went in for `CX-vtaa`, to stop a round
seeing sibling processes. **The credential protection is a side effect.**

⚠️ *Why it is load-bearing:* when `ANTHROPIC_API_KEY` sat in the serve's environ
for ~25h, it was readable by any host process running as `jes` and **not** by a
sandboxed round.

## ⭐⭐ RE-DERIVED AT AUTHORING TIME — THE TICKET NAMES ONE FLAG, THE PROTECTION NEEDS TWO

`sol-egress-run.sh:350`:

```
bwrap --dev-bind / / --unshare-pid --proc /proc "${MASK[@]}" ...
```

⛔ **`--unshare-pid` ALONE DOES NOT PROVIDE THIS PROTECTION.** Measured
2026-08-13 and already recorded: *"`--unshare-pid` alone blocked signalling;
`/proc` stayed host-backed, so 230 host pids remained readable."*
⇒ ⭐ **The protection is `--unshare-pid` AND `--proc /proc` TOGETHER. Removing
EITHER removes it, and the ticket names only one.** ⚠️ **That doubles the number
of ways this can vanish silently, and the second way is the one nobody would
think to look at — `--proc /proc` reads like plumbing, not like a guard.**

⭐ **Your check must therefore assert the CAPABILITY, not the flags.** *A
grep for `--unshare-pid` would pass on a fence with `--proc` removed.*

## ⚠️ AND THE PREMISE THAT DID **NOT** MOVE — stated so you do not re-derive it

Instance 1's premise had changed between filing and briefing. **This one has
not**, re-derived just now:

```
serve pid (BY PORT OWNERSHIP, not by name)   1153034, unchanged since Aug 13 21:26
credential-shaped vars in its environ         0
  corpus control: 26 vars read                (a 0 from an unreadable /proc is
  positive control: PATH and HOME present      indistinguishable from a clean one)
```

⭐⭐ **BUT NOTE WHAT THAT ZERO MEANS FOR THIS ROUND, BECAUSE IT IS A TRAP:
THE PROTECTION IS CURRENTLY PROTECTING NOTHING.** ⇒ **Its VALUE is intermittent
— it only matters while a secret happens to be in some process's environ — while
its REMOVAL is permanent and silent.** ⛔ ***"There is no secret in there right
now" is exactly the condition under which someone removes the flag without
noticing***, and it is true today.
⇒ **So the check must NOT be conditioned on a credential being present.** Assert
the *unreadability of another live process's `environ`*, which holds always.

## ⛔ THE SCOPE PROBLEM — read this before choosing where the check lives

**The fence lives in `/home/jes/boss-clod/sol-egress-run.sh`. You cannot edit
it, and you cannot reach it.** ⛔ **NO ROUND MAY EDIT THE MECHANISM THAT
CONTAINS IT.** ⭐ *A test OF a fence is not an EDIT TO the fence.*

⇒ **DELIVERABLE: a standalone check script in `bin/` in THIS repo, which asserts
the capability from wherever it is run.** ⚠️ **WIRING IT INTO THE FENCE IS NOT
YOUR JOB and must not be attempted** — that is an edit to the container, and the
reviewer does it. **Say in your report where you think it should be invoked from
and why; do not invoke it there.**

⛔ **The red-first arm runs against a SCRATCH COPY of the bwrap invocation that
you construct yourself — never against `sol-egress-run.sh`.**

## ⛔ Acceptance — BOTH halves, and the quiet one is the round

1. ⭐⭐ **A TRUE POSITIVE: with the protection REMOVED in your scratch bwrap
   invocation, the check FAILS.** ⇒ **Do it BOTH ways, because there are two
   ways to lose it: drop `--unshare-pid`, and separately drop `--proc /proc`.**
   ⚠️ **If dropping `--proc /proc` alone does NOT break it, THAT IS A FINDING —
   report it; do not quietly drop the arm.**
2. ⭐⭐ **A TRUE NEGATIVE: with the protection INTACT, the check PASSES — and
   its corpus is proven non-empty.** ⛔ **A check that cannot find any live pid
   to test against also "passes", and that is a false green wearing the true
   one's clothes.** ⇒ **Assert you HAD a target pid before you assert you could
   not read it.**
3. ⭐ **THE CHECK TESTS THE CAPABILITY, NEVER THE HANDLE.** ⛔ **Not "is the
   flag present", not "is the variable empty" — *can it still READ another live
   process's `environ`?*** ⚠️ *An empty variable is exactly what a successful
   fix looks like; so is a failed read for the wrong reason.*
4. **The failure NAMES what it managed to read** — which pid, and that its
   environ was readable. *A check that says "the fence is open" without saying
   what leaked costs the next person the whole investigation.*
5. **The script LANDS AS A FILE and its own run output is reported.**

## ⛔ Do not perturb the live serve

⚠️ **Its module set is the subject of a sibling ticket, and a probe that loads a
module makes the finding true by making it happen.** ⭐ **If you read a live node
at all: `:code.is_loaded/1` ONLY** — never `Code.ensure_loaded?/1` or
`module_info/1`, **both of which AUTO-LOAD.**
⇒ **Reading `/proc/<pid>/environ` from outside a fence is a harmless read and is
the positive control; running the BEAM against the live node is not.**

## ⚠️ The honest limit, from the ticket, and it needs an answer

**This ticket does not make the protections intentional — it makes their removal
NOISY.** ⭐ **The stronger fix is to provide the protection DELIBERATELY as well,
so the accidental source stops being load-bearing.**
⇒ ⛔ **STATE WHETHER THAT IS CHEAP HERE. Do not build both without asking
whether the second makes the first decoration.**

## Suites

Baseline, **falsifiable — measure your own**: core **3,494 / 0 failures /
1 skipped** at **seed 117514**. ⚠️ *This went 3,493 → 3,494 at `711f561d`; it is
not drift.* ⛔ **REPORT THE SEED OF EVERY RUN.** ⛔ **Never pipe a long
`mix test`.** ⚠️ **`mix format --check-formatted` is ALREADY RED on main from a
pre-existing file (`CX-y8j6`) — do not "fix" it, and do not let it read as
yours.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact.**
- ⛔ **Do not run `mix format` or `mix precommit`**; use
  `mix format --check-formatted`.
- ⛔ **Do not edit `sol-egress-run.sh`.**
- ⛔ **If you cannot find this brief, STOP AND SAY SO.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⚠️ *Its author shipped this
  ticket's instance 1 as a gate that was red on correct state.* ⛔ **If the
  measurements or counts do not match the artifact, REPORT THE DISCREPANCY
  rather than satisfying the claim.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to assert the flag
  rather than the capability, because that is the version that always passes.

## Review criteria

Both directions demonstrated against a scratch copy; the check asserting a
capability rather than a flag; a corpus control proving a target pid existed;
the two-flag finding confirmed or refuted; and a stated answer on whether
providing the protection deliberately is cheap.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). ⚠️ Not reachable
from inside the sandbox — **a capability boundary, not a defect.**
