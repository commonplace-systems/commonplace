# I1 build brief: the identity root, and its write gate as a SCOPE

> **Ticket/row: `I1`** of the §14 identity slice
> (`commonplace-plan:docs/plans/2026-08-15-identity-slice-decomposition.md`).
> Base: **the commit that adds this brief** — ⚠️ *not a sha.*
>
> ⛔⛔ **THIS IS A COMPONENT LANDING, NOT THE SLICE.** **NO ROUND PUBLISHES A
> "SLICE WORKS" CLAIM UNTIL `I5` RUNS.** *`I5` is the two-deployment proof and it
> is not yours.* ⭐ *A component landing that reads as the slice is the failure
> the cell ladder exists to prevent.*

## Build

**The `__identities/<name>.json` root extension from §2:**
- **`genesis`** — immutable: `created_by`, `birth_commit`, `activation`,
  `class_ref`
- **the `records` DocRef map**
- **exactly ONE governed record to prove the shape: `understanding`**, chosen
  because it is the child-writable one.

## ⛔⛔ THE GATE IS THE POINT, NOT THE SCHEMA

**Per finding 2: the child's inability to edit its own charter must be CERT
SCOPE, not a record-type check in identity code.** ⇒ ⭐ **A write gate that can be
expressed as a scope MUST be one, or it becomes a second authority system beside
the certs.**

⛔ **NO NEW AUTHORITY CODE. A diff introducing a record-type permission check
FAILS THIS ROUND ON ITS FACE.**

## ⭐⭐ AND HERE IS WHY THAT IS ACHIEVABLE — the schema choice DECIDES it

**Verified in the tree before briefing: the cert layer already understands
`{:subtree, root_uuid}` scope** (`apps/commonplace/lib/commonplace/trust/capability.ex`,
plus `verify_chain.ex` and `read.ex`).

⇒ ⭐⭐ **BECAUSE `records` IS A **DocRef** MAP, EACH RECORD IS ITS OWN DOC WITH ITS
OWN UUID — SO "SCOPE TO A RECORD" *IS* "SCOPE TO A DOC SUBTREE", WHICH THE
EXISTING GATE ALREADY EXPRESSES.** ✅ *That is what makes "no new authority code"
reachable rather than aspirational.*

⛔⛔ **THE TRAP, AND IT IS THE ONE PLAN SAYS FAILS ON ITS FACE: IF YOU MODEL THE
RECORDS AS FIELDS INSIDE ONE DOCUMENT, NO SUBTREE SCOPE CAN DISTINGUISH THEM AND
YOU WILL BE *FORCED* INTO A RECORD-TYPE CHECK.** ⇒ ⭐ **The schema decision and
the "no new authority code" constraint are THE SAME DECISION.** ⚠️ *If you find
yourself needing a record-type check, that is the signal your DocRef modelling
went wrong — STOP AND REPORT rather than adding the check.*

## ⛔ Acceptance — all artifact-checkable

1. **A child cert scoped to `records.understanding` WRITES it** — lands,
   **verified by RE-READ**, not by the write returning.
2. ⭐⭐ **The SAME cert attempting `records.charter` is REFUSED BY THE EXISTING
   GATE, and the refusal NAMES SCOPE.** ⛔ **Same cert — not a second, weaker
   one. A different cert proves nothing about scope.**
3. ⭐⭐⭐ **THE FIXTURE MUST *ATTEMPT* THE FORBIDDEN EDIT** — §15's formulation,
   which is stronger than "the check goes red". ⇒ ⛔ ***A check can go red for
   reasons unrelated to the invariant it guards*** — *measured this week: a
   red-first arm that was actually a PARSE FAILURE, and a stale-arm that was
   actually a formatter crash.* ⭐ **The refusal must name the scope and the
   attempted path, so an enumerated refusal cannot be an incidental one.**
4. ⛔ **NO NEW AUTHORITY CODE** — see above. **State plainly which existing gate
   refused you, by module and function.**
5. ⭐⭐ **PRINT BOTH ARMS' OUTCOMES AND SHOW THEY DIFFER.** ⛔ ***If two arms
   defined to differ produce the same result, the arms did not run.*** ⚠️ *Days
   old: three arms silently ran the same check via a mistyped env var and all
   returned 0; and an arm LABELLED "fresh" returned 1, nearly hiding a live stale
   artifact behind three passing labels.* ⇒ **Read the outcome, never the label
   you gave it.**
6. **Lands as files with their own counts from the tree.**

## ⚠️ THE SANDBOX CANNOT SIGN — plan for it, do not discover it

**Standing property: `node_signing_key` is MASKED in your fence, so
`NodeIdentity.signing_context/0` FAILS and NO node-signed write can succeed
there.** ⇒ ⛔ **A cert round that assumes ambient node signing will produce a
confident wrong diagnosis ("signing is broken"), not a stuck run.**

⭐ **USE THE INJECTABLE SEAM THE CODEBASE ALREADY HAS: `opts[:signing_context]`,
threaded through `start_link/1` → `init/1` (Bursar and `Frontier.Server` are the
worked examples).** ⇒ **Fixture context + fixture anchor.**
⭐ ***"Tested against fixtures, one assertion needs a real anchor" beats "we
couldn't test it."*** ⛔ **If an assertion genuinely needs a real anchor, NAME IT
AS OWED — the reviewer runs it outside.**

## Suites

⛔ **Run `bin/cp-suite-baseline apps/commonplace`; report ITS BLOCK; read the
`BEFORE` line.** `host DIRTY 3505/0` · `host CLEAN 3505/0`, seed 117514.
⚠️ **Two sandbox runs disagree — one `3505/2`
(`chat_view_compute_supervisor_test.exs` `:172`, `:143`), the next `3505/0`;
filed `CX-s9kc`, non-deterministic, NOT yours.** ⛔ **Anything else IS yours.**
⚠️ **In a fresh worktree `mix format --check-formatted` exits `rc=1` with
"Unknown dependency :phoenix" — the SAME CODE as "files are not formatted".**
⇒ **Never branch on `rc` alone: a real format failure LISTS FILE PATHS.**

## ⛔ Standing discipline

- ⛔ **Never a commit** — `.git` is read-only. **No live-store contact, no serve
  contact.** *Live store: `/home/jes/commonplace/workspace/.commonplace/commits/`
  — workspace-relative, NOT repo-root, NOT `data/`.*
- ⛔ **Do not run tree-wide `mix format` or `mix precommit`.**
- ⭐ **Verify by RE-READ, not by the write returning** — *this week a CLI printed
  a ticket id and exited 0 for a write that never landed.*
- ⭐⭐ **THIS BRIEF IS A CLAIM, NOT AN INSTRUCTION.** ⛔ **REPORT DISCREPANCIES
  rather than satisfying it** — *its author's last brief cited line numbers that
  had already moved.*
- ⭐⭐ **CITE BEHAVIOUR AND A GREP-ABLE STRING, NEVER A LINE NUMBER** — *in your
  report and in any comment you leave.* ⚠️ *The previous brief's line cites
  expired in under a day.*
- ⭐ **Report the NEAR-MISS** — especially any temptation to add a record-type
  check "just for this one case", or to prove scope with a second cert.
- ⭐⭐ **WHAT WAS THIS COPIED FROM, AND WHAT HAS BEEN COPIED FROM THIS?** *If you
  model this on an existing gate, say which — the parent is what the next copy
  gets made from.*

## Review criteria

The gate expressed as scope with no new authority code; the SAME cert used for
both arms; the forbidden edit ATTEMPTED rather than simulated; the refusal naming
scope and path; writes verified by re-read; and the records modelled as DocRefs
such that the existing subtree scope can distinguish them.
