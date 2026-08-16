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

```
ON MAIN, seed 117514:  5 doctests, 3553 tests, 0 failures, 12 excluded, 1 skipped

⚠️ MAIN IS CURRENTLY GREEN AND THAT IS NOT THE WHOLE STORY:

① STANDING — MUD render defect. CURRENTLY NOT FIRING. NOT FIXED.
   MUD.RoomVisibilityTest / MUD.WebPlayIntegrationTest — ONE mechanism, two tests.
   symptom "(this place has no description)". Mechanism UNMEASURED.
   observed:  3541 → 2 failures · 3546 → 1 · 3548 → 1 · 3553 → 0
   ⛔⛔ THE COUNT IS ARRANGEMENT-DEPENDENT, SO A ZERO IS EXACTLY AS UNINFORMATIVE
       AS A ONE. ADDING TESTS CHANGES THE POPULATION, WHICH CHANGES THE ORDERING.
       AT YOUR POPULATION THIS MAY GO RED. ⛔ THAT IS NOT YOURS AND IT IS NOT NEW.
   ⛔ DO NOT CHANGE THE SEED. ⛔ Do not report that you fixed or caused it.
   RECIPE: docs/measurements/2026-08-16-mud-render-ordering-reproducer.md
   ⛔ A DIFFERENT symptom in those two files IS yours.

② CI-ONLY, UNATTRIBUTED — GitHub CI red since 2026-08-13 in
   Runner.Launcher* / TwoDeploymentPodProofTest. GREEN ON HOST (measured:
   56 tests, 0 failures under apps/commonplace/test/commonplace/runner/).
   ⛔ If one fails ON HOST, that IS yours.

③ GitBridge.ServerTest — teardown check-then-act, THREE distinct tests.
   ⛔ Any OTHER error shape in that module IS yours.
```
⚠️ **The authoritative block is `/home/jes/boss-clod/KNOWN-REDS.md` — it is a
file so it cannot go stale in anyone's context.**

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
