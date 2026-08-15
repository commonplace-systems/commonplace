# I4 build brief: the tombstone exists to split an absence into its causes

> **Ticket/row: `I4`** of the §14 identity slice
> (`commonplace-plan:docs/plans/2026-08-15-identity-slice-decomposition.md`).
> Base: **the commit that adds this brief** — ⚠️ *not a sha.*
>
> ⛔⛔ **COMPONENT LANDING, NOT THE SLICE. NO ROUND PUBLISHES A "SLICE WORKS"
> CLAIM UNTIL `I5` RUNS.** *`I5` is the two-deployment proof and it is not yours.*

## Build

**§7's deployment record, written APPEND-ONLY by the runner, with the SLA tier
from finding 4: the log is EPHEMERAL; yields, decisions and findings are
PROMOTED BY REFERENCE under graded reachability.**

## ⭐⭐ WHY THE TOMBSTONE IS THE POINT

⛔ **`EVICTED-PER-POLICY`, `NEVER-WRITTEN`, and `LOST` ARE THREE DIFFERENT FACTS
THAT SHARE ONE OBSERVABLE: nothing is there.** ⇒ ⭐ **The tombstone exists
precisely to split that absence into its causes.** ⚠️ *This class cost real time
this week: a CLI printed a minted id and exited `0` for a write that never
landed, and "the ticket is absent" could not distinguish never-written from
lost until the store was asked directly.*

⇒ ⭐⭐ **SO THE ACCEPTANCE IS NOT "A TOMBSTONE EXISTS". IT IS "AN EVICTED RANGE
AND A NEVER-WRITTEN RANGE ARE DISTINGUISHABLE, AND THE READER CAN SAY WHICH."**

## ⛔ Acceptance — artifact-checkable

1. **A DEPLOYMENT WRITES ITS RECORD**, append-only. **Verified by RE-READ, not by
   the write returning.**
2. ⭐⭐ **A YIELD REFERENCED FROM A DURABLE TIER SURVIVES A SIMULATED EVICTION OF
   ITS DEPLOYMENT RANGE.** ⇒ **Show the reference resolving AFTER the eviction,
   with the value it returns.**
3. ⭐⭐⭐ **AN EVICTED RANGE LEAVES A ***SIGNED*** TOMBSTONE.**
   ⚠️ **PLAN'S EXACT CARVE: EVICTION MAY BE SIMULATED; THE TOMBSTONE MUST BE
   REAL.** ⛔ **A struct with a `:tombstone` field is NOT a tombstone.**
   ⇒ ⭐⭐ **VERIFY IT BY ITS SIGNATURE, NOT BY ITS SHAPE.** ***Every field you
   assert by equality is a field a forgery also satisfies.*** *Measured this week:
   a `@cid` present in a `DocRef` did not prove the pin was enforced, because
   `resolve/1` discarded it — the field was there and meant nothing.*
   ⛔ **Show the verification call and its result. `verify_sig`-shaped, not
   `record.type == :tombstone`.**
4. ⭐⭐ **THE THREE-WAY DISCRIMINATION, PRINTED AND SHOWN TO DIFFER:**
   ```
   evicted range      →  ?
   never-written range →  ?
   present range      →  ?
   ```
   ⛔ ***If two of these produce the same answer, the tombstone is not doing its
   job*** — **and a round that only demonstrates evicted-vs-present has tested
   the easy half.** ⚠️ *The never-written arm is the one that gets skipped.*
5. ⭐ **A FORGED OR TAMPERED TOMBSTONE MUST BE REFUSED, and the refusal must
   name why.** *If eviction is simulated, forging one is cheap — so this arm
   costs little and is the difference between a signature that is checked and one
   that is merely present.*
6. **Lands as files with their own counts from the tree.**

## ⚠️ THE SANDBOX CANNOT SIGN — plan for it, do not discover it

**`node_signing_key` is MASKED in your fence** ⇒ `NodeIdentity.signing_context/0`
**FAILS and NO node-signed write succeeds there.** ⛔ **A round assuming ambient
node signing produces a confident wrong diagnosis ("signing is broken"), not a
stuck run.**
⭐ **Use the injectable `opts[:signing_context]` seam.** **`Identity.ClassRatification`
and `Identity.SpawnCeremony` (`I3`/`I2`, already on main) are the closest worked
examples — read them first;** `Bursar` and `Frontier.Server` are the originals.
⭐ ***"Tested against fixtures, one assertion needs a real anchor" beats "we
couldn't test it."*** ⛔ **If an assertion needs a real anchor, NAME IT AS OWED.**

## ⭐ Prior art in the tree — read before inventing

- **`Commonplace.Identity.ClassRatification`** — `read_pinned/2` REFUSES an
  unpinned ref (`{:error, :class_version_required}`) rather than silently
  degrading. ⭐ **That is the shape to copy: make the bad state unrepresentable
  rather than documented.**
- **`Commonplace.Identity.Root` / `SpawnCeremony`** — the append-only
  record + re-read-to-confirm pattern, and `signing_context` threading.

## Suites

⛔ **Run `bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK; read the
`BEFORE` line.**
⚠️⚠️ **THE BASELINE MOVED TODAY AND THE OLD NUMBER IS IN OLDER BRIEFS: `I3`
merged, so the population is NO LONGER 3510.** ⭐ **Take the count from the tool's
own block, not from any brief — including this one.**
⚠️ **`CX-0ktk` was a suite-ordering failure (`MUD.RoomVisibilityTest`) that
reproduced at seed `117514` on population 3510. It was reported NOT REACHABLE by
detector-based investigation and the population has since moved; it may or may
not appear for you.** ⛔ **If `MUD.RoomVisibilityTest` fails, that is `CX-0ktk`
and NOT YOURS — say so and continue.** **`CX-s9kc`: sandbox
`chat_view_compute_supervisor_test.exs` flake, non-deterministic, NOT yours.**
⛔ **Anything else IS yours.**
⚠️ **In a fresh worktree `mix format --check-formatted` exits `rc=1` with
"Unknown dependency :phoenix" — the SAME CODE as "files are not formatted".**
⇒ **Never branch on `rc` alone: a real format failure LISTS FILE PATHS.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐ **Verify by RE-READ, not by the write returning.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES
  rather than satisfying it.** ⚠️ *Its author was 0-for-5 on a bug today, and the
  last two rounds' best contributions were both CORRECTIONS to their briefs —
  one caught an overstated "never perturbing" claim, the other killed its own
  instrument's headline finding.* ⭐ **That is the most valuable thing a round
  can do here.**
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to assert the tombstone
  by shape, or to skip the never-written arm because evicted-vs-present already
  passes.
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?** *Answer
  as a CHAIN, as `I2` and `I3` did.*

## Review criteria

Append-only record verified by re-read; a durable-tier reference surviving
simulated eviction with its resolved value shown; a REAL signed tombstone
verified by SIGNATURE rather than by field equality; the three-way
evicted/never-written/present discrimination printed and shown to differ; a
forged tombstone refused with a named reason; and the suite counts taken from
the tool's own block rather than inherited.
