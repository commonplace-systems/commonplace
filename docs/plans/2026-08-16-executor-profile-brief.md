# The executor profile: what launching MEANS — and it launches nothing

> **Ruled by `commonplace-plan`, joining arc rung 4, split into 4a/4b and
> accepted 2026-08-16.** Base: **the commit that adds this brief** — ⚠️ *not a
> sha; a brief cannot name its own commit.*
> *Prior rungs, all in the `commonplace` repo: `cf430433` producer ·
> `a052133c` reconciler · `e397021c` re-partition.*
>
> ⛔ **THIS RUNG DECLARES AND REFUSES. IT LAUNCHES NOTHING, STARTS NOTHING,
> SPAWNS NOTHING.** *4b is the act. This is its governed source.*

## Why the profile comes BEFORE the act

**The customer, named by jes:** *"a json file that defines the relationships and
a way to instantiate them / maintain them"* — with **TWO instantiators**:
`tmux + workerclaude` **today**, a **pod later**.

⇒ ⭐ **THE DECISION LAYER AND THE ACT ARE SEPARATE.** The reconciler decides
*"this slot should have an incarnation and does not"*. **A PROFILE DEFINES WHAT
LAUNCHING MEANS.** One decision layer, two instantiators.

⇒ ⭐⭐⭐ **AND THE ORDER IS NOT HYGIENE — IT IS THE FIX FOR A DEFECT THAT ALREADY
HAPPENED ONCE: building the act first gives it NO GOVERNED SOURCE TO DRAW FROM,
and the pressure is then to let the declaration supply what the profile does not
yet.** *That is exactly how an `instantiate.recipe` field got into v1 of the
proposal — the act was imagined before its governed source existed, so the
document grew a recipe field to fill the hole.*

## ⛔⛔ THE HARD CONSTRAINT — THIS IS THE ROUND'S POINT

> ⛔ **AN INSTANTIATOR THAT EXECUTES AN ARBITRARY RECIPE READ FROM A DOCUMENT
> TURNS PERMISSION-TO-EDIT INTO PERMISSION-TO-EXECUTE-ARBITRARY-CODE.**

⇒ ⭐⭐ **THE DECLARATION *SELECTS* A GOVERNED PROFILE BY NAME. IT NEVER CARRIES A
RECIPE.**

⛔ **AND THE PROFILE OWNS THE MANDATORY SAFETY BEHAVIOUR** — `oom_score_adj`,
failure-domain isolation, receipts — **SPECIFICALLY SO IT CANNOT BE COPIED INTO
DECLARATIONS AND DRIFT.** *A safety field that can be restated per-declaration
has N owners and N values.*

### ⚠️ A CLAIM TO CHECK, BECAUSE THE HAZARD REAPPEARS ONE LEVEL UP

**If profiles are themselves freely-editable documents, then
permission-to-edit-a-profile IS permission-to-execute — the same defect, moved.**

⇒ **THIS BRIEF'S CLAIM: PROFILES ARE REPOSITORY-OWNED**, in the shape
`Commonplace.Runner.RunRecipe` already uses — *"the six-field, repository-owned
declaration… this module never infers, provisions, starts, or probes anything."*
⛔ **REPORT IT IF THE CODE MAKES THAT WRONG OR IMPOSSIBLE.** ⭐ *Where the
governance boundary sits is the one thing in this rung that a builder must not
decide silently — say where you put it and why.*

## ⛔ What to build

**① A PROFILE DECLARATION TYPE — `validate` / `encode` / `decode`, and it
INFERS, PROVISIONS, STARTS AND PROBES NOTHING.** *Copy `RunRecipe`'s discipline;
it is this arc's house style and the last three rungs all used it.*

**② SELECTION BY NAME — resolving a profile name to a governed profile, with an
unknown name REFUSED BY NAME.**

**③ THE REFUSAL: a declaration that carries a recipe (or any execution-bearing
field) is REFUSED BY NAME and CAN NEVER BE INTERPRETED.**

⛔ **NO CATCH-ALL / FALLTHROUGH** on validation or selection. ⇒ *A default is how
an unknown future field gets silently treated as an old one — and here the
permissive default is arbitrary code execution.*

### ⛔⛔ RED-FIRST, AND THE SECOND ARM IS THE SECURITY CLAIM

```
① a declaration carrying a recipe/command/exec field is REFUSED — by name
② and that field is NEVER INTERPRETED, EXECUTED, OR PASSED THROUGH —
   asserted EXPLICITLY, not implied by ①
```
⚠️ **② IS NOT REDUNDANT AND IT IS THE ONE THAT MATTERS.** ⭐ **① proves the
refusal appears; ② PROVES THE PERMISSIVE OUTCOME CANNOT.** *Same shape as the
forgery-laundering guard in the previous rung, on the execution side.*

## ⛔ Acceptance — ARTIFACTS

1. **The profile type** with `validate`/`encode`/`decode`, declaring and doing
   nothing.
2. **Where the governance boundary sits, STATED** — repository-owned or
   otherwise — **and why.**
3. **Selection by name, with an unknown name refused BY NAME.** No catch-all.
4. ⭐⭐ **BOTH RED-ARM DIRECTIONS** per above.
5. ⭐ **PROOF IT EXECUTES NOTHING:** grep the new module for `System.cmd`,
   `Port.open`, `spawn`, `:os.cmd`, `File.write`, sleeps, retries. **Print it.**
6. **The two named instantiators are EXPRESSIBLE** — `tmux + workerclaude` and a
   pod — **without the decision layer knowing which.** *Show both as profile
   values; ⛔ do NOT implement either.*
7. **Existing tests still pass. PER-FILE counts AND the suite total, plus the
   POPULATION DELTA BY HAND.**

⛔ **BOUNDED ESCAPE HATCH:** if part of this brief does not survive contact with
the code, **SAY SO AND STILL BUILD THE REST.** ⇒ ***Reporting a problem with the
brief is a RESULT; producing no code is not.*** *An earlier brief said "report it
and stop", meaning "stop mapping that case", and it was read — correctly, as
written — as "stop the round". That was the author's defect.*

## ⚠️ THE SANDBOX CANNOT SIGN AS THE NODE

**`node_signing_key` is MASKED** ⇒ `Crypto.NodeIdentity.signing_context/0` fails.
⭐ **Use fixture signing contexts via `opts[:signing_context]`** — the pattern is
in `spawn_ceremony_test.exs` and in `declaration_reconciler_test.exs` (the test
standing up a real `SpawnCeremony` under `:enforce`).
⚠️ **A fresh worktree may need `mix deps.get` before anything boots.**

## ⛔⛔ SUITES — AND WHAT MAIN'S GREEN DOES NOT MEAN

⛔⛔ **THE BLOCK BELOW IS THE OUTPUT OF `bin/cp-brief-known-reds`, WHICH READS
`/home/jes/boss-clod/KNOWN-REDS.md`.** ⚠️ *An earlier revision of this brief
RETYPED it from the previous brief: it INVENTED a `GitBridge.ServerTest` entry
that is not in the file and OMITTED three that are. The builder caught it.*
⇒ ⭐ **Verify with `bin/cp-brief-known-reds --check <this file>`.**

```
KNOWN REDS ON main (as of e397021c, 2026-08-16 18:08Z) — NOT YOURS. Anything else IS.

① STANDING — MUD render defect. ⚠️ CURRENTLY NOT FIRING. THE ENTRY STAYS.
   MUD.RoomVisibilityTest     — owner's own look on their gated room
   MUD.WebPlayIntegrationTest — citizen spawns in owned home
   Symptom: "(this place has no description)".
   Full suite at seed 117514, CURRENT (e397021c): 5 doctests, 3553 tests,
   0 FAILURES, 12 excluded, 1 skipped — measured by commonplace, population
   predicted by hand (3548 + 5) BEFORE measuring and matched exactly.
   ⛔⛔ THIS IS NOT FIXED, RESOLVED, OR CLOSED, AND THE ENTRY MUST NOT BE DELETED
      FOR BEING GREEN. Observed sequence:
          population 3541 → 2 failures
          population 3546 → 1
          population 3548 → 1
          population 3553 → 0     ← a green that proves nothing
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
      At 3553 + N this pair MAY COME BACK RED OR GREEN, and NEITHER IS A SIGNAL ABOUT
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
   read from a file. ⛔ ITS ABSENCE VOIDS EVERY COUNT. Never infer completion.
② A CONTROL MUST NAME THE WORLD IN WHICH IT READS DIFFERENTLY, or it is
   decoration. ⚠️ `grep -c 'YourModule' <test output>` → 0 IS NOT A CONTROL:
   mix test does not print module names for PASSING tests, so 0 is what SUCCESS
   looks like AND what NEVER-RAN looks like. THE POPULATION DELTA is the
   control — and only if PREDICTED BEFORE MEASURING.
③ Sequential `mix test` runs COLLIDE ON PORT 4002; a run that dies at boot
   leaves a small file whose greps all return 0.
```
⭐ ***A DEAD RUN'S ZERO AND A REAL ZERO ARE THE SAME BYTE.***

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — **workspace-relative**, NOT repo-root, NOT `data/`.*
- ⛔ **No tree-wide `mix format` or `mix precommit`.**
- ⛔ **Do not select processes by name or argv pattern. Use captured pids.**
- ⭐⭐ **REDIRECT TEST OUTPUT TO A FILE AND GREP THE FILE.**
- ⭐⭐ **SYMBOL SEARCHES USE THE CALL FORM `name(` — then READ THE HIT.**
  ⚠️ *`grep -rn 'AgentKeys.ensure('` returns seven hits and one is a moduledoc
  mention in backticks. Count call sites and prose SEPARATELY.*
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION. REPORT DISCREPANCIES.**
  ⚠️ *The last three rounds each found real defects in their brief — a list that
  said "two" above three entries, a cited commit that lives in the OTHER repo, an
  omitted result value, and a ruling whose enumeration was off by one in each
  direction.* ⭐ **COUNT THE LIST — including any list this brief QUOTES.**
- ⭐ **VERIFY BY RE-READ, not by the write returning.**
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to let the declaration
  carry an execution field "just for now", or to make the profile editable.

## Review criteria

A profile type that declares and does nothing; the governance boundary stated
with its reason; selection by name with unknown names refused by name and no
catch-all; both red-arm directions demonstrated, the second showing the
execution-bearing field can never be interpreted; the executes-nothing grep
printed; both named instantiators expressible without either being implemented;
per-file counts, the suite total, and the population delta by hand.
