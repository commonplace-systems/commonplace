# Bind an ephemeral principal to its deployment, and make the resolution a real lookup

> **Ruled by `commonplace-plan`.** Base: **the commit that adds this brief** —
> ⚠️ *not a sha.* **Build the worktree from that base.**

## The gap — measured on the current tree, not inherited from the design

**The joining arc's §2 and §4b claim that what makes many short-lived principals
COMPOSE rather than FRAGMENT ATTRIBUTION is the deployment record.** ⛔ **No code
does it.**

```
apps/commonplace/lib/commonplace/runner/deployment_record.ex
  occurrences of `signer_id`                       0
  fields validate_record requires:  deployment_id · started_at · ended_at ·
                                    runtime_profile · budget · capability_proofs
                                    ⇒ NO principal field at all

signer → durable-identity resolution anywhere in lib   0 files
  (positive control: `signer_id` appears in 36 other lib files, so the grep works
   and that zero is an absence rather than a broken query)
```

⚠️ **`I4` built deployment records BEFORE ephemeral principals existed, so this
looks done and is not.** ⭐ *That is why the citation is genuinely new rather
than a re-litigation.*

## ⛔ What to build — record + resolution, and nothing else

**Bind the ephemeral principal into the deployment record, and make
"which durable identity does this signer belong to?" A REAL LOOKUP through it.**

⛔⛔ **NO POD. NO CUSTODY. Neither is in scope and neither may be implied.**

## ⛔ Four arms — the third is the one that matters

| # | arm | expect |
| --- | --- | --- |
| 1 | a commit signed by an ephemeral principal | ✅ resolves to the durable identity **via its deployment record** |
| 2 | two deployments of the **same** identity | ✅ both resolve to it while remaining **DIFFERENT SIGNERS** |
| 3 | an ephemeral principal with **NO** deployment record | ⛔ **DISTINGUISHABLE BY A NAMED REFUSAL** from one that has a record |
| 4 | a record citing a principal that **never signed anything** | ⛔ refused |

### ⭐⭐⭐ ARM 3 IS THE DESIGN-TIME APPLICATION OF THIS WEEK'S DOMINANT DEFECT

**Without it, attribution returns a UNIFORM NEGATIVE** ⇒ ⛔ ***"this principal is
unattributable" becomes INDISTINGUISHABLE FROM "the lookup is broken."***

⚠️ **That shape has been hit THREE TIMES in the last six hours** — a wrong store
handle returning `{:no_commit, :none}` uniformly, a wrong struct field returning
`nil` × 324, and a metadata key absent returning `nil` where `false` was meant.
⇒ ⭐ ***Each was the most convincing possible wrong answer, because CONSISTENCY
READS AS RELIABILITY.*** **This is the first time we can forbid the shape BEFORE
it exists.**

⛔ **So: "no record" must return a NAMED refusal, distinct from any value the
lookup returns when it is broken or empty.** ⭐ **And the arm must SHOW the two
apart, not merely assert the refusal.**

### ⛔⛔ ARM 2 — DO NOT WRITE IT AS "SAME PRINCIPAL"

**The assertion is: both resolve to ONE DURABLE IDENTITY while remaining
DIFFERENT SIGNERS.** ⇒ ⛔ ***"Same principal" would make TWO DEPLOYMENTS SHARING
A KEY look like SUCCESS*** — the exact failure this arm exists to exclude.
⭐ *Same wording trap as S87 arm 7; both halves asserted separately.*

## ⛔ Acceptance — artifacts

1. **The deployment record carries the ephemeral principal**, readable back.
   *Verified by RE-READ, not by the write returning.*
2. ⭐⭐ **Arm 3's refusal is NAMED and demonstrably DISTINCT from a broken or
   empty lookup.** ⛔ *Show the two apart. A refusal that equals the empty answer
   is the defect this arm forbids.*
3. ⭐ **Arm 2 asserts BOTH halves — different signers AND one durable identity —
   without the words "same principal".**
4. ⭐ **Every negative arm asserts its PRECONDITION adjacent to the act**, and
   holds every other axis non-violating so the refusal is isolated to one cause.
   *(S87 arm 4's controlled-comparison form, now standard here.)*
5. ⭐⭐ **RED FIRST: show that TODAY there is no resolution** — verbatim — **and
   that after the change there is.**
6. ⛔ **State in your report that KEY CUSTODY IS NOT TESTED and needs a pod, and
   that NO JOIN CLAIM FOLLOWS.** *In your own words.*
7. **PER-FILE counts AND the suite total from the tool's own block, plus the
   POPULATION DELTA BY HAND.**

## ⚠️ THE SANDBOX CANNOT SIGN

**`node_signing_key` is MASKED** ⇒
`Commonplace.Crypto.NodeIdentity.signing_context/0` fails. ⭐ **Use fixture
signing contexts via `opts[:signing_context]`** — `DeploymentRecord.append/3`
already requires one and returns `{:error, :signing_context_required}` without it.

## Suites

⛔ **`bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK.** **Baseline
pasted verbatim as measured:**
```
  5 doctests, 3528 tests, 0 failures, 12 excluded, 1 skipped  (seed 117514, rc=0)
  --- state the run STARTED in … [stamp-v2] ---
  sha:        2e693cd6 (clean vs HEAD)
  test state: DIRTY — tmp/test_data/root present (written 2026-04-27)
  deps:       repo deps/   cwd: /home/jes/commonplace/apps/commonplace
```
⭐ **`[stamp-v2]` matters: v1 stamps could not see untracked test files, so a v1
`clean` means "clean except possibly for untracked tests". Your block will be v2.**
⚠️⚠️ **THE LEAK DETECTOR'S OBSERVED VALUES ARE A RECORD, NOT A BOUND** — seen so
far `0 · 58 · 68 · 72 · 115 · 117 · 118 · 122 · 123 · 126 · 127 · 135 · 141 ·
149 · 152`. ⛔ **A value outside that list is NOT an anomaly and NOT a finding.
Only `FAILURE` rather than `ADVISORY` is.**

### ⚠️ Known-nondeterministic, by TEST and MECHANISM — NOT yours

```
GitBridge.ServerTest — "GenServer.stop → no process" teardown check-then-act.
  THREE distinct tests, reproduced ON A CLEAN TREE. Known BY MECHANISM.
  ⛔ Any OTHER error shape in that module is YOURS.
DeniedWriteReportingTest — CX-7rjn. Handler counted a VM-WIDE telemetry stream the
  trust audit log also writes into. FIXED at 2e693cd6 by filtering on the emitting
  process; if it recurs, that is NEW and it is yours.
Runner.LauncherTest — "pod cannot read a canary injected by its launching BEAM".
  Environment-sensitive (CX-kacr); a stray tmux socket has triggered it. Fails as
  `canary_result == ""` where "absent" is expected. Passes in isolation.
  ⛔ A DIFFERENT error shape there is yours.
```

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐⭐ **REDIRECT TEST OUTPUT TO A FILE AND GREP THE FILE.** *The summary line is
  the one part of a run that cannot say what broke, and a transient gives you one
  chance at its artifact.*
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES**,
  including in the measured zeros above. ⭐ *Four rounds running have corrected
  this brief's author — on a count, on which stage a refusal happens at, on which
  files a change touches, and on an acceptance arm that had become unsatisfiable.*
- ⭐ **VERIFY BY RE-READ, not by the write returning.**
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to let "no record" and
  "lookup returned nothing" share a value, or to describe arm 2 as "same principal".
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?**

## Review criteria

The deployment record carrying its ephemeral principal and readable back; a real
resolution from signer to durable identity; arm 3's named refusal shown DISTINCT
from a broken or empty lookup; arm 2 asserting different-signers AND
one-durable-identity without "same principal"; preconditions adjacent to each
negative act; the red-first artifact; the custody bound stated; per-file counts,
the suite total, and the population delta by hand.
