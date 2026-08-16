# Make mint success mean something: the third gate, or a sentence saying why not

> **Ruled by `commonplace-plan` after S87.** Base: **the commit that adds this
> brief** — ⚠️ *not a sha.* **Build the worktree from that base.**

## The asymmetry — measured, not inferred

**`Capability.issue/5` runs two gates and not a third:**

```
subtree root equality       ✅ enforced AT MINT   (check_subtree_delegation, D1)
verb attenuation            ✅ enforced AT MINT   (check_attenuation)
may this parent delegate?   ❌ NOT enforced at mint
```

**Measured on `capability.ex`: `:delegate` appears ZERO times** *(positive
control: `check_attenuation` appears 3 times in the same file, so the file was
read).* **The only enforcement is `verify_chain.ex`:**

```
if :delegate in verbs, do: :ok, else: {:error, :delegation_not_permitted}
```

**Observed in S87, arm 5 — a cell WITHOUT `:delegate`:**
```
Capability.issue(…)          ⇒  {:ok, deployment}                        ← MINTS
VerifyChain.verify_chain(…)  ⇒  {:error, :delegation_not_permitted}
```

## ⛔ Why this is worth a round, and it is NOT that a refusal is missing

**The system fails closed. `verify_chain` does refuse.** ⇒ ⛔ **The defect is the
SILENT ASYMMETRY, not a missing check.**

⭐⭐ **In the ruling author's own words, written in the D1 design about the
same-root check:** ***"a mint that emits unusable certificates is a footgun, even
though the system still fails closed."*** ⇒ **That reasoning was established and
applied to ONE axis.**

⇒ ⛔ ***`{:ok, cap}` FROM `issue/5` IS A MISLEADING SIGNAL.*** **Any caller that
treats mint success as authority holds a certificate that can never verify.**

⚠️ **Rank basis: PROTECTION BEFORE THE HAZARD. The deployment-cert path is the
identity arc's live surface and pod integration is its next consumer.** *Fix the
footgun before the consumer arrives, not after it fires.*

## ⛔ What to build — the PROPERTY, not a particular mechanism

**MINT SUCCESS MUST NOT BE A MISLEADING SIGNAL.** Two acceptable outcomes:

1. ⭐ **PREFERRED — enforce the parent's `:delegate` verb AT MINT**, alongside
   the other two gates, so all three refuse at the same stage.
2. **If you find a REASON verify-only is deliberate — a caller that legitimately
   mints before the parent is known-delegable, an ordering constraint, a test
   that depends on it — DO NOT FORCE THE CHANGE. Report the reason, and instead
   make the asymmetry EXPLICIT AT THE SITE** with a comment naming why the third
   gate is verify-time only.

⛔ **Silence is not acceptable. Either the gate or the sentence.**
⭐ **The escape hatch is stated up front deliberately: if this subject cannot
carry the change, SAY SO — that is a publishable result, not a failure.**

## ⚠️⚠️ THIS CHANGE BREAKS AN EXISTING TEST ON PURPOSE — that is EXPECTED

**`deployment_capability_attenuation_test.exs` arm 5 currently asserts:**
```elixir
assert {:ok, deployment} = Capability.issue(…)          # ← today's behaviour
…
assert {:error, :delegation_not_permitted} = VerifyChain.verify_chain(…)
```
⇒ ⛔ **If you take option 1, THAT `{:ok, …}` BECOMES A REFUSAL and arm 5 fails.**
⭐ **THAT IS NOT A REGRESSION — it is the point.** ⚠️ **Update arm 5 to assert the
mint-time refusal, and KEEP a verify-time arm as well** *(construct the
unverifiable chain directly if mint no longer emits one)* — **because
`verify_chain`'s independent refusal is defence in depth and must not be
deleted by making the mint stricter.**
⛔ ***Do not delete the verify-time assertion. A stricter mint that removes the
verify-time check is a NET LOSS of protection.***

## ⛔ Acceptance — artifacts

1. ⭐⭐ **RED FIRST: show that TODAY a cell without `:delegate` MINTS a child**,
   verbatim, **and that after the change it does not** (or, under option 2, that
   the site now states why it does not refuse).
2. ⭐ **The red arm carries its PRECONDITION, asserted adjacent to the act:**
   that the parent genuinely lacks `:delegate` and that every OTHER axis is
   non-violating — same root, verbs attenuating, window within. ⇒ *So the
   refusal is isolated to the delegate verb and cannot be produced by another
   gate.* **(This is S87 arm 4's controlled-comparison form, now the standard.)**
3. ⭐⭐ **THE VERIFY-TIME REFUSAL STILL EXISTS AND IS STILL ASSERTED.**
4. **All three mint gates named in one place** — a comment or a test — so the
   next reader sees the set rather than discovering the asymmetry again.
5. **`deployment_capability_attenuation_test.exs` still passes as a whole**, with
   arm 5 updated, and its other six arms untouched.
6. **PER-FILE counts AND the suite total from the tool's own block.**

## ⚠️ THE SANDBOX CANNOT SIGN

**`node_signing_key` is MASKED** ⇒
`Commonplace.Crypto.NodeIdentity.signing_context/0` fails. ⭐ **Use fixture
signing contexts via `opts[:signing_context]`.** ⚠️ **Do not widen a function's
accepted options to make an arm reachable — if an arm needs more, that is a
finding.**

## Suites

⛔ **`bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK.** **On-main
baseline WITH ITS STATE STAMP — the stamp is part of the number:**
```
  5 doctests, 3528 tests, 0 failures, 12 excluded, 1 skipped  (seed 117514, rc=0)
  sha:        <the commit adding this brief>   test state: DIRTY — tmp/test_data/root present
  deps:       repo deps/                       cwd: /home/jes/commonplace/apps/commonplace
```
⚠️ **A run in a DIFFERENT state may legitimately differ — that is a scope
difference to investigate, NOT the round being wrong.** ⭐ *A suite total without
its state stamp is not a baseline.*
⚠️⚠️ **THE LEAK DETECTOR'S NUMBER IS NOT A BASELINE — read as
`0 · 58 · 68 · 72 · 115 · 117 · 118 · 122 · 123 · 126 · 127 · 149 · 152` across
populations, movement UNATTRIBUTED.** ⛔ **If it appears as a FAILURE rather than
`ADVISORY`, that is a finding.**

### ⚠️ Known-nondeterministic, by TEST and MECHANISM — NOT yours

```
GitBridge.ServerTest      GenServer.stop → "no process" in on_exit. MODULE-WIDE:
                          seen in "filters: __ / nosync / presence", "phantom-diff
                          pin", "pause/resume". Reproduced on a clean tree.
DeniedWriteReportingTest  CX-7rjn. Ordinal selection over a nondeterministic write
                          sequence (observed 4 and 5). Fails as
                          `assert landed_count == 4` (left: 5) OR as a
                          `CX-7rjn: ordinal selection picked …` message.
chat_view_compute_supervisor_test.exs    CX-s9kc.
```
⛔ **ANY OTHER failure, or these with a DIFFERENT ERROR SHAPE, IS YOURS — say
which you saw, verbatim.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES**,
  including in the measured block above. ⭐ *The last two rounds each corrected
  this brief's author — one on a count, one on which stage a refusal happens at —
  and those were their most valuable outputs.*
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to delete the
  verify-time assertion once the mint refuses, or to call arm 5's expected
  failure a regression.
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?**

## Review criteria

Mint success no longer misleading — either a third gate at mint or a sited
statement of why not; the red-first artifact showing today's `{:ok, …}`; the red
arm's precondition isolating the delegate verb from every other gate; the
verify-time refusal retained and asserted; all three gates named in one place;
arm 5 updated rather than deleted; per-file counts and the suite total.
