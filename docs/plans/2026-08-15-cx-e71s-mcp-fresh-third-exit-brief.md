# CX-e71s build brief: `check-mcp-fresh`'s third exit is documented but never taken

> **The work's ticket is CX-e71s.** Base: **the commit that adds this brief**
> — ⚠️ *not a sha; committing a brief moves HEAD past any sha it records.*

## ⚠️ Read the severity honestly — this is NOT urgent, and the brief says so

**Ranked #1 by EXHAUSTION, not by re-valuation.** *"Nothing about it has changed
and I am not claiming it got more important. It is the top of a shorter list."*
⇒ ⛔ **DO NOT inflate it in your report.**

⭐ **Its failure direction is the SAFE one**: it conflates *cannot-determine*
with *stale*, so it errs toward **alarming**, never toward passing.
⇒ ***Loud-wrong, not silent-wrong — the inverse of `CX-q8f1`'s danger despite
sharing its shape.*** ⚠️ **The real cost is slower and still real: A GATE THAT
CRIES WOLF GETS ROUTED AROUND.**

## The defect, verified at source before briefing

```
bin/check-mcp-fresh:48   # exit 0 fresh, exit 1 stale, exit 2 could-not-verify   ← DOCUMENTED
bin/check-mcp-fresh:60   ESCRIPT="$PROJECT_DIR/apps/commonplace_mcp/commonplace_mcp"
bin/check-mcp-fresh:62   if [ ! -f "$ESCRIPT" ]; then
bin/check-mcp-fresh:64     exit 1                                                 ← ACTUAL
env override for ESCRIPT: 0 occurrences
```
⇒ ⛔ **"No escript" is indistinguishable from "stale".** ⭐ **A reader seeing
`rc=1` rebuilds — harmless when stale, but when the artifact is ABSENT they have
"fixed" a condition that was never diagnosed.**

## ⭐⭐ FIX THE TEMPLATE, NOT ONLY THE COPY — this file IS the template

**`bin/check-cli-fresh` was deliberately modelled on this one and got the third
exit RIGHT (`rc=2` for a missing escript AND a missing build dir).** ⇒ ⭐ **THE
CHILD IS CORRECT AND THE PARENT STILL HAS THE DEFECT — and the parent is what
the next copy gets made from.**
⚠️ *The child escaped only because its brief made the third exit an explicit
acceptance arm. Without that clause it would have inherited this silently.*
⇒ ⭐ **Read `bin/check-cli-fresh` first: it is the worked example of the contract
this file documents but does not honour.**

## ⛔ What to build

**Make the cannot-determine paths exit `2`, matching this file's own
documentation and its sibling.** ⚠️ **Sweep for ALL of them, not just the one
named above** — a missing build directory, an unreadable escript, and any other
path where the answer is *I do not know*.

⛔ **You will need a way to point it at a nonexistent escript to test this, and
there is currently NO env override (`0` occurrences).** ⇒ **Adding one is IN
SCOPE and should follow the sibling's naming** (`CLI_CHECK_ESCRIPT` /
`CLI_CHECK_BUILD_DIR`). ⭐ *State what you added.*

## ⛔⛔ THE FIXTURE WEAKNESS — state it, do not paper over it

**`CX-1f64`'s red arm used a NATURALLY OCCURRING stale binary — the one that
actually caused an incident.** ⛔ **NO SUCH FIXTURE EXISTS FOR THE MCP ESCRIPT.**
⇒ ⚠️ **Your stale-arm must be MANUFACTURED, which proves the check fires on
WHAT WE BUILT rather than on WHAT HAPPENS — strictly weaker.**
⭐ **SAY SO IN YOUR REPORT. Do not imply parity with `CX-1f64`'s evidence.**
*A manufactured fixture can encode the author's MODEL of the failure rather than
the failure, and that difference is invisible in a passing run.*

## ⭐ The standard the arms must meet

**From the design doc §15, and it is stronger than "prove it can go red":**
> *demonstrate that the gate catches **a fixture attempting the forbidden edit**,
> not merely that the current corpus contains no violation.*

⇒ ⭐ **For a STATE invariant like this one, the analogue is A FIXTURE IN THE
FORBIDDEN STATE — a genuinely mismatched escript, not a check nudged into
failing.** ⛔ **A check can go red for reasons unrelated to the invariant it
guards** — *measured last night: a red-first arm that was actually a PARSE
FAILURE, which proved nothing.*
⭐⭐ **THE TEST THAT DISTINGUISHES THEM: A RED THAT ENUMERATES THE SPECIFIC
DIVERGENCE CANNOT BE AN INCIDENTAL RED.** ⇒ **Does the failure NAME WHAT
DIFFERS, or only that something does?**

## ⛔ Acceptance — three arms, and they must DISAGREE

1. **STALE** → `rc=1`, **naming which modules differ**, coverage stated.
2. **FRESH** → `rc=0`, coverage stated.
3. ⭐⭐ **CANNOT-DETERMINE → `rc=2`**, for **missing escript AND missing build
   dir separately.** ⛔ *One blind case checked is a coin flip dressed as
   coverage.*
4. ⭐⭐⭐ **ASSERT THE ARMS DISAGREE.** ⛔ ***IF TWO ARMS ARE DEFINED TO DIFFER AND
   THEIR EXIT CODES AGREE, THE ARMS DID NOT RUN.*** ⚠️ *Measured last night: a
   reviewer's three arms silently ran the SAME check via a mistyped env var and
   all returned 0 — indistinguishable from a passing suite. The only tell was
   RED and CANNOT-DETERMINE agreeing.* ⇒ **Print the codes and show they differ.**
5. ⛔ **DO NOT change the documented contract to match the code.** *Making the
   documentation agree with the bug is the un-failable-gate move.*
6. **Lands as a file with its own count from the tree; format what you touch
   (`bin/cp-format-changed` gates changed files only).**

## Suites

⛔ **Run `bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK; read the
`BEFORE` line.** `host DIRTY 3505/0` · `host CLEAN 3505/0`, seed 117514.
⚠️ **Two sandbox runs disagree — one `3505/2`
(`chat_view_compute_supervisor_test.exs` `:172`, `:143`), the next `3505/0`;
filed `CX-s9kc`, non-deterministic, NOT yours.** ⛔ **Anything else IS yours.**
⚠️ **In a fresh worktree `mix format --check-formatted` exits `rc=1` with
"Unknown dependency :phoenix" — the SAME CODE as "files are not formatted".**
⇒ **Never branch on `rc` alone: a real format failure LISTS FILE PATHS.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES
  rather than satisfying it.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to let a manufactured
  fixture read as equivalent to a natural one, or to soften the documented
  contract instead of the code.

## Review criteria

All three exits demonstrated and shown to DIFFER; both blind cases returning `2`;
the stale arm naming what differs; the manufactured-fixture weakness stated
rather than implied; the documented contract unchanged; and any env override
named after the sibling's.
