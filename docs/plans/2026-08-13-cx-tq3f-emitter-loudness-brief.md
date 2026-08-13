# CX-tq3f build brief: the emitter's failures must name their step

> **The work's ticket is CX-tq3f** (open, p1). Base: **`38691b25`** on
> `main`. ⚠️ **`CX-d81c` was its duplicate and is closed** — this is the
> surviving row, and it survived the S50 reconciliation **on a live
> symptom**, not on a title.
>
> ⭐ **The symptom, from the cell-demo evidence doc
> (`df7df185:48-60`): the pin lands, and the emitter still prints**
> ```
> proto-chit: emission failed: :error
> ```
> ⇒ **A bare `:error` names no step, no cause, and no remedy. It is the
> least informative possible non-crash.**

## Where it comes from — structural, and you should confirm it

`Commonplace.ProtoChit.emit/3`
(`apps/commonplace/lib/commonplace/proto_chit.ex:29`) is a **`with`
chain of 15 steps that has NO `else` clause.**

⇒ **Any step returning something other than its matched pattern is
returned VERBATIM to the caller.** A step that answers a bare `:error`
makes `emit/3` answer a bare `:error`. The CLI
(`apps/commonplace_cli/lib/commonplace/cli/proto_chit.ex:57`) then hits
its catch-all `other -> fail(other)` and prints it.

⭐ **So the information is not lost in formatting — IT NEVER EXISTED.**
The value crossing the module boundary already carries nothing.
⚠️ **`annotate/5` (:54) has the same shape. Check it.**

⛔ **DO NOT TAKE THE ABOVE AS THE FINDING — CONFIRM IT AND REPORT WHICH
STEP ACTUALLY PRODUCES THE BARE `:error` TODAY.** Report a
**measurement**, not a mechanism you inherited from this brief. ⚠️ *If
the origin is somewhere else entirely, that is the finding and I want
it.*

## The property to build

**Every failure leaving `emit/3` and `annotate/5` names the step that
produced it and carries that step's own value.**

- ⛔ **NEVER INVENT A REASON.** If a callee genuinely answers a bare
  `:error`, the honest result is a wrap that **names the step and
  preserves the opaque value** — e.g. `{:error, {:cut_pin, :error}}`.
  ⭐ **"cut_pin failed and would not say why" is a true and useful
  sentence; a manufactured cause is neither.**
- ⛔ **Do not "fix" the callee's silence by guessing at it.** If a step
  should be able to say more, **that is a FINDING to report** — a
  second ticket, not this round's change.
- **The CLI's catch-all stays** as a backstop, but a value reaching it
  should be **describable as unstructured** rather than printed bare.
- ⛔ **The SUCCESS path must not change.** No new output, no changed
  exit codes, no reordering of the chain.

## ⭐ Acceptance: red-first, and the red is already sitting there

- ⭐⭐ **RED FIRST, BY THE REAL SYMPTOM: write the test that asserts a
  named step BEFORE the fix, and show it failing with the bare
  `:error`.** ⇒ **Report both outputs.** *This round is unusually well
  set up for it — the defect is reproducible and the current message is
  known verbatim.*
- **Force a failure at more than one step** and show each names itself.
  ⚠️ **A single arm proves the wrapper you added on that one line**; two
  arms prove the property. **Say how many you covered and which.**
- **Assert on the message CONTENT** — the step name and the preserved
  value — **not merely that stderr was non-empty.**
- **Tests LAND AS FILES and each file's own count is reported from the
  tree.** ⭐ **An existing test file is a fine home** — the property is
  *exists AND executes*, and a new file was never the requirement.

## ⚠️ Blast radius — name suites by what you TOUCHED, not by where you edited

`proto_chit.ex` exists in **core** and its CLI caller in
**commonplace_cli**. ⇒ **Both suites run, per-app:**

```
mix test apps/commonplace/test        # baseline 3,468 / 0 failures / 1 skipped @38691b25
mix test apps/commonplace_cli/test    # ⚠️ baseline NOT measured by me — measure it and report it
```
⚠️ **Multi-app `mix test A B` silently drops tests here — run them
separately.** ⚠️ **Both baselines are FALSIFIABLE CLAIMS: measure your
own and report any difference rather than adopting mine.**
⚠️ A worktree cannot host a suite run (no `deps/`, no `_build/`);
compile through writable copies and **report where you ran.**

## Files

- **MAY touch**: `apps/commonplace/lib/commonplace/proto_chit.ex` ·
  `apps/commonplace_cli/lib/commonplace/cli/proto_chit.ex` · their test
  files.
- ⛔ **MUST NOT change, pinned by md5**:
  `run_recipe.ex` = `230839fc23e1047282306486ea48db41`,
  `run_recipe_test.exs` = `07c92ded3ac4668225fdff5eb3482602`.
- ⛔ **`sol-egress-run.sh` is never edited from inside a round** — it is
  the mechanism that contains you.

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. Produce the **intended
  commit message**.
- ⛔ **Do not run `mix format` or `mix precommit`.** Use
  `mix format --check-formatted`.
- ⛔ **If you cannot find this brief, STOP AND SAY SO.**
- ⛔ **If a fenced capability is needed, NAME IT** rather than working
  around its absence — **a `0` from a probe may mean MASKED, not
  ABSENT.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** If a stated fact
  here does not match the artifact — the line numbers, the missing
  `else`, the symptom — ⛔ **report the discrepancy rather than
  satisfying the claim.** *Last round this brief's author asserted three
  of something and there were two; the builder's refusal to invent the
  third was the round's best moment.*
- ⭐ **Report the NEAR-MISS**, including anything that tempted you to
  invent a cause for a silent callee.

## Review criteria

The bare `:error` cannot survive to stderr; ≥2 failure arms each naming
their own step, asserted on content; red-first demonstrated with both
outputs reported; no invented causes; success path byte-identical in
behaviour; both suites reconciled per-app against their own measured
baselines.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). ⚠️ Not
reachable from inside the sandbox — **a capability boundary, not a
defect.** Report identities; the reviewer files them.
