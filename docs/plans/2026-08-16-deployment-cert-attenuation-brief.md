# Mint a DEPLOYMENT cert from a CELL cert, and pin the attenuation

> **Ruled by `commonplace-plan`.** Base: **the commit that adds this brief** —
> ⚠️ *not a sha.* **Build the worktree from that base.**

## What this round is, and what it deliberately is not

**The identity arc needs a middle link: a long-lived CELL capability minting a
short-lived DEPLOYMENT capability.** `D1` landed, so the two-level subtree chain
is mintable. **This round proves the middle link BEHAVES — nothing more.**

⛔⛔ **EXPLICITLY OUT OF SCOPE, AND THE ROUND'S OUTPUT MUST SAY SO:**
**KEY CUSTODY IS NOT TESTED HERE.** Whether the cell key is absent from a pod
and only the ephemeral key is present **requires a pod** and is not observable in
this round. ⇒ ⭐ **State that as a bound in your report, in your own words. Do
NOT publish, or imply, any claim that "join works" or that custody holds.**

⚠️ *Why the decomposition: "pods mint ephemeral principals" bundles cert
attenuation + pod execution + key custody into one unknown. This slice takes
only the first.*

## ⛔ Verified facts you can build on — re-derive any that matter to you

```
Capability.issue/5            runs check_subtree_delegation THEN check_attenuation
check_subtree_delegation      compares child_root to parent_root by EXPLICIT EQUALITY
scope_set({:subtree, _root})  MapSet.new([])          ← empty, on purpose
caveat_window_within?         child not_before >= parent, child not_after <= parent
VerifyChain.within_window/2   returns :not_yet_valid | :expired
VerifyChain.combine_scope     independently requires identical roots at verify time
```
⭐⭐ **THE ONE THAT WILL MISLEAD YOU IF YOU MISS IT: `attenuates?` IS VACUOUS FOR
SUBTREE SCOPES**, because `scope_set({:subtree, _})` is empty and an empty set is
a subset of everything. ⇒ ⛔ **A different-root refusal must come from the
EXPLICIT equality check at MINT, NOT from `attenuates?`.** ⚠️ *If you assert a
different-root refusal and it passes, confirm WHICH mechanism refused — a
vacuous check produces the right answer for no reason.*

## ⛔ Seven arms — five of them RED

**Each arm asserts its PRECONDITION STATE immediately before the act it guards.**
⭐ *That is now standing practice here: a refusal is only about the property if
the setup reached the state. Arm 10 of the eviction ceremony passed for its whole
life while refusing on ABSENCE.*

| # | arm | expect |
| --- | --- | --- |
| 1 | same root · subset verbs · **tighter** `not_after` | ✅ mints and verifies |
| 2 | same root · **looser** `not_after` than the cell | ⛔ refused |
| 3 | **different** subtree root | ⛔ refused **AT MINT** |
| 4 | a verb the cell cert does not carry | ⛔ refused |
| 5 | cell cert lacking `:delegate` | ⛔ refused |
| 6 | **after expiry**, a write signed by the deployment key | ⛔ refused, **naming expiry** |
| 7 | deployment's commits verify as a **different signer** than the cell | ✅ both resolve to the same durable identity |

### ⭐⭐⭐ ARM 6 IS THE LOAD-BEARING ONE — say so in your report

**The whole reason an ephemeral key may live in a pod at all is that IT IS
WORTHLESS AFTER EXPIRY.** ⇒ ⭐ ***THE WORTHLESSNESS IS THE THING UNDER TEST.***
⛔ **A write signed by the deployment key after `not_after` must be refused, and
the refusal must NAME EXPIRY** (`:expired` from `within_window/2`) — **not a
generic trust rejection.** ⚠️ *If it refuses for some other reason, the arm has
not tested what it claims: report which reason you saw, verbatim.*

### ⛔⛔ ARM 7 — DO NOT WRITE IT AS "SAME PRINCIPAL"

**The assertion is: the deployment's commits verify as a DIFFERENT SIGNER from
the cell's, and BOTH resolve to the SAME DURABLE IDENTITY.**
⇒ ⛔ ***Phrasing it as "same principal" would make TWO DEPLOYMENTS SHARING A KEY
look like SUCCESS*** — which is the exact failure this arm exists to exclude.
⭐ **Different signer, same identity. Both halves asserted.**

## ⛔ Acceptance — artifacts

1. **Seven arms, five red, each with its precondition asserted adjacent to the
   act it guards.**
2. ⭐ **Arm 3 states WHICH mechanism refused** — the explicit mint-time equality,
   not `attenuates?`. ⚠️ *A vacuous check gives the right answer for no reason.*
3. ⭐⭐ **Arm 6's refusal NAMES EXPIRY, verbatim.**
4. ⭐ **Arm 7 asserts BOTH halves — different signer AND same durable identity.**
5. ⭐ **The out-of-scope bound stated in your own words: key custody is NOT
   tested here and needs a pod.**
6. **Any arm that fails once its precondition is asserted is REPORTED, not
   adjusted.**
7. **PER-FILE counts AND the suite total from the tool's own block.**

## ⚠️ THE SANDBOX CANNOT SIGN

**`node_signing_key` is MASKED** ⇒ `Commonplace.Crypto.NodeIdentity.signing_context/0`
fails and no node-signed write succeeds. ⭐ **Use fixture signing contexts via
`opts[:signing_context]`.** ⚠️ **Do not widen a function's accepted options to
make an arm reachable — if an arm needs more, that is a finding.**

## Suites

⛔ **`bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK.** **On-main
baseline, WITH ITS STATE STAMP — the stamp is part of the number:**
```
  5 doctests, 3521 tests, 0 failures, 12 excluded, 1 skipped  (seed 117514, rc=0)
  sha:        160a66fa (clean)     test state: DIRTY — tmp/test_data/root present
  deps:       repo deps/           cwd: /home/jes/commonplace/apps/commonplace
```
⚠️ **A run in a DIFFERENT state may legitimately differ — treat a mismatch as a
scope difference to investigate, NOT as the round being wrong.** ⭐ *A suite total
without its state stamp is not a baseline.*
⚠️⚠️ **THE LEAK DETECTOR'S NUMBER IS NOT A BASELINE — it has read
`0 · 58 · 68 · 72 · 115 · 117 · 118 · 122 · 126 · 127 · 149 · 152` across
populations and the movement is UNATTRIBUTED.** ⛔ **If it appears as a FAILURE
rather than `ADVISORY`, that is a finding.**

### ⚠️ Known-nondeterministic, by TEST and MECHANISM — NOT yours

```
GitBridge.ServerTest      GenServer.stop → "no process" in on_exit.
                          MODULE-WIDE: seen in "filters: __ / nosync / presence",
                          "phantom-diff pin", and "pause/resume". Reproduced on a
                          clean tree.
DeniedWriteReportingTest  CX-7rjn. Ordinal selection over a write sequence whose
                          length is nondeterministic (observed 4 and 5). Fails as
                          `assert landed_count == 4` (left: 5), OR as a
                          `CX-7rjn: ordinal selection picked …` message.
chat_view_compute_supervisor_test.exs   CX-s9kc.
```
⛔ **ANY OTHER failure, or these with a DIFFERENT ERROR SHAPE, IS YOURS — say
which you saw, verbatim.** ⚠️ *A stray tmux socket has once triggered the
launcher's channel-isolation test.*

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES** —
  including in the verified-facts block above. ⭐ *The last round corrected this
  brief's author on a count, and that was its most valuable output.*
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to let a vacuous check
  stand because it produced the expected answer, or to describe arm 7 as "same
  principal".
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?**

## Review criteria

Seven arms with preconditions adjacent to their acts; arm 3 naming the mint-time
equality as the refusing mechanism rather than `attenuates?`; arm 6's refusal
naming expiry verbatim; arm 7 asserting different-signer AND same-durable-identity
without the words "same principal"; the custody bound stated; any precondition
failure reported rather than adjusted; per-file counts and the suite total.
