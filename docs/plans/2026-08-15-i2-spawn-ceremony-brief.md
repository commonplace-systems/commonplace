# I2 build brief: the spawn ceremony, minus ratification

> **Row `I2`** of the §14 identity slice
> (`commonplace-plan:docs/plans/2026-08-15-identity-slice-decomposition.md`).
> Base: **the commit that adds this brief** — ⚠️ *not a sha.*
>
> ⛔⛔ **COMPONENT LANDING. NO "SLICE WORKS" CLAIM UNTIL `I5` RUNS.** *State what
> you landed, never what it implies.*

## Build

**§5 steps 1–4 and 6–8 as a gated, IDEMPOTENT transaction:**
parent proposes · **child mints its own keypair INTO THE CHILD'S OWN WORKSPACE**
(finding 1 — *not* the deployment's, *not* a container's) · parent signs the
birth commit · child signs activation · issuer mints the attenuated cert · first
deployment permitted only after activation.

⚠️ **Step 5 (steward ratification) is DELIBERATELY DEFERRED to `I3`, so this
round has ONE unknown, not two.** ⛔ **Do not build it.**

⭐ **You are building on `I1`, which landed at `41ba1906`:
`Commonplace.Identity.Root` — a GenServer with `read_record` / `write_record`,
`genesis`, and a `records` DocRef map.** *Records are separate self-zoned
documents; that is what lets `{:subtree, uuid}` scope them, and it is why `I1`
needed no record-type check.*

## ⚠️ THERE IS NO EXISTING SPAWN PATH — "the pre-fix path" is one YOU write

**Checked before briefing: no spawn ceremony exists.** *(`runner/provisioner.ex`
is pods; `mud/bot.ex` is bots; `identity/root.ex` has `birth_commit` as a field
and no ceremony.)*

⇒ ⭐ **So the red-first arm means: WRITE THE NAIVE PATH, DEMONSTRATE IT MINTS
TWICE, THEN MAKE IT IDEMPOTENT.** ⛔ **Do not go hunting for an existing
double-mint to reproduce — you will not find one and you will burn the round
looking.**

## ⛔ Acceptance

1. ⭐⭐ **IDEMPOTENCE, RED-FIRST.** Repeating an identical spawn request resolves
   to the **same child** or a **named conflict** — **never a duplicate.**
   ⇒ ⛔ **The pre-fix path MINTS TWICE and that must be DEMONSTRATED BEFORE it is
   fixed.** *That is `CX-0mns`'s shape: a retry after partial failure produces a
   second identity instead of resolving to the first.* ⭐ **Show the two distinct
   ids from the naive path, then show one id (or a named conflict) after.**
2. **A partial birth remains `Provisioning` and HAS NO ACTION AUTHORITY** — a
   write attempted by a non-activated child **refuses**. ⭐ **Name the gate that
   refused, by module and function**, as `I1` did.
3. **A requested grant outside the parent's holdings REFUSES AT MINT, NAMING THE
   AXIS THAT FAILED.** ⛔ **At mint — not at use.** ⭐ *An enumerated refusal
   cannot be an incidental one.*
4. ⭐⭐⭐ **THE CHILD'S PRIVATE KEY IS PRESENT IN THE CHILD WORKSPACE AND ABSENT
   FROM THE PARENT'S — ASSERTED, NOT ASSUMED.**

   ⛔⛔ **THIS IS AN ABSENCE ASSERTION AND IT IS THE ARM MOST LIKELY TO PASS
   VACUOUSLY.** ⇒ **"Not in the parent's workspace" and "I looked in the wrong
   place" are the same observation.**
   ⭐ **REQUIRED: a POSITIVE CONTROL on the search itself — run the identical
   search against the CHILD workspace, where the key IS, and show it FINDS it.
   Only then is the parent-side zero evidence.** ⚠️ **And read the control's
   result: a control that returns zero is not a control.**
   ⛔ *This week a survey nearly certified a live repo untouched on an instrument
   whose own positive control came back empty.*

5. ⭐⭐ **PRINT THE OUTCOMES AND SHOW THEY DIFFER** across the arms. ⛔ ***If two
   arms defined to differ produce the same result, the arms did not run.***
   ⚠️ *Read the outcome, never the label you gave it.*
6. **Lands as files with their own counts from the tree.**

## ⚠️ THE SANDBOX CANNOT SIGN — plan for it

**`node_signing_key` is MASKED in your fence, so `NodeIdentity.signing_context/0`
FAILS and no node-signed write can succeed.** ⇒ ⭐ **Use `opts[:signing_context]`
with fixture contexts and a fixture anchor — `I1`'s fixture is the worked
example, threaded `start_link/1` → `init/1`.**
⭐ ***"Tested against fixtures, one assertion needs a real anchor" beats "we
couldn't test it."*** ⛔ **If an assertion needs a real anchor, NAME IT AS OWED.**

⚠️ **Note the interaction with arm 4: the child key is a CEREMONY-MINTED
fixture key, not the masked node key. If you find yourself needing the node key,
something has drifted — STOP AND REPORT.**

## Suites

⛔ **Run `bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK; read the
`BEFORE` line.** ⭐ **Baseline is now `3506` — `I1` added one fixture and
accounted for it. ACCOUNT FOR YOUR OWN DELTA the same way.**
⚠️ **Two sandbox runs have disagreed historically — `3505/2` vs `3505/0`
(`chat_view_compute_supervisor_test.exs`); filed `CX-s9kc`, non-deterministic,
NOT yours.** ⛔ **Anything else IS yours.**
⚠️ **In a fresh worktree `mix format --check-formatted` exits `rc=1` with
"Unknown dependency :phoenix" — the SAME CODE as "files are not formatted".**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐ **Verify by RE-READ, not by the write returning.**
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES.**
- ⭐ **Report the NEAR-MISS** — especially any temptation to satisfy arm 4 by
  looking somewhere convenient, or to build step 5.
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?** *`I1`
  was modelled on `Trust.SubtreeCarveTest`; if you model on `I1`, say so — the
  parent is what the next copy gets made from.*

## Review criteria

The double mint demonstrated before the fix; idempotence resolving to one id or a
named conflict; a non-activated child's write refused with the gate named; an
over-broad grant refused AT MINT naming the axis; and the key-absence arm carrying
a positive control that was itself read.
