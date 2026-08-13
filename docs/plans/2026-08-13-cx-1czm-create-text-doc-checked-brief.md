# CX-1czm build brief: route five callers through the checked variant that already exists

> **The work's ticket is CX-1czm**, ranked **#1** by commonplace-plan. Base:
> **`aa21f1e3`** on `main` — *re-derived at authoring time via
> `git ls-remote origin main`, not carried from the round that discovered
> this.*
>
> ⭐ **The rank's basis is not severity — it is that THIS TICKET IS THE ONLY
> THING KEEPING A LIVE MITIGATION IN FORCE.** Every writer on this box is
> currently told to **re-read after writing**, and that instruction stands
> only because five-of-six is not six-of-six. ⚠️ **A live advisory is a DEBT
> WITH A DECAY TERM: the window doesn't close when the mitigation is
> announced, it closes when the mitigation becomes UNNECESSARY — and the day
> it silently stops being followed is invisible.**

## ⭐⭐ The remedy already exists, is documented, and is partially adopted

`apps/commonplace/lib/commonplace/bd/schemas.ex`:

```
:536  def create_text_doc(json, store, opts)          # discards the store's answer
:553  def create_text_doc_checked(json, store, opts)  # KEEPS it — {:ok, uuid} | {:error, reason}
```

**And `create_text_doc_checked/3`'s own docstring already states this
ticket, verbatim, from CX-xmsd layer 1:**

> *"`create_text_doc/3` discards that answer and hands back a uuid for a doc
> that may not exist; **every caller that reports success to someone else
> must use this one instead**."*

⛔⛔ **THE RULE WAS WRITTEN, THE SAFE FUNCTION WAS BUILT, AND FIVE CALLERS DO
NOT FOLLOW IT** — including two in the same file as callers that do
(`issue.ex:370`/`:376` already use the checked variant).

⭐ **That partial adoption is the hazard, not an accident: THE REMEDY'S
EXISTENCE IS EVIDENCE FOR SAFETY THAT THE UNCHECKED CALLSITES MAKE FALSE.** A
reader sampling `issue.ex:370` concludes the codebase handles this.
⇒ ⭐ **A WRITTEN RULE WITH AN UNENUMERATED CALLER LIST IS A RULE NOBODY CAN BE
FOUND TO HAVE BROKEN.** **This round enumerates it.**

## The five callers — the table, enumerated and verified by callee

| # | site | binds to | then |
|---|---|---|---|
| 1 | `bd/issue.ex:336` | `issue_meta_uuid` | ⛔ **the live hole** — reported success via `create/5` |
| 2 | `bd/issue.ex:337` | `desc_uuid` | ⛔ **the live hole** |
| 3 | `bd/frontier/server.ex:203` | `uuid` | `Schema.add_file(schema, filename, uuid)` → `create_chained_commit` |
| 4 | `bd/schemas.ex:674` | `meta_uuid` | `Schema.add_file(dir_doc, meta_filename, …)` |
| 5 | `bd/label.ex:85` | `label_uuid` | `Schema.add_file(dir_doc, "label.json", …)` → `create_commit` → returns `dir_uuid` |

⚠️ **All five register a document that may never have landed, then hand a
uuid onward as if it had.** ⭐ **`label.ex:85` is the same two-step as
`issue.ex` and can mint an EMPTY LABEL DIRECTORY the way `:422` mints an
invisible ticket.**

⛔ **SEVERITY NOTE, plan's, and it belongs in the record: `frontier/server.ex:203`
IS THE FRONTIER DOC — the ready/blocked computation EVERY RANKING READS.**
⇒ **That is the third distinct path by which a denied write corrupts the
ranking instrument: a lost close reads as an open row, a lost create reads as
work nobody filed, and A LOST FRONTIER WRITE READS AS A DIFFERENT SET OF WORK
BEING READY.** **This round repairs an instrument, not only a store.**

⚠️ **NOT A CALLER, reported so you don't re-find it: `cell/manifest.ex:153`
calls that module's OWN private `create_text_doc/3` (defined at `:438`), not
`Schemas`'.** ⭐ **It already matches `{:ok, doc_uuid} <- …` and is fine.**
⇒ *A name-based enumeration is a superset whose surplus looks exactly like
the real thing — resolve each hit to its callee before counting it.*

## ⛔ The fix — small, and forbidden from growing

**Route all five through `create_text_doc_checked/3` and propagate the error
to the caller.** ⛔ **Do NOT change `create_text_doc/3` itself**; it has other
uses and changing a shared function is the larger, riskier round this one
replaced.

- ⛔ **No rescue, no retry, no queue. No gate change.** The denial is correct
  behaviour; only the reporting is wrong.
- ⚠️ **Preserve each caller's existing success shape.** `issue.ex` must keep
  returning `{:ok, issue, dir_uuid}`; `label.ex` its `dir_uuid`; and so on.
  ⛔ **Normalising return shapes is a redesign, not this fix.**
- ⭐ **Propagate through the intermediate** — `build_issue_dir` already
  returns `{:error, reason}` from `CX-9wy4`'s fix, so thread these the same
  way.

## ⭐ Acceptance

1. ⭐⭐ **RED FIRST, on the LIVE HOLE (rows 1–2): in an enforcing fixture, a
   ticket create whose DOCUMENT write is denied TODAY returns success while
   the document, its index entry, AND the parent link are all absent.**
   ⇒ **Assert all of it and report VERBATIM.** *This is the case the S24/S25
   index cannot see — measured `new_docs=[]`,
   `issue_doc_index_delta=[]`.*
2. **After the fix, each of the five returns a named error when its write is
   denied.** ⛔ **Per-row, not as a group** — ⭐ *a group verdict is one claim
   wearing five hats, and the day a sixth caller answers differently, a group
   verdict is what hides it.*
3. ⛔⛔ **A CONTROL THAT GOES RED BOTH WAYS: a PERMITTED create still succeeds
   AND still lands its schema entry**, for each row. *The cheap wrong fix
   propagates so faithfully that every create fails, and arm 2 cannot detect
   it.*
4. ⭐ **THE ARM THAT CLOSES THE MODULEDOC NOTE: with the fix in, is a
   document-denied create now DETECTABLE?** ⇒ **State whether
   `torn_create_detected` fires, or whether detection needs its own change —
   and say which.** ⚠️ `issue_doc_index.ex`'s moduledoc currently records that
   the index **cannot see document-denied orphans**, with this ticket as its
   closing condition. ⛔ **If your fix does not close it, SAY SO and leave the
   note** — *do not delete a limit you did not remove.*
5. **Tests LAND AS FILES with each file's own count from the tree.**

## Suites

Baseline, **falsifiable — measure your own and report it**: core
**3,479 / 0 failures / 1 skipped** @`aa21f1e3` **at seed 117514**.
⛔⛔ **REPORT THE SEED OF EVERY SUITE RUN.** ⚠️ *Two runs differing in code AND
order are not a comparison.*
⚠️ **`--seed 16421` reproduces UNRELATED failures whose population has moved
(`CX-g9ea`, now a lead rather than a handle). NOT YOURS.**
⛔ **Never pipe a long `mix test` — redirect to a file.**

## Files

- **MAY touch**: `bd/issue.ex` · `bd/frontier/server.ex` · `bd/schemas.ex` ·
  `bd/label.ex` · their tests.
- ⛔ **MUST NOT change**, verified present at this base:
  `runner/run_recipe.ex` (md5 `230839fc23e1047282306486ea48db41`) ·
  `runner/run_recipe_test.exs` (md5 `07c92ded3ac4668225fdff5eb3482602`) ·
  `command_router.ex` (the five-of-six fix landed at `aa21f1e3`) ·
  **`create_text_doc/3` itself** at `schemas.ex:536`.
- ⛔ **`sol-egress-run.sh` is never edited from inside a round.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. Produce the **intended commit
  message**. ⛔ **No live-store contact**; a live reproduction is explicitly
  not wanted.
- ⛔ **Do not run `mix format` or `mix precommit`.**
- ⛔ **If you cannot find this brief, STOP AND SAY SO.**
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** The table above was
  enumerated by grep and each hit resolved to its callee — **if a line number,
  a binding, or the count of five does not match the artifact, REPORT THE
  DISCREPANCY rather than satisfying the claim.** ⚠️ *Five wrong brief-facts
  this week were caught this way.*
- ⭐ **Report a MEASUREMENT, never a mechanism you did not observe**; name any
  failure's SUBJECT as `file:line`.
- ⭐ **Report the NEAR-MISS**, especially anything tempting you to change
  `create_text_doc/3` itself.

## Review criteria

All five routed and propagating; **per-row verdicts, not a group**; permitted
creates still succeed and still land their entries; the red shown first with
document, index entry and parent link all absent; the moduledoc note either
closed with evidence or explicitly left; `create_text_doc/3` unchanged; seeds
reported; counts reconciled against a self-measured baseline.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). ⚠️ Not reachable
from inside the sandbox — **a capability boundary, not a defect.** Report
identities; the reviewer files them.
