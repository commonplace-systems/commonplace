# The disposition: what each disagreement MEANS — and it still writes nothing

> **Ruled by `commonplace-plan`, joining arc §4f (`9918ea1` in
> `commonplace-plan`).** Base: **the commit that adds this brief** — ⚠️ *not a
> sha. A brief cannot name its own commit; the number would be wrong by
> construction.*
>
> ⛔ **THIS RUNG CLASSIFIES. IT DOES NOT LAUNCH, WAIT, UPDATE, OR REFUSE
> ANYTHING — it says WHICH of those a given comparison IS.**
> *§4f's consequence is that the reconciler's only write is LAUNCHING. Launching
> is the NEXT rung's unknown and is deliberately excluded here. One unknown per
> rung.*

## The ruling this rung implements — quoted, not paraphrased

**§4f: THERE IS NO GENERAL WINNER, BECAUSE THERE IS NO GENERAL DISAGREEMENT.**

| Case | What it is | Disposition |
|---|---|---|
| **Declaration ahead of receipt** — declared, ceremony unfinished | ⭐ **NOT a divergence — a RACE** | **WAIT** |
| **Receipt ahead of declaration** — ceremony done, declaration stale | a lag in INTENT's own record | the declaration **may be updated FROM the receipt** |
| ⛔ **Genuine conflict** — same child, DIFFERENT `public_key` | ⛔⛔ **AN INTEGRITY PROBLEM** | **REFUSE. NAME IT. RECONCILE NOTHING.** |

> **THE AUTHORITY RULE:** the **receipt** is authoritative for anything the
> ceremony minted (`child_uuid`, `public_key`); the **declaration** is
> authoritative for intent (that this cell should exist, its name, its class).
> ⛔ **THE RECONCILER MAY NEVER WRITE AN AUTHORITY-BEARING FIELD, IN EITHER
> DIRECTION.**

⛔⛔ **WHY ROW 3 IS THE WHOLE POINT: A RECONCILER THAT SILENTLY PICKS A WINNER ON
A KEY MISMATCH IS A FORGERY-LAUNDERING PATH.** *If the declaration could win
there, the deliberately UNPRIVILEGED declaration-writer would be able to override
a MINTED key. The producer holds no secret precisely so it cannot do that, and
this rung must not hand it back.*

## What exists, measured

```
✅ Commonplace.Cell.DeclarationReconciler.reconcile/3
     → {:ok, [divergence]} | {:ok, :nothing_to_compare} | {:error, term}
✅ its CLOSED divergence vocabulary, pinned by its own test:
     declaration_missing · receipt_missing · declaration_invalid
     child_uuid_mismatch · name_mismatch · public_key_mismatch
⛔ NOTHING says what any of them MEANS.
```

## ⛔⛔ THE RUNG'S UNKNOWN — AND "IT DOES NOT PARTITION" IS A LEGITIMATE ANSWER

**§4f names THREE dispositions. The reconciler reports SIX divergence kinds plus
`:nothing_to_compare`.** ⇒ ⭐ **THE UNKNOWN IS WHETHER THE VOCABULARY PARTITIONS
CLEANLY ONTO THE RULING.**

**Two map by direct reading, and you should check even these:**
```
receipt_missing       declaration exists, ceremony has not finished  ⇒ row 1, WAIT
declaration_missing   ceremony done, intent's record is stale        ⇒ row 2
public_key_mismatch   same child, different minted key               ⇒ row 3, REFUSE
```
**Three do NOT have an obvious row, and THAT IS THE WORK:**
```
child_uuid_mismatch   the receipt is AUTHORITATIVE for child_uuid, so this is not
                      a lag — but is it row 3, or its own thing?
name_mismatch         the declaration is AUTHORITATIVE for name (intent) — yet the
                      receipt is LOOKED UP BY name, so what does disagreement even
                      denote here?
declaration_invalid   unparseable. Not a race, not a lag, not a key conflict.
```

⇒ ⛔⛔ **PRE-DECLARED AS LEGITIMATE, SO THE ROUND CAN REACH IT WITHOUT IT LOOKING
LIKE FAILURE: *"kind X does not belong to any of the three rows, and here is
why"* IS A RESULT.** ⭐ **REPORT IT AND STOP — do not invent a fourth disposition
to make the table close, and do not force a kind into a row it does not fit.**
⚠️ ***A round that believes only a complete mapping counts will manufacture one.***
⭐ *The same shape as `HOST-ONLY IS THE CORRECT ANSWER` being pre-declared for the
CI check: the difference between a correct answer and a cop-out is entirely
whether the gap is NAMED.*

## ⛔ What to build

**① A DISPOSITION FUNCTION: comparison result → a NAMED disposition.**
**② A RED-FIRST ARM ON ROW 3.**

⭐ **THE DISPOSITION IS A VALUE, NOT AN ACTION.** ⛔ **No launching, no waiting
(no sleeps, no retries, no polling), no updating, no writing of ANY kind.
`:wait` is a WORD THIS RUNG RETURNS, not a thing it does.**

⇒ **Follow the discipline the last two rungs shipped and are now this arc's
house style:** an enumerated closed set of disposition names; a refusal BY NAME
rather than a nil/absence test; and bounding by ENUMERATION so a divergence kind
added tomorrow does not silently acquire a disposition.
⛔ **NO CATCH-ALL / FALLTHROUGH CLAUSE.** ⇒ ***A default disposition is exactly
how an unmapped future kind gets silently treated as an old one*** — and if that
default were ever the permissive one, row 3 leaks. **An unmapped kind must be
refused by name.**

### ⛔⛔ THE RED-FIRST ARM IS ROW 3 AND IT IS THE ACCEPTANCE

```
① a public_key mismatch yields the REFUSE disposition — asserted by NAME
② and it NEVER yields the update-from-receipt or launch-ward disposition,
   asserted explicitly rather than implied by ①
```
⚠️ **② is not redundant. ① proves the right answer appears; ② proves the
DANGEROUS answer cannot.** ⭐ **A gate you have never seen refuse is not known to
refuse, and this is the forgery-laundering path — the one place in this arc where
a wrong default is a security defect rather than a bug.**

## ⛔ Acceptance — ARTIFACTS

1. **The disposition function, with an ENUMERATED closed set of names.** Show the
   list and show there is no catch-all clause.
2. ⭐⭐ **THE MAPPING, STATED — every divergence kind either mapped to a §4f row
   WITH ITS REASON, or reported as NOT BELONGING with its reason.** *Both are
   acceptable outcomes; an unexplained mapping is not.*
3. ⭐⭐ **BOTH RED-ARM DIRECTIONS ON ROW 3**, per above.
4. **A test that an unmapped/unknown divergence kind is REFUSED BY NAME rather
   than defaulted.**
5. ⭐ **PROOF IT WRITES NOTHING: a grep for write calls, sleeps, retries and
   process spawns in the new module.** *Print it.*
6. ⭐ **BOTH PRIVILEGE GREPS, call sites and prose mentions counted SEPARATELY.*
   ⚠️ `grep -rn 'AgentKeys.ensure('` returns SEVEN hits and ONE is a moduledoc
   mention in backticks — **the call form narrows the haystack; it does not
   remove the obligation to read the hit.**
7. **Existing tests still pass. PER-FILE counts AND the suite total, plus the
   POPULATION DELTA BY HAND.**

## ⚠️ THE SANDBOX CANNOT SIGN AS THE NODE

**`node_signing_key` is MASKED** ⇒ `Crypto.NodeIdentity.signing_context/0` fails.
⭐ **Use fixture signing contexts via `opts[:signing_context]`.** The real-ceremony
pattern is in `declaration_reconciler_test.exs` (the test naming a real
`SpawnCeremony` under `:enforce`) and in `spawn_ceremony_test.exs`. Copy it.
⚠️ **A fresh worktree may need `mix deps.get` before anything boots** — measured;
without it the first run dies at boot and every grep on its output returns 0.

## ⛔⛔ SUITES — AND MAIN IS RED BEFORE YOU START

**`bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK.**
```
ON MAIN, seed 117514:  5 doctests, 3548 tests, 1 FAILURE, 12 excluded, 1 skipped
```
⛔ **THAT FAILURE IS NOT YOURS:**
```
① STANDING RED — the MUD render defect. MAIN IS RED.
   MUD.RoomVisibilityTest / MUD.WebPlayIntegrationTest — ONE mechanism, two tests.
   symptom: "(this place has no description)"
   TRIGGER IS THE ARRANGEMENT — not count, not code. Mechanism UNMEASURED.
   RECIPE: docs/measurements/2026-08-16-mud-render-ordering-reproducer.md
   ⛔ DO NOT CHANGE THE SEED TO MAKE IT PASS.
   ⛔ DO NOT READ THE FAILURE COUNT AS A RESULT. Observed 2 failures at population
     3541, 1 at 3546, 1 at 3548. THE COUNT IS ARRANGEMENT-DEPENDENT — at YOUR
     population it may be 1 or 2, BOTH tests remain in scope, and NEITHER NUMBER
     IS A SIGNAL ABOUT YOUR WORK. Do not report that you fixed it or caused it.
   ⛔ A DIFFERENT symptom in those two files IS yours.

② CI-ONLY, UNATTRIBUTED — GitHub CI has been red since 2026-08-13 with failures in
   Runner.Launcher* / TwoDeploymentPodProofTest. GREEN ON HOST (measured: 56 tests,
   0 failures under apps/commonplace/test/commonplace/runner/).
   ⛔ If one of those fails ON HOST, that IS yours.

③ GitBridge.ServerTest — "GenServer.stop → no process" teardown check-then-act.
   THREE distinct tests. ⛔ Any OTHER error shape in that module is YOURS.
```

### ⭐⭐ MEASUREMENT DISCIPLINE — EARNED, NOT DECORATIVE
```
① THE VERDICT LINE ("N tests, M failures") MUST BE PRESENT before you read ANY
   count out of a file. ⛔ ITS ABSENCE VOIDS EVERY COUNT.
② A CONTROL MUST NAME THE WORLD IN WHICH IT READS DIFFERENTLY, or it is
   decoration. ⚠️ `grep -c 'YourModuleName' <test output>` → 0 IS NOT A CONTROL:
   `mix test` does not print module names for PASSING tests, so 0 is what
   SUCCESS looks like AND what NEVER-RAN looks like. The POPULATION DELTA is the
   control, and it only works if you PREDICT IT BEFORE MEASURING.
③ Sequential `mix test` runs COLLIDE ON PORT 4002 — the previous VM holds it for
   seconds after printing its verdict line.
```
⭐ ***A DEAD RUN'S ZERO AND A REAL ZERO ARE THE SAME BYTE.***

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, **NOT** repo-root, **NOT** `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⛔ **Do not select processes by name or argv pattern. Use captured pids.**
- ⭐⭐ **REDIRECT TEST OUTPUT TO A FILE AND GREP THE FILE.**
- ⭐⭐ **SYMBOL SEARCHES USE THE CALL FORM `name(` — then READ THE HIT.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION. REPORT DISCREPANCIES.**
  ⚠️ *S95 corrected this author twice — on a base sha and on an unscoped count.
  Both corrections were right and both are now fixed in the artifact.*
- ⭐ **VERIFY BY RE-READ, not by the write returning.**
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to add a catch-all
  disposition, to invent a fourth row, or to let row 3 fall through to a default.

## Review criteria

A disposition function returning named values and performing no action; an
enumerated closed set with no catch-all and an unmapped kind refused by name; the
full mapping stated with reasons, including any kind reported as NOT belonging to
a §4f row; both row-3 directions demonstrated (refuse appears, update/launch
cannot); the writes-nothing grep printed; both privilege greps with call sites
and prose separated; per-file counts, the suite total, and the population delta
by hand.
