# CX-3vgy build brief: make the caller rule enumerable — but ask the harder question first

> **The work's ticket is CX-3vgy.** Base: **`84475d91`** on `main` —
> re-derived via `git ls-remote origin main` at authoring time, and **for the
> first time today the deployed tree and the gated tree are the same object.**
>
> ⛔⛔ **THIS ROW PREVENTS A SEVENTH. IT FIXES NOTHING LIVE.** The
> discarded-return class has **no live victim**: zero callers of the unchecked
> variant remain (re-derived below). ⇒ **Do not treat this as urgent repair —
> treat it as the mechanism that keeps a true fact true.**

## ⭐⭐ ANSWER THIS BEFORE WRITING THE TEST

> **IS THERE A VERSION WHERE `Schemas.create_text_doc/3` SIMPLY STOPS
> EXISTING?**

⭐ **A remedy you must REMEMBER to call can only ever be "unreached-safe",
never "bound-safe".** ⇒ `create_text_doc_checked/3` is a function callers must
choose; **an enumeration test keeps *unreached* true, it cannot make skipping
impossible.** ⚠️ **If the unchecked variant can be deleted or made private,
adoption becomes STRUCTURAL rather than DISCIPLINARY, and this guard degrades
from the mechanism to a safety net.**

⛔⛔ **AND THE ORDER MATTERS FOR A REASON THIS REPO KEEPS RE-LEARNING: A GUARD
THAT LANDS FIRST CAN FORECLOSE THE BETTER FIX BY REMOVING THE SYMPTOM THAT
WOULD HAVE MOTIVATED IT.** ⇒ **State the answer with evidence, THEN build.**
⚠️ **Do not build both without saying whether the second makes the first
decoration.**
■ **If deletion is not affordable, say WHY with the blast radius measured** —
⛔ *"seems risky" is not an answer; `create_text_doc/3`'s remaining callers,
if any, are.* ⭐ **Either answer is publishable and "it can't go" is a
perfectly good one.**

## The facts, re-derived at authoring time (not carried)

```
schemas.ex:536  def create_text_doc/3          ← STILL DISCARDS ITS RETURN
schemas.ex:553  def create_text_doc_checked/3  ← keeps it

callers of the UNCHECKED variant:  0     ← the class is unreached, not bound
callsites of the CHECKED variant:  9
```

⚠️ **The `9` corrects something I said earlier and it makes the species
WORSE, not better.** I described the partial adoption as *"two callers in the
same file as two that do."* ⭐ **Measured: BEFORE S55 there were already FOUR
adopters across THREE files** — `issue.ex` (the deadline path, ×2),
`workspace.ex:89`, `comment.ex:182` — **against five non-adopters across four
files.**
⇒ ⭐⭐ **So a reader sampling for the rule had a 4-in-9 chance of landing on a
compliant callsite in a DIFFERENT file and concluding the codebase handled
it.** **The remedy's existence was evidence for safety across more of the tree
than I claimed.**
■ ⚠️ **`comment.ex:182` calls it inside a `guarded(fn -> … end)` wrapper.**
⇒ **The allowlist must be built BY CALLEE, not by call shape** — *a
shape-based scan misses this one and a name-based one over-counts (see
below).*
■ ⛔ **NOT A CALLER: `cell/manifest.ex:153` resolves to that module's OWN
private `create_text_doc/3` at `:438`.** ⭐ *A name-based enumeration is a
superset whose surplus looks exactly like the real thing.*

## What to build, if the answer above is "the variant stays"

**A test asserting the set of `Schemas.create_text_doc/3` callers equals an
explicit allowlist.** The allowlist at `84475d91` is **EMPTY**.

## ⭐ Acceptance — and arm 1 IS the row

1. ⭐⭐ **RED-FIRST BY ADDING A TEMPORARY UNCHECKED CALLER AND WATCHING THE
   TEST FAIL — then removing it and watching it pass. REPORT BOTH VERBATIM.**
   ⛔⛔ **A SOURCE-SCAN THAT PASSES ON TODAY'S TREE PROVES NOTHING: it passes
   identically whether it scans correctly or SCANS NOTHING.**
   ⚠️ *2026-08-13 produced four ancestors of exactly that vacuity — a `find`
   that was `bfs` printing `0` from an error sent to `/dev/null`; two
   orphan-sweep keyings comparing sets that could never intersect (one
   answering "0 orphans", one "962"); and a suite gate reporting `0 failures`
   because `0 tests ran`.* ⭐ **A guard whose own scan is vacuous is the same
   species it exists to stop.**
2. **The scan resolves each hit to its CALLEE**, so
   `cell/manifest.ex:153` does not appear and `comment.ex:182` does.
   ⇒ **Demonstrate both**: the false positive stays out, the wrapped call
   stays in.
3. **The failure message names the offending `file:line`** — ⚠️ *a guard that
   says "a caller appeared" without saying where costs the next person the
   enumeration you just built.*
4. **The test LANDS AS A FILE and its own count is reported from the tree.**

## Files

- **MAY touch**: a new test file · `bd/schemas.ex` **only if** the answer to
  the opening question is deletion/privatisation.
- ⛔ **MUST NOT change**, verified present at this base:
  `runner/run_recipe.ex` (md5 `230839fc23e1047282306486ea48db41`) ·
  `runner/run_recipe_test.exs` (md5 `07c92ded3ac4668225fdff5eb3482602`) ·
  `command_router.ex` · `bd/issue.ex` · `bd/label.ex` ·
  `bd/frontier/server.ex` — **the six-site fix landed at `aa21f1e3`/`84475d91`
  and this round does not re-open it.**
- ⛔ **`sol-egress-run.sh` is never edited from inside a round.**

## Suites

Baseline, **falsifiable — measure your own**: core **3,490 / 0 failures /
1 skipped** @`84475d91` **at seed 117514**.
⛔ **REPORT THE SEED OF EVERY RUN.** ⛔ **Never pipe a long `mix test` —
redirect to a file.**
⚠️ **`--seed 16421` reproduces unrelated failures whose population has moved
(`CX-g9ea`). NOT YOURS.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. Produce the **intended commit
  message**. ⛔ **No live-store contact.**
- ⛔ **Do not run `mix format` or `mix precommit`.**
- ⛔ **If you cannot find this brief, STOP AND SAY SO.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **And do not treat any
  number here as a target: if the caller counts, the line numbers, or the
  `0`/`9` do not match the artifact, REPORT THE DISCREPANCY.** ⚠️ *Last round
  this author demanded a measurement that was false, and only the builder
  refusing to produce it stopped the artifact from confirming the error.*
- ⭐ **Report the NEAR-MISS**, especially anything tempting you to delete the
  unchecked variant *to make the question go away* rather than because the
  blast radius supports it.

## Review criteria

The opening question answered with evidence before any test was written; if
the guard was built, **red demonstrated by an added caller and reported
verbatim**; callee-resolution shown in both directions; failure message names
`file:line`; no re-opening of the six-site fix; seed reported.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). ⚠️ Not reachable
from inside the sandbox — **a capability boundary, not a defect.**
