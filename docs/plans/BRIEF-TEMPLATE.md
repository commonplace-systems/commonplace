# Brief template — START HERE, do not copy the last brief

> ⛔⛔ **WHY THIS FILE EXISTS: A FIX APPLIED TO AN INSTANCE DOES NOT TRAVEL TO THE
> TEMPLATE.** *Four briefs were written on 2026-08-16, each by copying the
> previous one. Each inherited the TEXT but not the CORRECTIONS: the base-sha
> rule was fixed in one brief and lost in the very next, and a count was given
> without its selector in the same document that demanded selectors of the
> builder.*
> ⇒ ⭐ **THE CORRECTED THING AND THE CORRECTED FORM ARE DIFFERENT OBJECTS.**
> **Start a new brief from THIS file. When a round corrects a brief, fix it
> HERE, not only in the brief that was wrong.**

---

## The header — three things that are wrong by construction if you guess

```
> Ruled by <who>, <arc/section> (`<sha>` IN WHICH REPO).
> Base: the commit that adds this brief — NOT a sha.
```
- ⛔ **BASE IS A RELATION, NEVER A NUMBER.** *A brief cannot name its own commit:
  the sha is minted BY landing the brief, so any sha inside it predates it.*
- ⛔ **EVERY CITED SHA NAMES ITS REPO.** *`commonplace` and `commonplace-plan`
  are different repos; a builder that checks will report the commit missing, and
  a builder that doesn't will trust a citation that does not resolve.*
- ⭐ **State what this round EXCLUDES and why** — one unknown per rung.

## Facts about the code — every one measured, with its selector

- ⭐⭐ **EVERY COUNT CARRIES ITS SELECTOR.** *`grep -rl 'x' apps --include=*.ex |
  grep /lib/` and `apps/commonplace/lib` give different numbers, and neither is
  wrong. A count without its selector is not a disagreement; it is two answers to
  two questions.*
- ⭐⭐ **COUNT THE LIST.** *A brief said "TWO map by direct reading" above three
  entries; another quoted a ruling naming three causes that mapped to two kinds.
  Cheapest review there is, and it applies to QUOTED RULINGS as well as your own
  prose.*
- ⚠️ **A call site is not a dataflow.** *Check whether a "reader" is really
  verifying its own write.*
- ⚠️ **Name collisions:** if a word already means something else in this tree,
  say so and say the hits are noise.

## The escape hatch — bounded, and stated UP FRONT

⛔⛔ **PRE-DECLARE THE LEGITIMATE NEGATIVE OUTCOME, AND BOUND WHAT IT STOPS.**
```
GOOD  "kind X does not belong to any row" IS A RESULT — report it AND STILL
      BUILD the rest. An unmappable case is refused BY NAME in code, not an
      excuse to produce no code.
BAD   "report it and stop."            ← cost a whole round on 2026-08-16
```
⇒ ⭐ **A round that believes only a complete/positive result counts WILL
MANUFACTURE ONE, and a manufactured result is indistinguishable from a real one
afterwards.** *The difference between a correct negative answer and a cop-out is
entirely whether the gap is NAMED.*
⚠️ ***The symptom half of a brief can be right while the remedy half is wrong —
and the remedy is the only part a builder acts on.***

## Acceptance — ARTIFACTS, not assurances

- **Red-first, and in BOTH directions where a gate is involved:** the right
  answer APPEARS, and the dangerous answer CANNOT. ⭐ *Only the second is a
  security claim. A gate never seen refuse is not known to refuse.*
- **No catch-all / fallthrough** on any classifier: *a default is how an unmapped
  future case is silently treated as an old one.* **Unmapped ⇒ refused BY NAME.*
- **Name which acceptance criteria CANNOT be verified in-sandbox** — those get
  reported UNVERIFIED and the round stops there.
- **Privilege greps, when the round touches key material:** call sites and prose
  mentions counted **SEPARATELY**. ⚠️ *`grep -rn 'AgentKeys.ensure('` returns
  seven hits and one is a moduledoc mention in backticks — the call form narrows
  the haystack; it does not remove the obligation to READ THE HIT.*

## Suites — name them with their on-main counts

⛔ **PASTE THE KNOWN-REDS BLOCK FROM `/home/jes/boss-clod/KNOWN-REDS.md`.**
⚠️ **DO NOT RETYPE IT FROM MEMORY OR FROM THE PREVIOUS BRIEF** — it is a file
precisely so it cannot go stale in someone's context.

⭐⭐ **IF THE ROUND ADDS TESTS, THE ARRANGEMENT CAVEAT IS MANDATORY:** *adding
tests changes the population, which changes the ordering, so an arrangement-
dependent red may be red OR green at the builder's population.* ⇒ **NEITHER
NUMBER IS A SIGNAL. Say so explicitly, or the builder will report "I fixed it"
or "I caused it" — both plausible, both false.**

## Measurement discipline — earned, not decorative

```
① THE VERDICT LINE ("N tests, M failures") MUST BE PRESENT before any count is
   read from a file. ⛔ ITS ABSENCE VOIDS EVERY COUNT. Never infer completion.
② A CONTROL MUST NAME THE WORLD IN WHICH IT READS DIFFERENTLY, or it is
   decoration. ⚠️ `grep -c 'YourModule' <test output>` → 0 IS NOT A CONTROL:
   mix test does not print module names for PASSING tests, so 0 is what SUCCESS
   looks like AND what NEVER-RAN looks like. THE POPULATION DELTA is the control
   — and only if PREDICTED BEFORE MEASURING. A prediction recognised afterwards
   is agreement, not a control.
③ A WAIT LOOP NEEDS A LIVENESS ARM. `setsid nohup … &` makes `$!` the WRAPPER,
   which exits instantly; watch the REAL child pid. A poll that can only detect
   success is a false-green generator with a timer.
④ Sequential `mix test` runs COLLIDE ON PORT 4002 — the previous VM holds it for
   seconds after printing its verdict line. A run that dies at boot leaves a
   small file whose greps all return 0.
⑤ A fresh worktree may need `mix deps.get` before anything boots.
```
⭐ ***A DEAD RUN'S ZERO AND A REAL ZERO ARE THE SAME BYTE.***

## Standing discipline — sandbox rounds

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — **workspace-relative**, NOT repo-root, NOT `data/`.*
- ⛔ **No tree-wide `mix format` or `mix precommit`.**
- ⛔ **Do not select processes by name or argv pattern. Use captured pids.**
- ⭐⭐ **REDIRECT TEST OUTPUT TO A FILE AND GREP THE FILE.**
- ⭐⭐ **SYMBOL SEARCHES USE THE CALL FORM `name(` — then READ THE HIT.**
- ⭐ **VERIFY BY RE-READ, not by the write returning.**
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION. REPORT DISCREPANCIES.**
- ⭐ **Report the NEAR-MISS.**
- ⭐⭐ **ASK FOR A MEASUREMENT THE BUILDER REPORTS, NEVER A MECHANISM IT
  EXPLAINS** — and this governs DESCRIPTION too: describe a fixture by WHAT IT
  IS, not WHAT IT DEFEATS. *"signed by an attacker-controlled key"* →
  *"whose `signer_public_key` is a DIFFERENT keypair from the trusted signer"*.
  ⚠️ *A brief written as an attack narrative gets refused at t≈0 with 0 tool
  calls, and that refusal is byte-identical to "nothing to do".*

## After the round — before reading an empty diff as "nothing to do"

⛔⛔ **CHECK THE RUN LOG FOR A CONTENT-FILTER REFUSAL FIRST.** Discriminate by
**POSITION IN EXEC-CALLS AND TOKENS**, never position-in-log (circular):
```
EARLY refusal   t≈0, ~0 tokens, 0 tool calls
LATE  refusal   after tool calls, ~32k tokens paid
DID THE WORK    tokens spent AND a report present — read it
```
⚠️ **Credit exhaustion is a SEPARATE grep and needs the flag lines as its own
positive control, or its zero means nothing.**
⚠️ **A refusal-word grep on the run log counts the BRIEF'S OWN VOCABULARY echoed
back** — if the brief says "refuse" forty times, so does the log.
