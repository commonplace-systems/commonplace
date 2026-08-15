# Eviction-signer anchor: provision what `CX-fmzk` made mandatory

> **Design: `commonplace-plan:docs/plans/2026-08-15-eviction-signer-anchor.md`
> (ranked #1). This brief is self-contained — you do not need that repo.**
> Base: **the commit that adds this brief** — ⚠️ *not a sha.*

## Why now, not later

**`CX-fmzk` (already merged) made `SlaTombstone.verify` check the signer against
a configured trusted set, and refuse `:no_eviction_anchor_configured` when none
is set.** ⛔ **Nothing provisions that set.**

⇒ ⭐ **The refusal is correct and unreachable today. It becomes reachable the
moment a production writer first evicts — and AT THAT MOMENT the cheap moves are
to provision whatever key is nearest, or to loosen the check.** ⇒ ***The window
in which this is cheap is the window before anything depends on it.***

## What to build

### ① A DISTINCT principal whose only capability is eviction

⛔ **NOT the node identity.** *The node signs everything it does, so an eviction
signed by the node key is indistinguishable from any other node act, and holding
the node key would confer eviction authority as a side effect.*
⇒ ⭐ **One principal, one meaning: holding that key IS the authority to evict and
nothing else grants it.** *Then "who could have written this tombstone" has
exactly one answer per anchor.*

### ② A SEPARATE `eviction_anchors` set — never `trusted_identities`

⛔ **`trusted_identities` answers *whose commits do we accept*. Folding eviction
into it would let every trusted writer produce an accepted tombstone** — which
re-creates the condition `CX-fmzk` closed, one layer up.
⇒ **`eviction_anchors` is its own set in the trust config: same file, same load
path, same absent-config posture.** ⭐ **An identity in BOTH sets is then a
DECLARED exception a reviewer can see, not an accident of sharing one list.**
⇒ ⭐⭐ **State the consequence plainly, because it IS the point: a node that
accepts a principal's WRITES still refuses that principal's TOMBSTONES unless
separately anchored.** ***Eviction is not a stronger write; it is a different
act.***

### ③ APPEND-ONLY anchors with `retired_at`, verified by CHAIN POSITION

**A tombstone is a durable explanation for absent data, so it must stay
verifiable after the key that signed it is gone.** ⛔ *If rotating the eviction
key made old tombstones unverifiable, rotation would silently convert EXPLAINED
absence back into UNEXPLAINED absence — the inversion `CX-fmzk` exists to
prevent.*
⇒ **Anchors are ADDED and MARKED retired, never replaced or deleted.**
Verification asks ***"was this anchor valid when this tombstone was written?"***
not *"is this anchor current?"*
⛔⛔ **AND "WHEN" IS CHAIN POSITION, NOT WALL CLOCK.** ⚠️ *A `signed_at` field
inside the tombstone is supplied by the record itself — the same shape as reading
the signing key off the struct, which is the defect this whole line of work
started from.* ⇒ **Use the tombstone's position in the commit chain, which the
store already orders.** **An anchor retired at commit N verifies tombstones at
chain positions before N.**

### ④ RETIREMENT and REVOCATION stay distinct

- **Retirement** = *this key stopped being used.* **Its old signatures remain
  valid.**
- **Revocation** = *this key is withdrawn as unsafe.* **Its signatures are void
  from the revocation point.** *`CX-bepn`'s content-addressed revocation records
  already carry that semantics — reuse them.*

⛔ **Conflating them means EITHER a routine rotation invalidates history OR a
withdrawn key leaves bad tombstones standing.** ⚠️ ***A single "remove the key"
operation would silently pick one of those, and the brief exists partly to stop
that.***

### ⑤ Provisioning reuses existing machinery — invent no custody

**`AgentKeys` mint · custody in the serve-local `SecretStore` · the binding
recorded on the identity doc (`held_by`, `role`, `minted_by`, `minted_at`),
exactly as the reviewer identity was minted on 2026-08-13.** ⛔ **NO new custody
mechanism.** ⭐ *An identity with ambiguous custody cannot audit, and equally
cannot evict.*
⚠️ **Adding an anchor to the trust config is a constitutional-tier act** — it
grants a new KIND of authority. ⛔ **If landing that ratification is beyond what
you can do in-sandbox, mark it UNVERIFIED and STOP rather than approximating it.**

## ⛔ Acceptance — six arms, artifact-checkable

1. **An anchored principal's tombstone VERIFIES; one signed by any other key is
   REFUSED — and the refusal names WHICH CHECK FAILED**, not merely that
   verification failed.
2. ⭐⭐ **THE `CX-fmzk` REPRODUCTION, UNCHANGED, MUST NOW FAIL:** *build a
   tombstone whose `signer_public_key` is a keypair you generated, naming
   yourself the signer.* ⇒ ⭐ **This fixture ALREADY EXISTS in
   `sla_tombstone_test.exs` — it is a NATURAL fixture, not a manufactured one,
   and it attempts the thing the check must refuse rather than merely making a
   check go red.**
3. ⭐⭐ **A principal in `trusted_identities` but NOT in `eviction_anchors` is
   REFUSED.** ⛔ **The separation DEMONSTRATED, not asserted** — this is the arm
   that proves ② is real.
4. ⭐⭐ **A tombstone signed BEFORE its anchor was retired STILL VERIFIES after
   retirement; one signed AFTER does not.** ⛔ **By CHAIN POSITION. If you find
   yourself comparing timestamps, that is the wrong axis — stop and report.**
5. ⭐ **A revoked anchor's tombstones are void from the revocation point, AND
   that is DISTINGUISHABLE IN THE REFUSAL from a retired anchor's.** *Two words,
   two behaviours, two messages.*
6. ⭐ **ABSENT CONFIG STILL REFUSES** — `CX-fmzk`'s existing
   `:no_eviction_anchor_configured` must survive this change. ⛔ **Assert it, so
   it cannot regress into a default.** ⚠️ *A provisioning round is exactly where
   "just default it to something" arrives wearing a convenience argument.*

⭐ **PRINT EVERY ARM'S OUTCOME AND SHOW THE PAIRS DIFFER.** ⛔ ***If two arms
defined to differ produce the same value, the arms did not run.***

## ⚠️ THE SANDBOX CANNOT SIGN — plan for it, do not discover it

**`node_signing_key` is MASKED in your fence** ⇒
`Commonplace.Crypto.NodeIdentity.signing_context/0` **FAILS and no node-signed
write succeeds.** ⭐ **Use the injectable `opts[:signing_context]` seam** —
`sla_tombstone_test.exs` and the `Identity.*` modules are worked examples.
⚠️ **A full suite DOES run in a worktree despite the baseline block saying "no
repo `deps/`".**

## Suites

⛔ **Run `bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK.** **Core was
`3518 / 0` at seed 117514 as of this brief — TAKE THE NUMBER FROM THE TOOL'S OWN
BLOCK, not from here.** ⭐ *The tool was fixed today so it no longer withholds a
green `commonplace_web` result; if it still exits 3 on a passing run, that is a
finding.*
⚠️ **`CX-s9kc`: sandbox `chat_view_compute_supervisor_test.exs` flake, NOT yours.**
⚠️ **`CX-kx6d`: `GitBridge.ServerTest` has a check-then-act teardown race that
goes red under load, NOT yours.** ⛔ **Anything else IS yours.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐ **Verify by RE-READ, not by the write returning.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES.**
  ⚠️ *The last five rounds' most valuable contributions were all corrections to
  their briefs rather than compliance with them.*
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to fold
  `eviction_anchors` into `trusted_identities` "since it is the same file", to
  compare timestamps instead of chain positions, or to give absent config a
  default.
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?**

## ⚠️ Held open by the design — do NOT decide these

**One anchor per node or per fleet (the federation case); whether an eviction
anchor may also be a delegation root (default NO); and who holds the key
operationally once pods exist.** ⛔ **If your work forces one of these, STOP AND
REPORT rather than choosing** — *they are being settled with finding 1 of the
identity review, together rather than twice.*

## Review criteria

A distinct eviction principal; `eviction_anchors` as its own set with the
trusted-but-not-anchored refusal demonstrated; append-only anchors with
retirement judged by chain position and not timestamps; retirement and revocation
distinguishable in the refusal; the existing `CX-fmzk` fixture now failing;
absent-config refusal asserted; every arm printed and shown to differ; and no
held-open question silently decided.
