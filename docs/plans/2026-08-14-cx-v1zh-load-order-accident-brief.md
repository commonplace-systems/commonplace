# CX-v1zh build brief: make ONE accidental protection's removal noisy

> **The work's ticket is CX-v1zh.** Base: **`6ce2f90e`** on `main`, re-derived
> at authoring time via `git ls-remote`.
>
> ⛔⛔ **ONE INSTANCE THIS ROUND, THEN STOP AND REPORT.** Plan ruled this
> explicitly. ⚠️ **Do not build the other two even if they look easy once the
> first is done** — *a guard that lands before its question is asked can
> foreclose a better fix by removing the symptom that would have motivated it.*
>
> ⭐ **The class: a safety property that holds BY ACCIDENT expires QUIETLY,
> WITH NO EVENT.** Three such properties are currently load-bearing here and
> none has a test.

## ⭐⭐ The instance, and its premise MOVED between filing and briefing

**Take the LOAD-ORDER accident: `Commonplace.Trust` cannot be hot-swapped by a
probe.**

⚠️ **The ticket says that holds because the module was ALREADY LOADED while
its beam was NEWER than the serve's start. Re-derived today, that is no longer
why:**

```
filed 2026-08-13    "Trust is in the newer-than-serve-start set,
                     and cannot be hot-swapped because something loaded it first"
measured 2026-08-14  WOULD-DEPLOY-ON-RESTART: 0 beam(s)   ← the newer set is EMPTY
                     Commonplace.Trust resident: true      (:code.is_loaded/1)
```

⇒ ⭐⭐ **THE PROPERTY SURVIVED AND ITS CAUSE WAS SWAPPED OUT UNDERNEATH IT:**

| when | "Trust can't be hot-swapped" | because |
|---|---|---|
| 2026-08-13 | **TRUE** | it was **already loaded** |
| 2026-08-14 | **TRUE** | **nothing newer exists** — a deploy emptied the set |
| after the next compile-without-restart | ⛔ **FALSE** | — |

⛔ **Same property, three reasons, ZERO EVENTS. Every check OF THE PROPERTY
stays green across all three rows** — which is exactly why *"it still holds"*
was never evidence that anything was safe.
⭐ **And this is not a hypothetical: a deploy landed between the filing and
this brief and nobody predicted it would falsify the premise.** ⇒ **You are
building a detector for something we can currently demonstrate rather than
argue.**

## ⛔ What to build — and what NOT to

**A check that FAILS when the accidental protection goes away.**

- ⛔ **NOT "document it."** ⛔ **NOT "harden it."** ⛔ **NOT "load everything at
  boot"** — *that converts a lazy partial deploy into an eager full one, which
  is a deploy, not a fix (the ticket says so).*
- ⭐ **The property to assert is the one that can change silently: THE SET OF
  BEAMS NEWER THAN THE RUNNING SERVE'S START.** ⇒ *When it is empty, no lazy
  load can deploy unbuilt code. When it is non-empty, any incidental load is an
  unplanned partial deploy — and today it is EMPTY only because of a restart
  nobody will remember.*
- ⚠️ **`bin/cp-deploy-gap` already computes this number.** ⛔ **It is
  PULL-ONLY — someone must think to run it.** ⭐ **The deliverable is that the
  number's going non-zero becomes NOISY without being asked.** *Where that
  noise lands — a boot assertion, a CI step, a periodic check — is your call;
  say which and why.*

## ⭐ Acceptance — and arm 1 is the round

1. ⭐⭐ **RED-FIRST BY DELIBERATE PERTURBATION, AGAINST A SCRATCH COPY:
   make the protection go away and watch the check FAIL, then restore it and
   watch it pass. REPORT BOTH VERBATIM.**
   ⚠️ **This exact perturbation is already known to work: touching one beam
   moved `cp-deploy-gap` 0 → 1, and restoring its mtime moved it back**
   (measured 2026-08-13 21:28Z). ⭐ **Capture the original mtime FIRST.**
   ⛔ **A check that has only ever been seen green is the species this ticket
   is about.**
2. **The failure names WHICH beams are newer** — ⚠️ *a check that says "the gap
   is non-zero" without saying what costs the next person the enumeration.*
3. ⛔ **DO NOT PERTURB THE LIVE SERVE.** ⚠️ *Its module set is the subject; a
   probe that loads a module makes the finding true by making it happen.*
   ⭐ **If you read a live node at all, `:code.is_loaded/1` ONLY** — never
   `Code.ensure_loaded?/1` or `module_info/1`, **both of which AUTO-LOAD.**
   ⭐ **And self-check: `:code.all_loaded` count before and after; report the
   delta.** *(Mine was 701 → 701, delta 0.)*
4. **The test LANDS AS A FILE with its own count reported from the tree.**

## ⛔ Then STOP

**Report and stop. Do not start the other two instances** — the sandbox
PID-namespace one and the `bin/bd`/missing-Dolt-DB one. ⭐ **Say what you
learned that would change how they should be done**, especially whether the
mechanism you built generalises or was specific to this property.

## Files

- **MAY touch**: a new test file · `bin/cp-deploy-gap` **only if** the noise
  belongs there and you say why.
- ⛔ **MUST NOT change**, verified present at this base:
  `runner/run_recipe.ex` (md5 `230839fc23e1047282306486ea48db41`) ·
  `runner/run_recipe_test.exs` (md5 `07c92ded3ac4668225fdff5eb3482602`) ·
  `bd/schemas.ex` · `command_router.ex` ·
  `test/commonplace/bd/create_text_doc_unchecked_callers_test.exs`.
- ⛔ **`sol-egress-run.sh` is never edited from inside a round** — and ⭐ **a
  test OF a fence is not an EDIT TO the fence: perturb a SCRATCH COPY.**

## Suites

Baseline, **falsifiable — measure your own**: core **3,492 / 0 failures /
1 skipped** @`6ce2f90e` **at seed 117514**. ⛔ **REPORT THE SEED OF EVERY RUN.**
⛔ **Never pipe a long `mix test` — redirect to a file.**
⚠️ **`--seed 16421` reproduces unrelated failures whose population has moved
(`CX-g9ea`). NOT YOURS.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. Produce the **intended commit
  message**. ⛔ **No live-store contact.**
- ⛔ **Do not run `mix format` or `mix precommit`.**
- ⛔ **If you cannot find this brief, STOP AND SAY SO.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION**, and this one has already
  been wrong once: **the ticket's own premise was stale by a day.** ⛔ **If the
  gap number, the resident state, or the line numbers do not match the
  artifact, REPORT THE DISCREPANCY.** ⚠️ *Seven brief-facts were wrong this
  week; every one was caught by the builder.*
- ⭐ **Report a MEASUREMENT, never a mechanism you did not observe**; name any
  failure's SUBJECT as `file:line`.
- ⭐ **Report the NEAR-MISS**, especially anything tempting you to start
  instance 2 or 3.

## Review criteria

One instance only; red demonstrated by deliberate perturbation of a scratch
copy with both outputs verbatim; the failure names which beams; no live-serve
perturbation and the `all_loaded` delta reported if a live node was read at
all; seed reported; the other two instances untouched with a note on what
would change about them.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). ⚠️ Not reachable
from inside the sandbox — **a capability boundary, not a defect.**
