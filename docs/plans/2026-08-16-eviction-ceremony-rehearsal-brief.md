# Rehearse the eviction-ceremony acceptance matrix against the landed mechanism

> **Design: `commonplace-plan:docs/plans/2026-08-15-eviction-anchor-ceremony.md`
> §5. This brief is self-contained.** Base: **the commit that adds this brief**
> — ⚠️ *not a sha.* **Build the worktree from that base.**

## What this round is, and what it is NOT

**The mechanism is landed** (`17ce0ebc`): an eviction-authority ledger the store
assigns positions from, an anchor set separate from `trusted_identities`,
retirement by ledger position, and verification that accepts **no evidence from
its caller** (only `:store` survives its options).

⇒ ⭐⭐ **THIS ROUND PRODUCES THE EVIDENCE RECORD.** *The ceremony puts
verification BEFORE ratification, so the record is the thing a human ratifies
against.* ⇒ ***The ceremony is not idle — it is missing an artifact, and this
round is that artifact.***

⛔⛔ **AND IT REHEARSES WITH A THROWAWAY ANCHOR IN ISOLATED STATE. NOTHING TOUCHES
THE LIVE STORE OR THE LIVE TRUST CONFIG.** ⇒ **That separates *"does the
mechanism satisfy all twelve arms?"* from the CUSTODY ACT of minting a real
anchor** — **so an arm that fails is found NOW, not mid-ceremony with a human
waiting on a broken preflight.**

⛔ **NOT IN THIS ROUND, AND NOT A BUILD LANE AT ALL: custody, ratification, and
live activation.** *If your work seems to require any of them, STOP AND REPORT.*

## ⛔ The twelve arms — rehearse each, print each

1. **An active anchored signer registers a tombstone successfully.**
2. ⛔ **An entirely untrusted SELF-NAMED signer is refused** — *no capability
   proof, absent from every trust set.*
3. ⛔ **A TRUSTED ORDINARY WRITER THAT IS NOT AN ANCHOR is refused.**
   ⭐⭐ **DISTINCT FIXTURE FROM ARM 2. The refusal reason may match; THE SETUP AND
   THE ATTEMPTED AUTHORITY MUST DIFFER.** ⚠️ *Arm 2 proves an untrusted signer is
   refused; arm 3 proves that being trusted FOR COMMITS does not confer eviction.
   One fixture cannot prove both — it would leave the other's alternative
   explanation standing.*
4. ⭐⭐ **ANCHOR MEMBERSHIP ALONE DOES NOT CHANGE ORDINARY-WRITE AUTHORIZATION.**
   ⛔ **Prove it by comparing the IDENTICAL COMMIT BEFORE AND AFTER anchor
   addition — NOT by asserting rejection.** ⚠️ **The live default is
   `accept_unsigned: true`, so an absolute-rejection assertion is UNPROVABLE in
   that posture and would pass or fail for the wrong reason.**
5. ⛔ **Absent anchor configuration STILL REFUSES** — `CX-fmzk`'s behaviour must
   survive.
6. **An active tombstone receives a STORE-CREATED ledger position.**
7. **That tombstone still verifies AFTER RETIREMENT AND STORE RESTART**, with
   the caller never having supplied a position. ⭐ *The restart is the half that
   proves the position is durable rather than in-memory.*
8. ⛔ **A tombstone whose position is at-or-after the retirement point is
   REFUSED — through the PRODUCTION ENTRYPOINT**, not a test seam. ⭐ *Since
   `CX-tadf` there is no caller-supplied position, so this arm tests that the
   store's own ordering is what refuses.*
9. ⭐⭐ **TOMBSTONES COVERING UNRELATED DOCUMENT HISTORIES ORDER CORRECTLY.**
   ⛔ **The proof must NOT arrange all covered commits into one chain.** ⚠️ *A
   single synthetic chain proves the one case where the assumption was manually
   made true — the previous rehearsal did exactly that.* **NOTHING HAS EVER
   EXERCISED THIS.**
10. ⭐⭐ ⛔ **PRE-ACTIVATION REGISTRATIONS ARE REFUSED, NOT RETROACTIVELY
    TRUSTED.** **NOTHING HAS EVER EXERCISED THIS EITHER.**
11. **Revocation and retirement remain DISTINGUISHABLE in the refusal.**
12. ⛔⛔ **NO TEST TOMBSTONE OR THROWAWAY ANCHOR IS PERSISTED IN THE LIVE STORE OR
    THE LIVE CONSTITUTIONAL SET.** ⭐ ***Rotation rehearses in isolated state; the
    instrument must not change the population it measures.*** **Demonstrate the
    isolation, do not assert it.**

⭐ **PRINT EVERY ARM'S OUTCOME AND SHOW THE PAIRS DIFFER.** ⛔ ***If two arms
defined to differ produce the same value, the arms did not run.***
⚠️ **Arms 9 and 10 are the ones the ledger newly makes testable and that nothing
has exercised — if either cannot be rehearsed against the landed mechanism, THAT
IS THE ROUND'S MOST VALUABLE FINDING. Say so and stop rather than approximating.**

## ⚠️ THE SANDBOX CANNOT SIGN

**`node_signing_key` is MASKED** ⇒ `NodeIdentity.signing_context/0` fails and no
node-signed write succeeds. ⭐ **Use fixture signing contexts via the injectable
`opts[:signing_context]` seam** — `sla_tombstone_test.exs` is the worked example.
⚠️ **Note that `SlaTombstone.verify` now takes ONLY `:store` in its options —
that is deliberate and is `CX-tadf`. Do not reintroduce an evidence seam to make
an arm easier; if an arm cannot be reached without one, that is a finding.**

## Suites

⛔ **`bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK.** **On-main:
`3520 / 0` at seed 117514, `origin/main` `17ce0ebc`.** ⚠️ **BUILD FROM THAT BASE.**
⭐ **PER-FILE counts AND the suite total** — *a stable total concealed a deleted
test last night, offset by an added one.*
⚠️ **The suite prints `GLOBAL STATE LEAK DETECTOR: <n> divergence(s) — ADVISORY,
not a failure` and a line saying its positive control did not run. EXPECTED.**
⭐ **`<n>` has read 152, 149, 127, 118, 115 and 58 across populations — it is an
UPPER BOUND over the population, NOT a regression signal. A different number in
your sandbox is expected.** ⛔ **If it appears as a FAILURE, that is a finding.**
⚠️ **Known reds by TEST and MECHANISM:** `CX-kx6d` — `GitBridge.ServerTest`
*"filters: __ / nosync / presence … across two cycles"*, teardown check-then-act
(`Process.whereis` then `GenServer.stop` → `no process`); **unticketed** —
`GitBridge.ServerTest` *"push: failure to an unreachable remote … retries"*,
`{:error, :already_registered}` from `WorkspaceFixture.complete_workspace!/2`;
`CX-s9kc` — `chat_view_compute_supervisor_test.exs`. ⛔ **ANY OTHER failure, or
either of those with a DIFFERENT error shape, IS YOURS — say which, verbatim.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. ⛔⛔ **NO LIVE-STORE CONTACT, NO
  SERVE CONTACT — and for this round that is an ACCEPTANCE ARM, not just a rule.**
  *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/` —
  workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐ **Verify by RE-READ, not by the write returning.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES.**
  ⚠️ *Nine rounds running have produced their best result by correcting their
  brief — including one that shipped an allowlist where the brief asked only for
  three removals.*
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to prove arm 9 with a
  single chain, to satisfy arms 2 and 3 with one fixture, or to assert arm 12's
  isolation rather than demonstrate it.
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?**

## Review criteria

Twelve arms rehearsed against the landed mechanism with observed values; arms 2
and 3 with DISTINCT fixtures; arm 4 by identical-commit comparison rather than by
asserting rejection; arm 7 surviving a store restart; arm 9 with covered commits
on genuinely unrelated histories; arm 12 demonstrated rather than asserted; no
evidence seam reintroduced; per-file counts; and any unreachable arm reported as
a finding rather than approximated.
