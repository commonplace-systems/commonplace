# A disagreement and an inability to tell are DIFFERENT OUTPUTS

> **Ruled by `commonplace-plan`, joining arc §4f as amended (`031ee3f`).**
> Base: **the commit that adds this brief** — ⚠️ *not a sha; a brief cannot name
> its own commit.*
>
> ⭐ **SUPERSEDES the disposition brief's build order.** *That round's ANALYSIS
> stands and is the reason this one exists — it is not repeated work.*

## Why this round exists — a design ruling was falsified, cheaply

**The previous round asked whether §4f's THREE dispositions cover the reconciler's
SIX divergence kinds. They do not, and the round said so instead of forcing a
mapping.** ⭐ **Two independent analyses reached the same partition.** `plan`
amended §4f rather than defending it.

> ⭐⭐⭐ **A DIVERGENCE SAYS *THE DOCUMENTS DISAGREE*. A NON-DIVERGENCE SAYS *WE
> COULD NOT TELL*.** ⇒ ***THOSE ARE A RESULT AND AN INABILITY TO PRODUCE A
> RESULT. THEY MUST BE DIFFERENT OUTPUTS, NOT TWO MEMBERS OF ONE ENUMERATION.***

⚠️ **This is the absent-vs-not-yet class, which this system keeps re-encountering.
A classifier built over the conflated set would ENCODE THE CONFLATION IN THE ONE
COMPONENT WHOSE ENTIRE JOB IS TO DISTINGUISH STATES.**

## ⛔ ① RE-PARTITION FIRST

**`Commonplace.Cell.DeclarationReconciler` reports six kinds in one closed set.
THREE ARE DIVERGENCES; THREE ARE NOT.**

```
DIVERGENCES — the documents genuinely disagree
  receipt_missing       declaration exists, ceremony unfinished
  declaration_missing   ceremony done, intent's record is stale
  public_key_mismatch   same child, different minted key

NOT DIVERGENCES — we could not produce a comparison at all
  child_uuid_mismatch   ⇒ NOT two views of one child: TWO DIFFERENT CHILDREN.
                          Possibly a LOOKUP ERROR — we compared the wrong pair.
  name_mismatch         ⇒ the receipt is looked up BY NAME, so a name
                          disagreement is an INTERNAL INCONSISTENCY IN THE
                          DECLARATION, not a disagreement BETWEEN documents.
  declaration_invalid   ⇒ a PRECONDITION FAILURE. You cannot compare against a
                          document that does not parse.
```

⛔⛔ **CONSTRAINT, AND IT IS THE SAME CONFLATION ONE LEVEL UP: DO NOT COLLAPSE THE
THREE NON-DIVERGENCES INTO A SINGLE `error` BUCKET.** ⭐ **A lookup error, a
malformed declaration and a precondition failure have DIFFERENT CAUSES AND
DIFFERENT REMEDIES. They stay distinguishable BY NAME.**

### ⭐ THE PROPERTY, NOT THE MECHANISM

**Required property:** ⇒ ***A CALLER MUST NOT BE ABLE TO PATTERN-MATCH A
NON-DIVERGENCE AS THOUGH IT WERE A DIVERGENCE LIST, OR VICE VERSA — and the three
non-divergences must remain individually named.***

⭐ **CHOOSE THE SPELLING YOURSELF.** *A distinct result term, a separate return
branch, whatever reads best in this codebase's idiom.* ⛔ **What is NOT
acceptable: the two categories arriving in one list that a caller must inspect
element-by-element to tell apart** — that is the conflation with extra steps.
⚠️ **Say which spelling you chose AND WHY, in one sentence.**

⚠️ **`{:ok, :nothing_to_compare}` (neither side exists) ALREADY EXISTS and is
already a distinct result. Do not disturb it, and say where it sits in the new
partition.**

⚠️ **The existing test `"the divergence vocabulary is closed and enumerated"`
PINS the six-kind list. IT MUST BE REWRITTEN — deliberately and visibly.** ⭐ *A
vocabulary that could be re-partitioned quietly would not have been worth
pinning; the friction is the mechanism working.*

## ⛔ ② THEN CLASSIFY — the disposition over REAL DIVERGENCES ONLY

**§4f, quoted:**

| Case | What it is | Disposition |
|---|---|---|
| Declaration ahead of receipt (`receipt_missing`) | ⭐ **NOT a divergence — a RACE** | **WAIT** |
| Receipt ahead of declaration (`declaration_missing`) | a lag in INTENT's record | may be **updated FROM the receipt** |
| ⛔ `public_key_mismatch` | ⛔⛔ **AN INTEGRITY PROBLEM** | **REFUSE. NAME IT. RECONCILE NOTHING.** |

> **AUTHORITY RULE:** the **receipt** is authoritative for anything the ceremony
> minted (`child_uuid`, `public_key`); the **declaration** is authoritative for
> intent (that this cell should exist, its name, its class).
> ⛔ **THE RECONCILER MAY NEVER WRITE AN AUTHORITY-BEARING FIELD, EITHER WAY.**

⭐ **THE DISPOSITION IS A VALUE, NOT AN ACTION.** ⛔ **No launching, no waiting
(no sleeps, no retries, no polling), no updating, no writes of ANY kind. `:wait`
is a WORD THIS RUNG RETURNS, not a thing it does.** *Launching is the next rung's
unknown.*

⛔ **NO CATCH-ALL / FALLTHROUGH CLAUSE.** ⇒ ***A default disposition is how an
unmapped future kind gets silently treated as an old one*** — and if that default
were the permissive one, row 3 leaks. **An unmapped kind is REFUSED BY NAME.**

### ⛔⛔ ROW 3 IS A SECURITY PROPERTY, NOT A TEST CASE

```
① a public_key mismatch yields the REFUSE disposition — asserted BY NAME
② and it NEVER yields the update-from-receipt or launch-ward disposition,
   asserted EXPLICITLY rather than implied by ①
```
⚠️ **② IS NOT REDUNDANT: ① proves the right answer appears; ② PROVES THE
DANGEROUS ANSWER CANNOT — and only ② is a security claim.**
⛔ **WHY IT MATTERS: A RECONCILER THAT SILENTLY PICKS A WINNER ON A KEY MISMATCH
IS A FORGERY-LAUNDERING PATH.** *If the declaration could win, the deliberately
UNPRIVILEGED declaration-writer would be able to override a MINTED key. The
producer holds no secret precisely so it cannot do that; this rung must not hand
it back.*

## ⛔ Acceptance — ARTIFACTS

1. **The re-partition, with the required property demonstrated:** a caller cannot
   take a non-divergence for a divergence list. **Say which spelling you chose
   and why, in one sentence.**
2. **The three non-divergences INDIVIDUALLY NAMED — no single `error` bucket.**
   Show the names.
3. **The rewritten vocabulary test**, pinning the NEW partition.
4. **The disposition function over real divergences**, enumerated and closed,
   **with no catch-all clause.** Show there is none.
5. **A test that an unknown/unmapped kind is REFUSED BY NAME, not defaulted.**
6. ⭐⭐ **BOTH ROW-3 DIRECTIONS**, per above.
7. ⭐ **PROOF IT WRITES NOTHING**: grep the new/changed code for write calls,
   sleeps, retries, process spawns. **Print it.**
8. ⭐ **BOTH PRIVILEGE GREPS, call sites and prose mentions SEPARATELY.**
   ⚠️ `grep -rn 'AgentKeys.ensure('` returns SEVEN hits, ONE a moduledoc mention
   in backticks — **the call form narrows the haystack; it does not remove the
   obligation to read the hit.**
9. **Existing tests still pass. PER-FILE counts AND the suite total, plus the
   POPULATION DELTA BY HAND.**

⛔⛔ **AND THE ESCAPE HATCH, BOUNDED — because an unbounded one cost the last
round its code:** if some part of this partition does not survive contact with
the code, **SAY SO AND STILL BUILD THE REST.** ⇒ ***Reporting a problem with the
brief is a RESULT; producing no code is not.*** ⚠️ *"Report it and stop" in the
previous brief meant "stop mapping that kind" and was read — correctly, as
written — as "stop the round". That was the author's defect, and this sentence
is its fix.*

## ⚠️ THE SANDBOX CANNOT SIGN AS THE NODE

**`node_signing_key` is MASKED** ⇒ `Crypto.NodeIdentity.signing_context/0` fails.
⭐ **Use fixture signing contexts via `opts[:signing_context]`.** The
real-ceremony pattern is in `declaration_reconciler_test.exs` (the test naming a
real `SpawnCeremony` under `:enforce`) and in `spawn_ceremony_test.exs`.
⚠️ **A fresh worktree may need `mix deps.get` before anything boots** — measured.

## ⛔⛔ SUITES — MAIN IS RED BEFORE YOU START

```
ON MAIN, seed 117514:  5 doctests, 3548 tests, 1 FAILURE, 12 excluded, 1 skipped

① STANDING RED — the MUD render defect. NOT YOURS.
   MUD.RoomVisibilityTest / MUD.WebPlayIntegrationTest — ONE mechanism, two tests.
   symptom "(this place has no description)". Mechanism UNMEASURED.
   RECIPE: docs/measurements/2026-08-16-mud-render-ordering-reproducer.md
   ⛔ DO NOT CHANGE THE SEED. ⛔ DO NOT READ THE FAILURE COUNT AS A RESULT:
     observed 2 failures at population 3541, 1 at 3546, 1 at 3548. THE COUNT IS
     ARRANGEMENT-DEPENDENT — at YOUR population it may be 1 or 2, both tests stay
     in scope, and NEITHER NUMBER IS A SIGNAL ABOUT YOUR WORK. Do not report that
     you fixed it or caused it.
   ⛔ A DIFFERENT symptom in those two files IS yours.

② CI-ONLY, UNATTRIBUTED — GitHub CI red since 2026-08-13 in
   Runner.Launcher* / TwoDeploymentPodProofTest. GREEN ON HOST (measured: 56
   tests, 0 failures under apps/commonplace/test/commonplace/runner/).
   ⛔ If one fails ON HOST, that IS yours.

③ GitBridge.ServerTest — "GenServer.stop → no process" teardown check-then-act.
   THREE distinct tests. ⛔ Any OTHER error shape there is YOURS.
```

### ⭐⭐ MEASUREMENT DISCIPLINE
```
① THE VERDICT LINE ("N tests, M failures") MUST BE PRESENT before you read ANY
   count from a file. ⛔ ITS ABSENCE VOIDS EVERY COUNT.
② A CONTROL MUST NAME THE WORLD IN WHICH IT READS DIFFERENTLY, or it is
   decoration. ⚠️ `grep -c 'YourModule' <test output>` → 0 IS NOT A CONTROL:
   mix test does not print module names for PASSING tests, so 0 is what SUCCESS
   looks like AND what NEVER-RAN looks like. THE POPULATION DELTA is the
   control, and only if you PREDICT IT BEFORE MEASURING.
③ Sequential `mix test` runs COLLIDE ON PORT 4002.
```
⭐ ***A DEAD RUN'S ZERO AND A REAL ZERO ARE THE SAME BYTE.***

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, **NOT** repo-root, **NOT** `data/`.*
- ⛔ **No tree-wide `mix format` or `mix precommit`.**
- ⛔ **Do not select processes by name or argv pattern. Use captured pids.**
- ⭐⭐ **REDIRECT TEST OUTPUT TO A FILE AND GREP THE FILE.**
- ⭐⭐ **SYMBOL SEARCHES USE THE CALL FORM `name(` — then READ THE HIT.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION. REPORT DISCREPANCIES.**
  ⚠️ *The previous round caught three real defects in its brief — an off-by-one
  in a list ("two" above three entries), an omitted result value, and a cited
  commit that lives in the OTHER repo. All three were the author's. **COUNT THE
  LIST** is the cheapest review there is.*
- ⭐ **VERIFY BY RE-READ, not by the write returning.**
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to add a catch-all, to
  merge the three non-divergences, or to let row 3 fall through to a default.

## Review criteria

A re-partition in which a non-divergence cannot be mistaken for a divergence
list, with the three non-divergences individually named and no single error
bucket; the vocabulary test rewritten to pin the new partition; a disposition
function over real divergences only, enumerated, closed, no catch-all, unmapped
refused by name; both row-3 directions demonstrated; the writes-nothing grep
printed; both privilege greps with call sites and prose separated; per-file
counts, the suite total, and the population delta by hand.
