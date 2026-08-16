# Record the eviction anchor's activation when it is added, citing its ratification

> **Ruled by `commonplace-plan` after the ceremony rehearsal.** Base: **the commit
> that adds this brief** — ⚠️ *not a sha.* **Build the worktree from that base.**

## The gap — verified on `origin/main` before briefing

```
eviction_authority_ledger.ex   7 public functions, and NO public activation entrypoint
defp prepare_activation        called only from prepare_registration and prepare_retirement
"ratification"                 0 references in the module
```

⇒ **Activation is created LAZILY, inside the first registration or retirement.**
⇒ ⭐ **So the authority window opens AT FIRST USE, not at ratification, and THE
GRANT'S START IS UNRECORDED.**

⚠️ **And the ceremony's Phase E step 16 asks to *"append an activation event
citing the ratification CID"* — an operation the store does not expose.**

## ⛔⛔ WHY THIS IS WORTH DOING, AND IT IS NOT THAT THE REFUSAL IS MISSING

**The ceremony rehearsal PROVED the refusal exists**: an anchor added to
`eviction_anchors` does NOT bless a tombstone that already existed — verifying
one returns `:eviction_anchor_activation_position_required`.

⇒ ⭐⭐⭐ **THE PROBLEM IS THAT TODAY'S REFUSAL IS *INCIDENTAL* RATHER THAN
*STATED*.** **It falls out of how lazy activation happens to interact with
verification. Nothing declares it, no name carries it, and a change to activation
TIMING would delete it silently — for reasons having nothing to do with
eviction.**
⇒ ⛔ ***INCIDENTAL CORRECTNESS IS INDISTINGUISHABLE FROM ENFORCED CORRECTNESS
UNTIL SOMETHING CHANGES.***

## ⛔ What to build — one change, three properties

**A PUBLIC activation entrypoint that records the activation event AT
ANCHOR-ADD TIME, carrying a reference to the ratification that authorised it.**

1. ⭐ **THE GRANT'S START IS RECORDED** — the ledger can distinguish *"activated
   by ceremony at position N"* from *"first used at position N"*.
2. ⭐⭐ **THE PRE-ACTIVATION REFUSAL BECOMES STATED** — an anchor present in
   config but never activated is refused BY A NAMED CHECK, not by an accident of
   ordering.
3. **Phase E step 16 gets the operation it already asks for.**

⚠️ **The ratification reference is a CID the caller supplies — and that is
CORRECT here, unlike everything `CX-tadf` removed.** ⭐ ***A ratification CID is
an INPUT TO the act (which authorisation is being cited), not EVIDENCE ABOUT the
act (whether it was authorised).*** ⛔ **The store must still assign the POSITION
itself. If you find yourself accepting a caller-supplied position again, stop —
that is the defect `CX-tadf` closed.**

## ⛔ Acceptance — artifacts

1. ⭐⭐ **RED FIRST: show that TODAY an anchor can be added and used with NO
   activation record naming a ratification** — verbatim — **and that after the
   change it cannot.**
2. ⭐⭐⭐ **THE ARM THAT MATTERS, AND IT IS NOT "ACTIVATION IS RECORDED":
   A TOMBSTONE REGISTERED BEFORE THE ANCHOR'S ACTIVATION EVENT IS REFUSED BY A
   NAMED CHECK THAT CITES ACTIVATION** — ⭐ ***so the refusal has an AUTHOR
   instead of an ACCIDENT.*** ⛔ **Distinguish it from today's
   `:eviction_anchor_activation_position_required`, which is the incidental
   form: if the refusal is the same value arising the same way, the round has
   changed nothing.**
3. ⭐⭐ **RE-RUN THE CEREMONY'S ARM 10 AFTERWARDS — IT MUST STILL PASS.**
   ⛔ ***If making the property EXPLICIT changes the OBSERVABLE, then one of the
   two mechanisms was doing something we did not know about*** — **and that is
   the round's most valuable possible finding. Report it rather than
   reconciling it.**
4. ⭐ **AN ACTIVATED ANCHOR CARRIES ITS RATIFICATION REFERENCE, readable back
   from the ledger.** *Verified by re-read, not by the write returning.*
5. ⭐⭐ **THE ORDERING PROPERTY SURVIVES: a tombstone registered after activation
   verifies; one whose position precedes the activation does not.** ⚠️ *This is
   the arm that proves activation is a REAL position in the sequence rather than
   a decorative field.*
6. **The quiet half — the ceremony's twelve arms still pass.** *They are in
   `sla_tombstone_test.exs`; run them and say so.* ⚠️ ***A change that makes
   everything fail passes the red arm and is worse than the gap.***
7. ⭐ **PRINT EVERY ARM AND SHOW THE PAIRS DIFFER.**
8. **PER-FILE counts AND the suite total.**

## ⚠️ WHY A GREEN RUN CANNOT SETTLE THIS ONE

**A rehearsal beat two careful source readings on arm 10 — but that principle has
an edge, and this round sits on the far side of it:**
```
WHAT THE CODE DOES   ⇒ RUN IT.  (arm 10 was settled decisively in one round)
WHAT IS GUARANTEED   ⇒ A RUN CANNOT SETTLE THIS.
```
⇒ ⛔ **A green run shows a property HOLDS. It can never show the property is
ENFORCED rather than EMERGENT, because *incidental correctness is
indistinguishable from enforced correctness in every passing suite.*** ⇒ ⭐ **So
this round is NOT justified by what currently happens — the rehearsal already
proved the refusal works, and that changed nothing about the ruling.** ***The
question was never "does it refuse" but "what would still refuse after an
unrelated change to activation timing."***
⭐ **Reach for a rehearsal by default; reach for the SOURCE when the claim is
about what CANNOT change. And if nothing declares the property, THAT is the
finding.**

## ⚠️ THE SANDBOX CANNOT SIGN

**`node_signing_key` is MASKED** ⇒ `NodeIdentity.signing_context/0` fails and no
node-signed write succeeds. ⭐ **Use fixture signing contexts via
`opts[:signing_context]`.** ⚠️ **`SlaTombstone.verify` accepts ONLY `:store` in
its options and that is deliberate — do NOT widen it to make an arm reachable. If
an arm needs more, that is a finding.**

## Suites

⛔ **`bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK.** **On-main:
`3520 / 0` at seed 117514, `origin/main` `b1d3031f`.** ⚠️ **BUILD FROM THAT BASE.**
⚠️⚠️ **THE DETECTOR'S NUMBER IS NOT A BASELINE. It has read
`58 · 72 · 115 · 118 · 127 · 149 · 152` across populations, main most recently
`72`, and the movement is UNATTRIBUTED.** ⇒ **A different number in your sandbox
is EXPECTED and is not a regression.** ⛔ **If it appears as a FAILURE rather than
`ADVISORY`, that is a finding.**
⚠️ **Known reds by TEST and MECHANISM:** `CX-kx6d` — `GitBridge.ServerTest`
*"filters: __ / nosync / presence … across two cycles"*, teardown check-then-act
(`Process.whereis` then `GenServer.stop` → `no process`); **unticketed** —
`GitBridge.ServerTest` *"push: failure to an unreachable remote … retries"*,
`{:error, :already_registered}` from `WorkspaceFixture.complete_workspace!/2`;
`CX-s9kc` — `chat_view_compute_supervisor_test.exs`. ⛔ **ANY OTHER failure, or
either of those with a DIFFERENT error shape, IS YOURS — say which, verbatim.**
⚠️ **And one seen once: a stray tmux socket triggered the launcher's
channel-isolation test. If that fires, check for incidental sockets before
treating it as yours.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐ **Verify by RE-READ, not by the write returning.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES.**
  ⚠️ *Ten rounds running have produced their best result by correcting their
  brief — including one whose rehearsal refuted two independent source readings
  of the very mechanism this round changes.*
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to let the caller supply
  a position alongside the ratification CID, or to leave the refusal incidental
  while adding the field.
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?**

## Review criteria

A public activation entrypoint recording the event at anchor-add time with a
ratification reference readable back; the pre-activation refusal arising from a
NAMED check rather than incidentally; the store still assigning the position
itself with no caller-supplied position anywhere; the ordering property
demonstrated both ways; the ceremony's twelve arms still green; per-file counts;
and the red arm showing today's unrecorded-activation state before the change.
