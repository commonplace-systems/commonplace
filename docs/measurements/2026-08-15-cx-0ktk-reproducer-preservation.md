# `CX-0ktk`'s reproducer — how to reconstruct it, and why this file exists

**`CX-0ktk` was closed as NOT REACHABLE BY DETECTOR-BASED INVESTIGATION.** It was
not closed as *understood*. **The leak that makes `MUD.RoomVisibilityTest` fail
has never been explained**, and the only thing that ever reproduced it
deterministically is a population state.

⛔⛔ **A POPULATION STATE IS NOT A FILE, SO IT CANNOT BE MERGED. This document is
the reconstruction procedure, and it exists on `main` because
`SAFE MEANS REACHABLE FROM MAIN`.**

⚠️ *Two assets from that one round were nearly lost because a null governed them:
the detector (stranded on a branch) and this reproducer (recorded in memory as
"dead" when it was only dead on `main`). Both were caught by someone else
looking. This file is the third catch, made durable.*

## The reproducer

```
git worktree add <dir> origin/sol/cx-0ktk-round2-s75      # merge base 33279716, population 3510
cd <dir>/apps/commonplace
MIX_DEPS_PATH=/home/jes/commonplace/deps mix test --seed 117514
```

**Expect: `5 doctests, 3510 tests, <n> failures`, including**

```
Commonplace.MUD.RoomVisibilityTest
  test "look on a gated room, via PlayerSession
        the owner's own look on their gated room renders normally (self-read)"
  Assertion with =~ failed
  code:  assert out =~ "Owner's Den"
  left:  "(this place has no description)"
```

⭐ **Observed 2026-08-15 ~22:10 by the S80 round, which hit it incidentally and
reported it rather than waving it through as a known red.**

## ⚠️ WHAT THIS REPRODUCER IS AND IS NOT

⛔ **It is a fact about a FENCED WORLD: population `3510`, seed `117514`, on that
branch.** ⇒ ***Anything measured behind a fence inherits the fence as a fact.***
⚠️ **Aliveness at 3510-on-a-branch is NOT aliveness at 3519-on-main.** `I3`,
`I4`, `CX-fmzk` and the eviction anchor all landed in between — exactly the kind
of population change that could kill the failure OR resurrect it.

## What is established, and what is not

**ESTABLISHED** (measured, do not re-derive):
- Survives `--trace` / `max_cases: 1` ⇒ **sequential state contamination, NOT
  concurrency.** `CX-5gkw`'s load playbook does not apply.
- Survives `tmp/test_data` being stashed entirely ⇒ **not disk state, not
  `CX-hzad`.**
- **Ordering is not the discriminator**: at seed `117514` (RED) the suspected
  leaker runs at module #43 and the victim at #136; at seed `1` (GREEN) they run
  at #46 and #205. **The leaker precedes the victim in BOTH.**
- `local node self-trust was not added: node signing public-key artifact is
  absent` **is AMBIENT — it appears in PASSING tests.** ⛔ Do not build a
  mechanism on it.

**NOT ESTABLISHED:**
- Whether the failure is an unwritten doc or a gated read.
- Which test leaks. **Four elimination methods were refuted** — bisecting the
  population, replaying prefixes with ordering forced, the immediate-predecessor
  pair, and stashing `tmp/test_data` — because **every way of looking at a subset
  is itself a perturbation of the ordering under test.**

## ⛔ If you resume this

**The detector on `main` cannot see it as built**: it reports only what diverges
between a test's entry and exit, and its snapshots straddle `on_exit`, so a
legitimate set-and-restore is indistinguishable from a leak. **Every count it
reports is an upper bound.** *Fixing that means snapshotting after `on_exit`, not
at the formatter boundary.*

⚠️ **And do not delete `origin/sol/cx-0ktk-round2-s75`.** It is the only place the
population that reproduces this exists.
