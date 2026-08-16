# Make the ceremony tests USE what they mint — through the gate production uses

> **Ruled by `commonplace-plan` after S88.** Base: **the commit that adds this
> brief** — ⚠️ *not a sha.* **Build the worktree from that base.**

## What S88 exposed, and it was not a prediction

**S88 added a third mint gate: the parent must carry `:delegate`. On its FIRST
CONTACT it refused two fixtures in the identity arc's own tests** —
`class_ratification_test.exs` and `spawn_ceremony_test.exs` — **whose parents
held only `[:read, :write]` while minting children.**

⇒ ⛔ **Those fixtures had been producing certificates THAT COULD NEVER VERIFY.**
⇒ ⭐⭐⭐ **AND NOTHING NOTICED, BECAUSE NEITHER TEST EVER VERIFIED ANYTHING.**

**Measured on the current tree — re-derive these, they are the whole basis:**
```
verify_chain calls in class_ratification_test.exs   0
verify_chain calls in spawn_ceremony_test.exs       0
Commonplace.Trust gate calls in either file          0
   (positive control: spawn_ceremony_test does call Capability — 1 hit,
    so the files were read and the zeros are real)
```

⇒ ⭐⭐ ***A TEST THAT ASSERTS A CONSTRUCTOR SUCCEEDED PROVES THE CONSTRUCTOR RAN,
NOT THAT ITS PRODUCT WORKS.*** **S88 added `:delegate` to those fixtures. That
made them CORRECT. It did not make them able to NOTICE.**

## ⛔⛔ SCOPE — say this precisely, because it touches a ratified slice

**`I5` DID verify end-to-end: two deployments, revocation freezing writes.**
⇒ ✅ ***THE IDENTITY SLICE'S TOP-LEVEL CLAIM STANDS.***
⛔ **What does NOT stand is that `I2`/`I3` can NOTICE A REGRESSION in what they
cover.** ⇒ ⭐ ***THIS IS A COVERAGE CORRECTION, NOT A RETRACTION.***
⚠️ **State that boundary in your report. Do not write anything that reads as
"the identity slice was wrong", and do not write anything that reads as "nothing
was wrong."**

## ⛔ What to build

**Make each ceremony test USE its minted product through the gate that consumes
it IN PRODUCTION**, rather than stopping at `{:ok, cap}`.

**The production consumers, measured in `lib/commonplace/trust.ex`:**
```
Trust.writer_authorized?/6            identity_uuid, pub, cert_cids, target_uuid, cfg, store
Trust.authorized_to_write?/4          %Commit{}, {:doc, uuid}, cfg, store
Trust.reader_authorized?/6
Trust.safe_verb_author_authorized?/6
```
⭐ **`writer_authorized?/6` takes exactly what these tests already hold** — cert
cids, a target uuid, and the store. **Pick the consumer that matches what the
ceremony actually grants; if none fits, say so rather than forcing one.**

**Per ceremony, two arms minimum:**
1. ✅ **The ratified/spawned principal IS authorized** for what the ceremony
   granted — through the gate, not by inspecting the struct.
2. ⛔ **A principal the ceremony did NOT grant is REFUSED** — with its
   precondition asserted adjacent to the act (the cert exists and verifies, the
   target exists, every other axis is non-violating), **so the refusal is
   isolated to the missing grant.**

## ⭐⭐ THE ARM THAT PROVES THIS ROUND WORKED

⛔ **RED FIRST, and it is the whole point: REVERT S88's `:delegate` ADDITION IN
ONE FIXTURE, AND SHOW THE NEW ARM GOES RED.**
⇒ ***Before this round, that same reversion produced a GREEN TEST.*** **After it,
the ceremony test must fail — because it now uses what it mints.**
⚠️ **If the new arm does NOT go red under that reversion, the arm is not
exercising the product and the round has not achieved its purpose. Report that
rather than adjusting the arm.**

## ⛔ Acceptance — artifacts

1. **Both ceremony tests drive their minted capability through a real
   `Commonplace.Trust` gate.**
2. ⭐⭐ **The red-first artifact: `:delegate` reverted in one fixture ⇒ the new
   arm FAILS**, verbatim. *This is the demonstration that the coverage gap is
   closed.*
3. ⭐ **A negative arm per ceremony**, with its precondition adjacent to the act,
   isolating the missing grant from every other cause.
4. ⭐ **The scope sentence: `I5`'s end-to-end claim stands; this corrects what
   `I2`/`I3` can NOTICE.** *In your own words.*
5. **Both files pass as a whole; no existing assertion deleted.** ⛔ *If an
   assertion becomes unreachable because the new arm subsumes it, KEEP IT and
   construct its input directly — see the standing rule below.*
6. **PER-FILE counts AND the suite total from the tool's own block.** ⚠️ **State
   the POPULATION DELTA BY HAND** — the stamp uses `--untracked-files=no` and is
   blind to a new untracked test file.

## ⛔ STANDING RULE, earned in S88 — do not delete an unreachable assertion

**When an EARLIER gate starts catching a case, the LATER gate's test for it
becomes unreachable.** ⇒ ⛔ ***DELETING IT SILENTLY REMOVES THE SECOND LAYER.***
⚠️ **The deletion LOOKS LIKE TIDYING — the assertion is genuinely unreachable and
the diff is genuinely smaller.** ⭐ **Construct and sign the invalid input
directly so BOTH stages keep reporting.**

## ⚠️ THE SANDBOX CANNOT SIGN

**`node_signing_key` is MASKED** ⇒
`Commonplace.Crypto.NodeIdentity.signing_context/0` fails. ⭐ **Use fixture
signing contexts via `opts[:signing_context]`.** ⚠️ **Do not widen a function's
accepted options to make an arm reachable — if an arm needs more, that is a
finding.**

## Suites

⛔ **`bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK.** **On-main
baseline, pasted verbatim from the run — NOT retyped to match your base:**
```
  5 doctests, 3528 tests, 0 failures, 12 excluded, 1 skipped  (seed 117514, rc=0)
  sha:        99acc5d1 (DIRTY — 5 tracked file(s) modified vs HEAD)
  test state: DIRTY — tmp/test_data/root present (written 2026-04-27)
  deps:       repo deps/   cwd: /home/jes/commonplace/apps/commonplace
```
⚠️ **That run's 5 modified files are S88, landed as `f27abab5`. `3528` is the
correct expectation for your base.** ⭐ *A stamp that was retyped is not a
measurement, so it is pasted as measured with its skew explained.*
⚠️⚠️ **THE LEAK DETECTOR'S NUMBER IS NOT A BASELINE — read as
`0 · 58 · 68 · 72 · 115 · 117 · 118 · 122 · 123 · 126 · 127 · 135 · 149 · 152`
across populations, movement UNATTRIBUTED.** ⛔ **If it appears as a FAILURE
rather than `ADVISORY`, that is a finding.**

### ⚠️ Known-nondeterministic, by TEST and MECHANISM — NOT yours

```
GitBridge.ServerTest      GenServer.stop → "no process" in on_exit. MODULE-WIDE:
                          "filters: __ / nosync / presence", "phantom-diff pin",
                          "pause/resume". Reproduced on a clean tree.
DeniedWriteReportingTest  CX-7rjn. Ordinal selection over a nondeterministic write
                          sequence (observed 4 and 5). Fails as
                          `assert landed_count == 4` (left: 5) OR as a
                          `CX-7rjn: ordinal selection picked …` message.
chat_view_compute_supervisor_test.exs    CX-s9kc.
```
⛔ **ANY OTHER failure, or these with a DIFFERENT ERROR SHAPE, IS YOURS.**
⚠️ **AND ONE UNATTRIBUTED OBSERVATION, stated so you can recognise it rather than
inherit a conclusion: a single directory-level run of `test/commonplace/trust/`
once reported `244 tests, 1 failure`. The artifact was destroyed and the test is
UNKNOWN. 21 subsequent runs across three conditions did not reproduce it.** ⛔
**That is NOT an acquittal. If you see a red in that directory, CAPTURE THE FULL
OUTPUT TO A FILE before anything else — a transient gives you one chance at it.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐⭐ **REDIRECT TEST OUTPUT TO A FILE AND GREP THE FILE.** *The summary line is
  the one part of a run that cannot say what broke.*
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES**,
  including in the measured zeros above. ⭐ *The last three rounds each corrected
  this brief's author — on a count, on which stage a refusal happens at, and on
  which files a change would touch.*
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to assert on the
  capability struct instead of driving the gate, which would reproduce the exact
  defect this round exists to close.
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?**

## Review criteria

Both ceremony tests driving their minted capability through a real production
gate; the red-first artifact showing the reverted `:delegate` now fails a
ceremony test; a negative arm per ceremony with its precondition isolating the
missing grant; the scope sentence distinguishing coverage correction from
retraction; no assertion deleted for unreachability; per-file counts, the suite
total, and the population delta by hand.
