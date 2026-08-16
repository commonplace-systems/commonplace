# Audit the twelve ceremony arms: did the fixture REACH the state it refuses from?

> **Ruled by `commonplace-plan` (`51f4963`).** Base: **the commit that adds this
> brief** — ⚠️ *not a sha.* **Build the worktree from that base.**

## What went wrong, and it was green the whole time

**Ceremony arm 10 read *"pre-activation registrations are refused, not
retroactively trusted"*. It passed. It never constructed the state its name
describes** — its "pre-existing tombstone" was never registered, because the
pre-anchor store attempt returned `:no_eviction_anchor_configured`.

⇒ ⭐⭐⭐ **THE ARM WAS REFUSING ON *ABSENCE*, NOT ON THE PROPERTY.**
⇒ ⛔ **THE FAILURE MODE, named: *REFUSING FOR THE RIGHT-LOOKING REASON AT THE
WRONG STAGE.*** **The atom is plausible, the arm is green, and nobody asks
whether the SETUP GOT FAR ENOUGH for the refusal to be about the property at
all.**

⚠️ **This was found only by PERTURBING the mechanism — three readings of the same
arm, each correcting the last: a source read said "unsatisfiable", a rehearsal
said "fires on the verify path", and only changing activation showed the
tombstone was never stored.** ⭐ *Neither reading nor re-running the unchanged
system could have surfaced it.*

## ⛔ What to build — one assertion per arm

**For EACH of the twelve ceremony arms in `sla_tombstone_test.exs`: BEFORE the
forbidden act is attempted, ASSERT THE PRECONDITION STATE EXISTS.**

⇒ ⭐ **This is *"prove the corpus was non-empty"* applied to TEST SETUP** — a law
this codebase already holds, in a habitat nobody had pointed it at.

**Concretely, per arm: what must be true for the refusal to be ABOUT the property?
Assert that, then attempt the act.** *Examples of the shape:*
- an arm about a tombstone being refused ⇒ **assert the tombstone IS IN THE STORE**
- an arm about an anchor being unactivated ⇒ **assert the anchor IS IN THE CONFIG**
- an arm about ordering ⇒ **assert BOTH positions EXIST and are DISTINCT**

⛔ **Do NOT change what any arm asserts about the refusal. This round adds
preconditions; it does not re-specify behaviour.** ⚠️ *If adding a precondition
makes an arm fail, that is the finding — report it, do not adjust the arm to
match.*

## ⭐⭐ REPORT THE RESULT AS A COUNT: **k of 12 were refusing on absence**

⇒ **That number is the ONLY evidence that will exist about whether auditing the
other ~89 negative assertions is worth a round.** ⛔ **A prose summary cannot
carry it.**

⚠️⚠️ **AND STATE THE ASYMMETRY IN YOUR REPORT, because the result will be
misread otherwise:**
```
DIRTY on the twelve  ⇒ DECISIVE FOR auditing the rest
CLEAN on the twelve  ⇒ LICENSES NOTHING about the rest
```
⇒ ⛔ ***THE TWELVE ARE NOT A RANDOM SAMPLE.*** **They are the most recently
written and most heavily reviewed negative arms in the codebase — so their defect
rate is a LOWER BOUND on the other 89, never an estimate of it.** ⭐ ***They can
PROMOTE the sweep; they cannot DEMOTE it.*** ⚠️ *Arm 10's defect appeared in the
arms that had the most care spent on them.*
⛔ **Do not write "the arms are clean, so the suite is probably fine." That is
measuring where the light is good and concluding about the dark.**

## ⛔ Acceptance

1. **All twelve arms carry a precondition assertion** naming what must exist for
   their refusal to be about the property.
2. ⭐⭐ **THE COUNT: `k of 12 were refusing on absence`**, with each affected arm
   named and what it was actually refusing on.
3. ⭐ **Any arm that FAILS once its precondition is asserted is REPORTED, not
   adjusted.** ⛔ *An arm that cannot reach its own state is the same defect as
   arm 10 and is the round's most valuable output.*
4. **The twelve still pass otherwise**, and the suite is green.
5. ⭐ **The asymmetry stated in the report** — clean licenses nothing.
6. **PER-FILE counts AND the suite total.**

## ⚠️ THE SANDBOX CANNOT SIGN

**`node_signing_key` is MASKED** ⇒ `NodeIdentity.signing_context/0` fails. ⭐ **Use
fixture signing contexts via `opts[:signing_context]`.** ⚠️ **`SlaTombstone.verify`
accepts ONLY `:store` in its options — deliberate. Do not widen it.**

## Suites

⛔ **`bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK.** **On-main:
`3521 / 0` at seed 117514, `origin/main` `defa7c61`.** ⚠️ **BUILD FROM THAT BASE.**
⚠️⚠️ **THE DETECTOR'S NUMBER IS NOT A BASELINE — it has read
`58 · 68 · 72 · 115 · 117 · 118 · 127 · 149 · 152` across populations and the
movement is UNATTRIBUTED. A different number is EXPECTED.** ⛔ **If it appears as
a FAILURE rather than `ADVISORY`, that is a finding.**
⚠️ **Known reds by TEST and MECHANISM:** `CX-kx6d` — `GitBridge.ServerTest`
*"filters: __ / nosync / presence … across two cycles"*, teardown check-then-act;
**unticketed** — `GitBridge.ServerTest` *"push: … unreachable remote … retries"*,
`{:error, :already_registered}` from `WorkspaceFixture.complete_workspace!/2`;
`CX-s9kc` — `chat_view_compute_supervisor_test.exs`. ⛔ **ANY OTHER failure, or
either with a DIFFERENT error shape, IS YOURS — say which, verbatim.** ⚠️ *And a
stray tmux socket has once triggered the launcher's channel-isolation test.*

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES.**
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to adjust an arm that
  fails its new precondition, or to summarise the count as "mostly fine".
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?**

## Review criteria

Twelve precondition assertions naming what must exist; the count `k of 12`
reported as a number with each affected arm named; any arm failing its
precondition reported rather than adjusted; the asymmetry stated so a clean
result cannot be read as licensing the other 89; suite green; per-file counts.
