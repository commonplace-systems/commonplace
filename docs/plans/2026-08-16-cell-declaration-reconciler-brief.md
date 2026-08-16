# The reconciler reads, compares, and REPAIRS NOTHING

> **Ruled by `commonplace-plan`, joining arc §4e, rung ②.** Base: **`cf430433`
> on `main`** — the commit that landed the producer.
>
> ⛔ **THIS ROUND RECONCILES NOTHING. It reads declarations, compares them to
> receipts, and REPORTS disagreement.**
> *One unknown per rung. This rung's unknown is **what "agreement" means**. The
> NEXT rung's unknown is **who wins, and on whose authority** — and that choice
> FORECLOSES THE GENERAL FORM, so it is deferred to a rung that has evidence.*
> ⚠️ **If you find yourself writing a repair, a merge, or a "fix it up" path,
> STOP AND REPORT IT.** *That is this round's near-miss signal.*

## What exists, measured — with both controls run

```
✅ Commonplace.Cell.Declaration           validate/1 · encode/1 · decode/1
✅ Commonplace.Cell.DeclarationProducer   write/3 — writes a declaration to a path
✅ SpawnCeremony.read_public_receipt/2    the FIVE named public fields:
                                          child_uuid name request_digest status public_key
⛔ NOTHING READS A DECLARATION.
```
⚠️ **The one apparent reader is not one: `DeclarationProducer` calls
`Declaration.decode` to VERIFY ITS OWN WRITE BY RE-READ, four lines after
encoding it.** ⛔ ***A call site is not a dataflow.*** *(Same correction the
producer brief carried about `Provisioner.Manifest.read`; it cost a re-measure
there, so it is stated up front here.)*

⚠️ **`reconcil*` ALREADY APPEARS IN 21 lib FILES** — sync agents, `store/merger`,
`tree/merge`, `process/sweep`, `git_bridge/inbound`. **They are a DIFFERENT sense
of the word and none of them is related to cells.** ⛔ **Do not import from them,
do not extend them, and do not assume a shared vocabulary. Grep hits on
"reconcile" in this tree are NOISE for this round.**

## ⛔ What to build

**① A READER + DIVERGENCE REPORT over (declaration, receipt) pairs.**
**② A RED ARM, so the report CAN GO RED rather than merely accumulate.**

### ⭐⭐ THE SHAPE TO COPY IS THE ONE THIS ARC JUST SHIPPED

**`Declaration` and the public reader both bound themselves BY ENUMERATION**
(`@public_receipt_fields`), so a field added tomorrow does not arrive already
exported, and a missing one is refused BY NAME.

⇒ ⭐ **DO THE SAME FOR DIVERGENCES: an enumerated, named set of divergence
kinds.** ⛔ **NOT a generic `{:mismatch, field, a, b}` catch-all** — that is a
shape that silently absorbs a NEW kind of disagreement as though it were an old
one, and nobody decides that it did.

⚠️ **The kinds below are a STARTING SET, not a specification. If the code makes a
different partition natural, TAKE IT AND SAY WHY — but every kind must be NAMED
and every comparison must land in exactly one.**
```
a declaration exists with no receipt
a receipt exists with no declaration
a field present in both DISAGREES        (name the field)
a declaration does not parse
```

### ⛔⛔ THE COMPARISON IS THE UNKNOWN — DO NOT SMUGGLE AN ANSWER INTO IT

**The declaration carries THREE fields (`child_uuid`, `name`, `public_key`); the
receipt exposes FIVE.** ⇒ **The two extra receipt fields (`request_digest`,
`status`) are NOT divergences — a declaration is a BOUNDED PROJECTION, not a
copy.**
⛔ ***A comparison that treats "absent from the declaration" as disagreement
would report every healthy pair as divergent*** — and a report that fires on
correct state is worse than no report. ⭐ **State in the moduledoc WHICH FIELDS
PARTICIPATE IN THE COMPARISON AND WHY, because that sentence IS this rung's
answer to "what does agreement mean".**

### ⛔⛔ A REPORT WITH NO NAMED READER BECOMES THE DENIAL COUNTER

⭐ **plan's addition, and it is the failure mode of every report-only rung:** a
correct report that nothing consumes is **unread, invisible for months, and we
have the scar** — the live denial counter that was 80% its own canary.

⇒ ⛔⛔ **THEREFORE THE RED ARM IS NOT OPTIONAL AND IT IS THE ACCEPTANCE:**
```
① a test asserting NO DIVERGENCE for a healthy fixture pair
② a test in which a divergence IS present and the report NAMES IT
```
⚠️ ***"We will read it later" is what decoration says about itself.***
⭐ **A GATE YOU HAVE NEVER SEEN FAIL IS NOT KNOWN TO WORK, and one that fires on
correct state is worse than none. Demonstrate BOTH directions.**

### ⛔ THE RECONCILER HOLDS NOTHING — SAME GREPS, RUN AND PRINTED

**The producer's privilege property must hold for the reconciler too: it reads
through `read_public_receipt/2` and touches no key material.**
```
the reconciler MUST NOT appear in the `AgentKeys.ensure(` caller list
    (currently SIX call sites: anubis_server · presence/identity ×2 ·
     spawn_ceremony · loom_bridge · telegram_bridge)
the reconciler MUST touch NO SLOT
    (priv_slot/pub_slot refs outside agent_keys.ex: 0)
```
⚠️ **THAT LIST IS A RECORD, NOT A BOUND — a seventh legitimate caller may
appear. What the check catches is THE RECONCILER appearing, not the list
growing.**
⚠️⚠️ **AND A MEASURED WARNING ABOUT THE GREP ITSELF: `grep -rn 'AgentKeys.ensure('`
returns SEVEN hits, and one of them (`telegram_bridge.ex:24`) is a MODULEDOC
MENTION IN BACKTICKS, not a call.** ⇒ ⭐ ***THE CALL FORM NARROWS THE HAYSTACK;
IT DOES NOT REMOVE THE OBLIGATION TO READ THE HIT.*** **Report call sites and
prose mentions separately.**

## ⛔ Acceptance — ARTIFACTS, not assurances

1. **A reconciler module that READS ONLY.** ⛔ No `File.write`, no store write,
   no repair path. *Print the evidence: a grep for write calls in the new module.*
2. **An ENUMERATED, NAMED divergence set.** Show the list.
3. **The moduledoc sentence naming WHICH FIELDS PARTICIPATE and why the two
   receipt-only fields do not.**
4. ⭐⭐ **BOTH RED-ARM DIRECTIONS DEMONSTRATED: green on a healthy pair, and RED
   with the divergence NAMED.** ⛔ *A report that has never gone red is not known
   to work.*
5. ⭐ **BOTH PRIVILEGE GREPS RUN AND PRINTED**, call sites and prose mentions
   counted separately.
6. **Existing tests still pass. PER-FILE counts AND the suite total, plus the
   POPULATION DELTA BY HAND.**

## ⚠️ THE SANDBOX CANNOT SIGN AS THE NODE

**`node_signing_key` is MASKED** ⇒ `Crypto.NodeIdentity.signing_context/0` fails.
⭐ **Use fixture signing contexts via `opts[:signing_context]`** — `spawn_child`
already requires one (`Keyword.fetch!(opts, :signing_context)`). The existing
`spawn_ceremony_test.exs` shows the working pattern; copy it.

## ⛔⛔ SUITES — AND MAIN IS RED BEFORE YOU START

**`bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK.** The stamp is
`[stamp-v2]` and sees `apps/*/test/` AND `bin/`.

```
ON MAIN AT cf430433, seed 117514:
  5 doctests, 3541 tests, 2 FAILURES, 12 excluded, 1 skipped
```

⛔⛔ **THOSE TWO FAILURES ARE NOT YOURS, AND THIS IS THE MOST IMPORTANT FACT IN
THIS BRIEF:**
```
① STANDING RED — the MUD render defect. MAIN IS RED.
   MUD.RoomVisibilityTest / MUD.WebPlayIntegrationTest
   symptom: "(this place has no description)" ×2
   TRIGGER IS THE ARRANGEMENT — not count, not code. The same tests at
   seed 424242 are GREEN. Mechanism UNMEASURED; closing condition SPENT.
   RECIPE: docs/measurements/2026-08-16-mud-render-ordering-reproducer.md
   ⛔ DO NOT CHANGE THE SEED TO MAKE IT PASS. A deterministic red at a known
     seed beats an intermittent red at a random one.
   ⛔ A DIFFERENT symptom in those two files IS yours.
```
⚠️⚠️ **AND THE PART THAT WILL CONFUSE YOU IF NOBODY SAYS IT: ADDING TESTS
CHANGES THE POPULATION, AND THE POPULATION CHANGES THE ARRANGEMENT.** ⇒ **At
YOUR population (3541 + however many you add) THE MUD PAIR MAY BE RED OR GREEN.**
⛔ ***NEITHER IS A SIGNAL ABOUT YOUR WORK.*** **Do not report "I fixed the MUD
red" and do not report "I caused it". Report the count you measured and move on.**

### ⚠️ Also known-nondeterministic, by TEST and MECHANISM — NOT yours
```
GitBridge.ServerTest — "GenServer.stop → no process" teardown check-then-act.
  THREE distinct tests, clean-tree reproduced. ⛔ Any OTHER error shape is YOURS.
Runner.LauncherTest — "pod cannot read a canary injected by its launching BEAM".
  CX-kacr; fails as `canary_result == ""`. Passes in isolation.
  ⛔ A DIFFERENT error shape there is yours.
```

### ⭐⭐ MEASUREMENT DISCIPLINE — EARNED TODAY, AT THE COST OF FIVE INSTRUMENTS

**Before you read ANY count out of a test-output file:**
```
① THE VERDICT LINE ("N tests, M failures") MUST BE PRESENT.
   ⛔ ITS ABSENCE VOIDS EVERY COUNT FROM THAT FILE. Never infer completion.
② A CORPUS CONTROL — prove the thing you are counting COULD have appeared
   in that run. A grep against a run that died returns 0 and looks exactly
   like a confirmed absence.
③ Sequential `mix test` runs COLLIDE ON PORT 4002 — the previous VM holds it
   for seconds after printing its verdict line. A second run launched too
   soon dies at boot with `eaddrinuse` and produces a ~500-byte file whose
   greps all return 0.
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
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES.**
  ⚠️ *Seven audits on this arc found the brief's own premise wrong, including one
  that corrected an audit from fifteen minutes earlier. Check this one too.*
- ⭐ **VERIFY BY RE-READ, not by the write returning.**
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to repair, to add a
  catch-all divergence kind, or to compare the two receipt-only fields.

## Review criteria

A read-only reconciler with an enumerated named divergence set; a moduledoc
sentence defining what agreement means and why the projection is bounded; both
red-arm directions demonstrated (green on healthy, RED with the divergence
named); both privilege greps run and printed with call sites and prose separated;
existing tests green; per-file counts, the suite total, and the population delta
by hand.
