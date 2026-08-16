# A reproducer for the MUD render defect — ARRANGEMENT, not count, not code

**Date:** 2026-08-16 · **Status:** the MECHANISM IS UNMEASURED, and the ONE named
closing condition is now SPENT (lead ⑧, both arms). Only the TRIGGER
is characterised.

## The observation

Two MUD tests fail together, with **one symptom**:

```
MUD.RoomVisibilityTest     assert out  =~ "Owner's Den"
                           left: "(this place has no description)"
MUD.WebPlayIntegrationTest assert look =~ "arwen's Home"
                           left: "Welcome, arwen.\n\n(this place has no description)\n(this place has no description)"
```

⇒ **A room's description is missing at render time.** ⭐ **Two tests, one symptom
— so this is ONE entry by mechanism, never two by name.**

## What was measured, in order

```
change REVERTED, no added tests        @3535  seed 117514   0 failures
change PRESENT,  no added tests        @3535  seed 117514   0 failures  ← CODE IS CLEAN
change PRESENT,  5 real tests          @3540  seed 117514   2 failures
lib change,      5 TRIVIAL async tests @3540  seed 117514   2 failures  ← NO CULPRIT TEST
lib change,      5 TRIVIAL sync  tests @3540  seed 117514   2 failures  ← not the KIND
lib change,      5 TRIVIAL sync  tests @3540  seed 424242   0 FAILURES  ← NOT COUNT
```

⇒ ⭐⭐⭐ **THE TRIGGER IS THE ARRANGEMENT, NOT THE COUNT AND NOT THE CODE.**
**Five tests that touch nothing reproduce it; the same five at a different seed do
not.** ⛔ ***"Count itself" predicted failure at ANY seed and is refuted by one
counterexample.*** ⇒ **Adding tests matters only because ExUnit RESHUFFLES —
`runner.ex:271 shuffle(config, tests)` — so a changed population produces a
different order.**

⛔ **THERE IS NO POPULATION CEILING.** *An earlier draft of this document said
there was. It was wrong, and the seed arm is what refuted it.*

## ⛔ The attribution needs BOTH halves

```
"pre-existing"  FALSE — they do not fail at 3535
"mine"          FALSE — green with the code change at matched population
```
⇒ ⭐⭐ ***THE DEFECT IS LATENT AND MUD's; THE TRIGGER IS A RESHUFFLE.***
⚠️ **Either half alone is a lie with a true sentence in it, and both were
available and comfortable.**

## The recipe — because an arrangement cannot be merged

**What reaches main is the PROCEDURE.** *(Same law as `CX-0ktk`'s preservation:
the reproducing state cannot be a commit, so the reconstruction must be.)*

```
1. base:  the commit adding the cell-declaration producer work
2. apply: lib/commonplace/cell/declaration.ex
          lib/commonplace/cell/declaration_producer.ex
          lib/commonplace/identity/spawn_ceremony.ex   (read_public_receipt/2)
3. apply: ANY FIVE ADDITIONAL TESTS, async OR sync, touching nothing.
          ⛔ NOT "these particular tests" — five trivial `assert 1 + 1 == 2`
          tests in a throwaway module reproduce it exactly. There is NO CULPRIT
          TEST, and a recipe naming one sends the next investigator hunting
          something that does not exist.
4. run:   bin/cp-suite-baseline apps/commonplace        ⭐ SEED 117514 IS REQUIRED
5. expect: 3540 tests, 2 failures — both "(this place has no description)"

   control A  remove the step-3 tests            ⇒ 3535 tests, 0 failures
   control B  keep them, pass `-- --seed 424242` ⇒ 3540 tests, 0 FAILURES
   ⚠️ the wrapper's banner prints its OWN seed regardless. ExUnit's
      "Running ExUnit with seed:" line in the retained /tmp/cp-suite-baseline.*
      output is the authority.
```
⭐ **Control A distinguishes "the suite fails" from "the suite fails at this
population". Control B distinguishes "count" from "arrangement". Without B, the
count hypothesis survives and is wrong.**

## ⛔ What is NOT established

- **WHY a room's description goes missing.** Unmeasured. The trigger is
  characterised; the mechanism is not.
- **WHICH tests interfere with the MUD pair.** Unknown. We know the arrangement
  matters, not what in it does.
- **That this is `CX-0ktk`.** `RoomVisibilityTest` was that ticket's original
  victim, which makes it a KNOWN ORDERING-SENSITIVE TEST — ⭐ **a reason to
  suspect the CLASS, and NOT evidence about this instance.** ⛔ *`CX-0ktk` closed
  as NOT-REACHABLE-BY-THAT-APPROACH on a measured premise; citing it as the cause
  inherits a conclusion its own ticket declined to draw.* ⚠️ *It is also the most
  tempting explanation available, which is exactly when the rule has to hold.*
- **That the two tests share a root cause beyond the symptom.** One symptom, two
  tests: corroboration, not a proven shared mechanism.

## ⛔⛔ EIGHT DEAD LEADS — each killed by a control, each worth a round

**Read this before investigating. Six of the eight were topically perfect and
would each have bought a round — ⑧ was the one plan AUTHORISED.**

| lead | how it died |
| --- | --- |
| `CommitStore: doc commit index interrupted (state={:dirty,…})` | Present in GREEN runs at the same rate — and the HIGHEST count was in a green run. |
| `EngineLook.run/2` `FunctionClauseError` runtime crash | **19 in every run**, red and green. |
| A test leaks `:trust` config | **NOT elevated in red** — and `GlobalStateLeakDetector` watches `[:data_dir, :trust, :local_write_gate]`, so this is a real negative, not a blind one. |
| The leak-detector formatter is participating | It **observes only** — `Application.fetch_env` and two `handle_cast` clauses. No `put_env`, no restore. It cannot cause a denial. |
| The denied contributor differs between runs | **Green-vs-green is equally disjoint.** And the field is a `commit.id`, not an identity — content-addressed hashes differ by construction. |
| `local node self-trust was not added: … artifact is absent` | **~1380 occurrences in every run.** A complete, observed causal chain that is present when everything passes. |
| The `look` verb's own fallback reason | Same classes in both arms (`:compile, :not_found` · `:compile_error` · `:execution_denied`), including a stable uuid `100ca11b-…` identical in each. |
| **⑧ The `:look` denial's contributor is outside the trusted set** | **MEASURED, both arms, verdict lines present. RED 117514: 11 lookdeny, 2 `name=:look`. GREEN 424242: 11 lookdeny, 2 `name=:look`. IDENTICAL.** ⇒ the denial is fixture background. |

⭐ **Every one died to the same habit: CHECK THE GREEN RUN BEFORE BELIEVING THE
RED ONE.** *One sentence; today it was worth eight rounds.*

### ⛔⛔ LEAD ⑧ CLOSED THE AUTHORISED ROUND — AND ITS ANSWER WAS "NEITHER"

**The within-run observation below was RUN.** At the `EngineModule :look` fallback,
logging that run's own trusted set beside the denied signer produced:

```
CX_LOOKDENY name=:look reason={:untrusted_signer, "b0b22222-…"} trusted_set=["eea11111-…"]
```

⇒ **The signer is NOT in the trusted set — but the same is true, at the same
count, in a run with ZERO failures.** ⭐⭐ ***A field that differs from
expectation in the red arm is not evidence until you have looked at the green
arm.*** ⇒ **Both pre-declared branches assumed the denial belonged to the defect.
It does not. The mechanism remains UNMEASURED.**

### ⛔⛔⛔ AND THE ROUND'S MOST EXPENSIVE FINDING IS ABOUT INSTRUMENTS, NOT MUD

**Reaching that one valid comparison took FOUR broken instruments, each of which
reported a confident, well-formed answer:**

```
1. green run DIED AT BOOT (`port 4002 in use`, prior VM still releasing it).
   541-byte file. `grep -c name=:look` → 0.
2. wait loop had NO liveness arm — could conclude "finished", never "died".
   It polled a corpse for 20 minutes.
3. added an `eaddrinuse` control. It PASSED while the run died another way.
4. `setsid nohup … &` makes `$!` the WRAPPER, which exits instantly.
   The liveness check reported PROCESS GONE on a perfectly healthy run.
5. a stall detector (two `stat`s, 25s apart, equal) fired on a QUIET GAP
   between tests — "slow" and "dead" are the same observation.
```

⇒ ⭐⭐⭐ ***A DEAD RUN'S ZERO AND A REAL ZERO ARE THE SAME BYTE.*** **Step 1's
zero was, verbatim, the branch pre-declared as *"the look denial IS the defect's
signature — the hunt closes on a real, named site."*** ⛔ **The hunt would have
closed on a run that never executed a test.**

⚠️⚠️ **AND THE SUBTLE HALF: PRE-REGISTRATION WAS NEARLY THE VECTOR.** *A
pre-declared branch names a specific expected observation and ratifies its
meaning IN ADVANCE — so a broken instrument that happens to emit that observation
is MORE dangerous, because the interpretation is already agreed and nobody
re-examines it.* ⇒ ***Pre-registration defends against choosing an interpretation
LATE. It does not defend against a FAKE MEASUREMENT ARRIVING ON TIME.***

⇒ ⭐⭐ **THE REQUIRED SHAPE FOR ANY SUITE MEASUREMENT IN THIS DOCUMENT:**
```
① the VERDICT LINE ("N tests, M failures") must be PRESENT — its absence
   VOIDS every count derived from that file. Never infer completion.
② a CORPUS CONTROL — prove the instrument fired at all in THAT run.
③ liveness by the REAL pid (setsid's child), never the wrapper's `$!`.
⛔ A poll that can only detect success is a false-green generator with a timer.
```
*What saved this round was not vigilance: the verdict line never appeared, so the
loop HUNG instead of LYING.*

### ⛔ And two traps specific to this defect

**① THE DENIAL CORPUS IS DOMINATED BY TESTS THAT INTEND DENIALS.** The `reason`
field reads `{:untrusted_signer, "b0b22222-…"}` — stable **fixture** identities,
an identical set in red and green. ⇒ ***Counting denials measures deliberate test
behaviour, not the defect.*** **Instrument the `EngineModule :look` fallback
SPECIFICALLY — one site, not the ~119-per-run class.**

**② THE DISCRIMINATING FIELD IS THE ONE THAT GETS TRUNCATED.** `reason` was cut
from every grep for two hours; extracting it ended the hunt in one read.
⇒ ⛔ ***A control validates the comparison you made, never the one you should
have made.*** *Every control run on the commit-id comparison was correct — about
a meaningless difference.*

## ⛔ What would close this — THE OBVIOUS ROUND IS SPENT

⚠️ **The within-run trusted-set observation WAS the named closing condition. It
was run, both arms, and it came back NEITHER (lead ⑧).** ⇒ ***Do not re-propose
it; it is measured, and the measurement is in this document.***

⇒ **The next round needs a NEW FACT, and a new fact is a MEASUREMENT, NOT AN
IDEA.** ⭐ **The unexamined surface is what makes a room's description READABLE at
render time — the denial path is now excluded by control, so the question is no
longer "who was refused" but "what did the renderer actually read".**

## ⛔ Why the seed must NOT simply be changed

**Changing the seed makes this green and is a RE-ROLL, not a fix:**
1. ⛔ **It trades a DETERMINISTIC red for an INTERMITTENT one** — the next
   reshuffle may be red again, and an intermittent red gets attributed to
   whoever is unlucky rather than to the defect.
2. ⛔ **It destroys the reproducer** — the only handle anyone has had on this
   class.

⇒ ⭐⭐ ***A DETERMINISTIC RED AT A KNOWN SEED IS A BETTER STATE THAN AN
INTERMITTENT RED AT A RANDOM ONE.*** *Reproducible, attributable, and it has a
recipe.*

## Corrections this document has already survived

⚠️ **Recorded because each was believed, stated, and wrong — and the corrections
came from measurement, not from re-reading:**
- *"these six tests"* → **any five**. The five real tests were not special.
- *"a population ceiling between 3535 and 3540"* → **no ceiling**; the seed arm
  refuted it.
- *"sequential-position shift is ruled out, because async tests cannot change
  sync ordering"* → **false.** `runner.ex:271` shuffles ALL tests by seed. That
  claim was reasoning about a scheduler instead of reading it, and it was
  reported as a narrowing that came free.
