# CX-h062 build brief: re-land the deploy-gap check with BOTH controls

> **The work's ticket is CX-h062.** Base: **the commit that adds this brief**
> — ⚠️ *not a sha; committing a brief moves HEAD past any sha it records.*
> Verify with `git ls-remote origin main` before cutting.
>
> ⛔⛔ **THE DEFECT THIS REPAIRS IS THE INVERSE OF THE USUAL ONE: not a check
> that CANNOT go red, but A CHECK THAT WENT RED ON CORRECT STATE.** ⇒ *A gate
> that fires on correct state is strictly worse than no gate, because it
> trains everyone to route around it* — **and `--no-compile` was already
> circulating as the workaround within an hour.**

## What happened, measured

The removed arm asserted **"no beam in the build is newer than the running
TEST VM."** ⛔ **`mix test` boots the VM and THEN compiles**, so any beam
recompiled during the run is newer than the VM's start **by construction**.

```
clean tree, no source change to the flagged modules:
  10 beam(s) newer than that start, rc 2
  MUD.PlayerSession.beam / Bd.Invariants.beam  mtime 16:22:06
  VM booted seconds earlier
```
⚠️ **It passed only when nothing needed recompiling** — which is why it read
as *intermittent* rather than *wrong*.

## ⭐⭐ AND THE SURVIVING TEST HAS THE SAME GAP — re-derived at authoring time

`deploy_gap_test.exs` now contains **exactly one test**, and it asserts
**`status == 1`**: a synthetic tmp_dir with one 2020 beam and one 2030 beam,
proving the gauge **fires**.

⛔ **There is NO arm asserting the GREEN direction — that a build with no
newer beams exits 0.** ⇒ ⭐ **So the true-negative gap is not only in the arm
we removed; it is in what SURVIVED.** ⚠️ *Both halves of this file prove the
gauge can fire. Neither proves it stays quiet when it should.*

## ⛔ The acceptance — arm 2 is the round

1. **A true POSITIVE**: perturb, and the check fires, naming the beams.
   *(Already demonstrated; keep it.)*
2. ⭐⭐ **A TRUE NEGATIVE, AND THIS IS WHY THE TICKET EXISTS: A NORMAL BUILD
   THAT RECOMPILES MUST NOT FIRE.** ⇒ **Construct the exact condition that
   broke it — a reference, then a recompilation, then the check — and show it
   staying GREEN.** ⛔ **A re-land that only proves it still fires is the same
   half-control that shipped the defect.**
3. ⭐ **THE REFERENCE IS JUSTIFIED FOR ITS SUBJECT, NOT BORROWED.** ⇒ **State
   what instant the check compares against and WHY that instant is the right
   one for the thing being guarded.** ⚠️ *The removed arm borrowed the serve's
   reference for a test VM. If you cannot justify a reference for a given
   subject, SAY SO AND GUARD A DIFFERENT SUBJECT.*
4. **The failure still names which beams.** *(Already true; do not regress
   it.)*
5. **Tests LAND AS FILES with their own count from the tree.**

## ⚠️ What the check is FOR — do not lose this in the re-reference

**The hazard is the SERVE**: modules load lazily, so while beams are newer
than the serve's start, **any incidental load is an unplanned partial
deploy.** ⭐ **The gauge is CORRECT for the serve, which does not compile
after it starts.** ⇒ ⛔ **If the honest conclusion is that the TEST VM cannot
be guarded this way at all, that is a legitimate answer — say it, keep the
synthetic arm plus a true negative, and leave the serve-side check to
`CX-beph`.** ⚠️ **Do not invent a reference to make a CI arm possible.**

## ⛔ Scope

- **MAY touch**: `apps/commonplace/test/commonplace/deploy_gap_test.exs` ·
  `bin/cp-deploy-gap`.
- ⛔ **MUST NOT change**, verified present at this base:
  `runner/run_recipe.ex` (md5 `230839fc23e1047282306486ea48db41`) ·
  `runner/run_recipe_test.exs` (md5 `07c92ded3ac4668225fdff5eb3482602`) ·
  `cli/access.ex` · `store/lock_refusal.ex` · `cli_access_test.exs`
  (all landed hours ago in `CX-a3fe`).
- ⛔ **`sol-egress-run.sh` is never edited from inside a round**; ⭐ *a test OF
  a fence is not an EDIT TO the fence.*

## Suites

Baseline, **falsifiable — measure your own**: core **3,493 / 0 failures /
1 skipped** at **seed 117514**. ⚠️ *That is one LOWER than yesterday's 3,494
because the bad arm was removed — do not "correct" it upward.*
⛔ **REPORT THE SEED OF EVERY RUN.** ⛔ **Never pipe a long `mix test`.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact.** ⚠️
  **And do not probe the live serve for a reference**: its module set is the
  subject of the sibling ticket, and a probe that loads a module makes the
  finding true by making it happen.
- ⛔ **Do not run `mix format` or `mix precommit`.**
- ⛔ **If you cannot find this brief, STOP AND SAY SO.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⚠️ *Its author shipped
  the defect it repairs, and had been warned in writing that the reference
  would not generalise — and read that warning as being about future work.*
  ⛔ **If the measurements, the surviving-test claim, or the counts do not
  match the artifact, REPORT THE DISCREPANCY.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to make the CI arm
  work by choosing a reference that happens to pass today.

## Review criteria

A true negative demonstrated on a build that actually recompiles; the
reference stated and justified for its subject; the true positive retained;
failures still naming beams; and — if the test VM turns out to be
unguardable this way — that conclusion stated plainly rather than worked
around.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). ⚠️ Not reachable
from inside the sandbox — **a capability boundary, not a defect.**
