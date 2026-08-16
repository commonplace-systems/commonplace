# The act: launching, and every other answer is a WAIT or a REFUSAL

> **Ruled by `commonplace-plan`, joining arc rung 4b (`eb9cc20` in
> `commonplace-plan`).** Base: **the commit that adds this brief** — ⚠️ *not a
> sha; a brief cannot name its own commit.*
> *Prior rungs, all in the `commonplace` repo: `cf430433` producer ·
> `a052133c` reconciler · `e397021c` re-partition · `9a058eb9` profile (4a).*

## ⛔⛔ THE TWO RULINGS THIS RUNG EXISTS TO SATISFY

> ⛔ **4b MUST CONSUME A PROFILE THROUGH `ExecutorProfile.select/1` AND MUST NOT
> ACCEPT A PROFILE STRUCT FROM ITS CALLER.**
> ⛔ **AND THE NAME MUST RESOLVE WITHIN A CLOSED SET** — *`select/1` alone is not
> sufficient; a lookup that can be pointed outside the governed collection is the
> same hole with an extra step.*

⇒ ⭐⭐⭐ **THE LAW BEHIND BOTH: *A GOVERNED SOURCE IS ONLY GOVERNED IF THE
CONSUMER CANNOT BE HANDED THE PRODUCT DIRECTLY.*** *Third instance in this
codebase — `chain_position` from `opts`, the verification-options allowlist, and
now a profile struct.* ⛔ **If the caller can synthesise a profile, 4a's
repository-ownership is DECORATIVE WHILE LOOKING INTACT.**

## ⛔ And launching is gated on AUTHORITY, which is not a topology fact

⛔ **THE REPORTER MUST NOT ACQUIRE LAUNCH CAPABILITY MERELY BY DETECTING
DIVERGENCE.** *Who may invoke the act is a CAPABILITY CHECK. Being the component
that noticed is not an authorisation.*

⛔⛔ **AND `desired-but-absent` ≠ `crash`: ABSENCE ALONE MUST NOT LAUNCH.**
⇒ **Absence + evidence, or an explicit human `instantiate`.** ⚠️ *A slot that is
empty because nothing was ever started and a slot that is empty because its
occupant died are different worlds with one observation — the absent-vs-not-yet
class, which this arc has now ruled on four times.*

## ⛔ SCOPE — and the in-sandbox-unverifiable part is named UP FRONT

**The reconciler's ONLY write is launching. Every disagreement is a WAIT or a
REFUSAL (§4f).** This rung builds that act.

⚠️⚠️ **BUT ACTUALLY SPAWNING A PROCESS CANNOT BE VERIFIED IN THE SANDBOX.**
⇒ ⭐ **SO THE INSTANTIATOR GOES BEHIND AN INJECTABLE SEAM, AND THE TESTS DRIVE A
FAKE ONE.** *What this rung proves is the GATE and the DECISION — that the right
instruction reaches the seam, and that a wrong one cannot.*
⛔ **DO NOT attempt a real `tmux` session, a real process, or any live contact.**
⭐ **If an acceptance criterion turns out to need one, REPORT IT UNVERIFIED AND
STOP THERE** — that is a result, not a failure.

⚠️ **ONE INSTANTIATOR ONLY.** *`tmux-workerclaude` is the one jes named for
today; `pod` stays a profile VALUE with no implementation, exactly as 4a left
it.*

## ⛔ What to build

**① THE ACT, taking a profile NAME and resolving it through
`ExecutorProfile.select/1` within the closed set.**
**② AN AUTHORITY CHECK that is separate from the detection path.**
**③ AN EVIDENCE REQUIREMENT: absence alone does not launch.**
**④ AN INJECTABLE INSTANTIATOR SEAM, with a fake in tests.**

⛔ **NO CATCH-ALL / FALLTHROUGH** anywhere in resolution, authority, or evidence.
⇒ *A default is how an unmapped future case is silently treated as an old one —
and here the permissive default is launching something nobody authorised.*
**Unmapped ⇒ REFUSED BY NAME.**

### ⛔⛔ RED-FIRST — THREE ARMS, AND EACH SECOND HALF IS THE SECURITY CLAIM

```
① a caller-supplied profile STRUCT is REFUSED BY NAME
   ...and it is NEVER used, even if it is well-formed and valid
② a profile name OUTSIDE the closed set is REFUSED BY NAME
   ...and resolution NEVER reaches the seam
③ ABSENCE ALONE does not launch — refused by name
   ...and the launch-ward outcome CANNOT appear without evidence or an
      explicit instantiate
```
⚠️ **In each pair the FIRST half proves the refusal appears; THE SECOND PROVES
THE PERMISSIVE OUTCOME CANNOT.** ⭐ **Only the second half is a security claim,
and a gate never seen refuse is not known to refuse.**

## ⛔ Acceptance — ARTIFACTS

1. **The act, consuming a profile NAME.** ⛔ **Show there is no parameter, field,
   or option by which a caller can supply a profile struct.**
2. **Closed-set resolution.** Show the set is closed and that resolution cannot
   be pointed outside it.
3. **The authority check, SEPARATE from detection.** *Show that being the
   detector grants nothing.*
4. **The evidence requirement**, with absence-alone refused by name.
5. ⭐⭐ **ALL THREE RED-ARM PAIRS**, both halves each.
6. ⭐ **The instantiator seam, with a FAKE in tests** — and **say plainly that
   the real instantiator is UNVERIFIED in-sandbox.**
7. **Existing tests still pass. PER-FILE counts AND the suite total, plus the
   POPULATION DELTA BY HAND.**

⛔ **BOUNDED ESCAPE HATCH:** if part of this brief does not survive contact with
the code, **SAY SO AND STILL BUILD THE REST.** ⇒ ***Reporting a problem with the
brief is a RESULT; producing no code is not.***

## ⚠️ THE SANDBOX CANNOT SIGN AS THE NODE

**`node_signing_key` is MASKED** ⇒ `Crypto.NodeIdentity.signing_context/0` fails.
⭐ **Use fixture signing contexts via `opts[:signing_context]`** — the pattern is
in `spawn_ceremony_test.exs` and in `declaration_reconciler_test.exs`.
⚠️ **A fresh worktree may need `mix deps.get` before anything boots.**

## ⛔⛔ SUITES

⛔⛔ **THE BLOCK BELOW IS THE OUTPUT OF `bin/cp-brief-known-reds`.** ⚠️ *The
previous brief RETYPED this from its predecessor and invented an entry that is
not in the source. Verify with `bin/cp-brief-known-reds --check <this file>`.*

```
KNOWN REDS ON main (as of 9a058eb9, 2026-08-16 19:17Z) — NOT YOURS. Anything else IS.

① STANDING RED — MUD render defect. ⚠️ FIRING AT 3563; WAS GREEN AT 3553. ENTRY STAYS EITHER WAY.
   MUD.RoomVisibilityTest     — owner's own look on their gated room
   MUD.WebPlayIntegrationTest — citizen spawns in owned home
   Symptom: "(this place has no description)".
   Full suite at seed 117514, CURRENT (9a058eb9): 5 doctests, 3563 tests,
   1 FAILURE (MUD.WebPlayIntegrationTest), 12 excluded, 1 skipped — measured by
   commonplace, population predicted by hand (3553 + 10) BEFORE measuring, matched.
   ⛔⛔ THIS IS NOT FIXED, RESOLVED, OR CLOSED, AND THE ENTRY MUST NOT BE DELETED
      FOR BEING GREEN. Observed sequence:
          population 3541 → 2 failures
          population 3546 → 1
          population 3548 → 1
          population 3553 → 0     ← a green that proves nothing
          population 3563 → 1     ← RED AGAIN, ONE ROUND LATER. The trap fired for
                                    real: had this entry been deleted at 3553 for
                                    being green, S98 would have been told by our own
                                    rule that this failure was ITS.
      THE ENTRY'S CLAIM IS THAT THE COUNT IS ARRANGEMENT-DEPENDENT, SO A ZERO IS
      EXACTLY AS UNINFORMATIVE AS A ONE. Neither a zero nor a nonzero is a signal.
   ⛔ A KNOWN-RED DELETED WHILE GREEN IS A TRAP ARMED FOR WHOEVER ARRIVES NEXT:
      the next round that adds tests and sees it red has no block to check, is
      told by our own rule that unlisted failures are ITS, and hunts a defect
      that is days old.
   ✅ STILL DETERMINISTICALLY REPRODUCIBLE at seed 117514 / population 3541 via
      the recipe (fc7d4bf6). The handle is intact; it is simply not firing here.
   MECHANISM: ARRANGEMENT, not count and not code — the same tests at seed 424242 are GREEN.
   Reproducer + eight dead leads: dba2e59e, d19361f7, deaa6464. Landed red at cf430433
   under commonplace-plan's escape condition; the red is the documented MUD mechanism,
   NOT S94 (per-file S94: 10 tests, 0 failures, boot verified).
   ⛔ DO NOT CHANGE THE SEED TO MAKE IT PASS. That trades a DETERMINISTIC red for an
      INTERMITTENT one, which gets attributed to whoever is unlucky rather than to the
      defect — and it destroys the only handle anyone has on this class.
   ⛔ MECHANISM IS UNMEASURED and the one named closing condition is SPENT (lead ⑧: the
      CX_LOOKDENY name=:look denial is fixture background — RED 117514 and GREEN 424242
      are IDENTICAL, 11 lookdeny / 2 name=:look / signer not in trusted set, both arms).
      No further round on this without a NEW FACT. A measurement is a fact; an idea is not.
   ⛔ A failure with a DIFFERENT symptom in these files IS yours.
   ⛔⛔ IF YOUR ROUND ADDS TESTS, THE POPULATION CHANGES AND SO DOES THE ARRANGEMENT.
      At 3563 + N this pair MAY COME BACK RED OR GREEN, and NEITHER IS A SIGNAL ABOUT
      YOUR WORK. Do not report "I fixed the MUD red" and do not report "I caused it" —
      both are available, both are plausible, and both are false. Report your per-file
      counts and the suite total WITH ITS POPULATION, and say nothing about causation.

② KNOWN TRIGGER — Runner.LauncherTest, "pod cannot read a canary injected by its
   launching BEAM". Environment-sensitive (CX-kacr); a stray tmux socket has triggered it.
   Fails as canary_result == "" where "absent" is expected — an EMPTY probe result, not a
   wrong one. Passes in isolation.
   ⛔ DO NOT "FIX" BY LOOSENING THE ASSERTION. That test refuses to treat "" as "absent",
      which is exactly why it goes red instead of quietly passing.
   ⛔ A DIFFERENT error shape there is yours.

③ STANDING RED IN GITHUB CI ONLY — UNATTRIBUTED. GREEN ON HOST.
   ⚠️ SCOPE IS LOAD-BEARING: these fail in the GitHub Actions runner and PASS ON HOST.
      If you see them fail ON HOST, that is NEW and it IS yours — say so.
   GitHub CI on main: 100 of the last 100 runs failed. Last green 2026-08-13 08:54Z.
   Newest run: 3541 tests, 9 failures, seed 172334 (CI does NOT pin a seed).
     Commonplace.Runner.LauncherTest
       · pod holds its own signing key and not the durable key, proven by effect
       · wrong handle fails while captured handle reaps the process unit
       · live-process channels are unreachable behind containing-directory masks
       · executes by effect with its five-variable constructed environment
       · pod cannot read a canary injected by its launching BEAM      (= ② above)
     Commonplace.Runner.LauncherRecipeTest
       · recipe requires gates placement before launch, with a satisfying control
       · changing only recipe run changes the observed worker effect
       · recipe env names resolve only from the constructed placement allowlist
     Commonplace.Runner.TwoDeploymentPodProofTest
       · two deployments in separate pods: B resolves A's yield, and cannot without it
   ⛔ UNATTRIBUTED — NOBODY HAS EXPLAINED THESE. Recording them is NOT accepting them.
      An unexplained red RECORDED as unexplained cannot mis-blame the next round.
   ⛔ THE MUD PAIR (① above) IS ABSENT FROM CI — 0 occurrences, positive control:
      the same grep hits LauncherTest 9×. CI rolls a fresh arrangement every run and
      has never met ①. ⇒ FIXING ① WILL NOT TURN CI GREEN. They are different defects.
   ⚠️ TODAY'S NINE ARE NOT THE ORIGINAL SET. The first red run (31687219046,
      2026-08-13 09:34Z, seed 198228) was 3456 tests, 4 failures, ALL LauncherTest.
      The other suites did not exist yet. Do not brief a fix against today's list.
```

### ⭐⭐ MEASUREMENT DISCIPLINE
```
① THE VERDICT LINE ("N tests, M failures") MUST BE PRESENT before any count is
   read from a file. ⛔ ITS ABSENCE VOIDS EVERY COUNT.
② A CONTROL MUST NAME THE WORLD IN WHICH IT READS DIFFERENTLY, or it is
   decoration. ⚠️ `grep -c 'YourModule' <test output>` → 0 IS NOT A CONTROL:
   mix test does not print module names for PASSING tests, so 0 is what SUCCESS
   looks like AND what NEVER-RAN looks like. THE POPULATION DELTA is the
   control — and only if PREDICTED BEFORE MEASURING.
③ A TAMPER TEST NEEDS ITS OWN POSITIVE CONTROL: prove you actually broke the
   thing before its rejection means anything. A no-op tamper's rc=0 is the
   purest form of a check that cannot fail.
④ Sequential `mix test` runs COLLIDE ON PORT 4002.
```
⭐ ***A DEAD RUN'S ZERO AND A REAL ZERO ARE THE SAME BYTE.***

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact, NO PROCESS SPAWNING.** *Live store:
  `/home/jes/commonplace/workspace/.commonplace/commits/` — workspace-relative,
  NOT repo-root, NOT `data/`.*
- ⛔ **No tree-wide `mix format` or `mix precommit`.**
- ⛔ **Do not select processes by name or argv pattern. Use captured pids.**
- ⭐⭐ **REDIRECT TEST OUTPUT TO A FILE AND GREP THE FILE.**
- ⭐⭐ **SYMBOL SEARCHES USE THE CALL FORM `name(` — then READ THE HIT.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION. REPORT DISCREPANCIES.**
  ⚠️ *Every round on this arc has found real defects in its brief. **COUNT THE
  LIST**, including any list this brief quotes.*
- ⭐ **VERIFY BY RE-READ, not by the write returning.**
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to accept a profile
  struct "just for tests", to add a fallthrough, or to launch on absence alone.

## Review criteria

An act that resolves a profile NAME through `ExecutorProfile.select/1` within a
closed set and offers no path for a caller-supplied struct; an authority check
separate from detection; an evidence requirement refusing absence-alone by name;
all three red-arm pairs with both halves; an injectable seam with a fake, and the
real instantiator named UNVERIFIED in-sandbox; per-file counts, the suite total,
and the population delta by hand.
