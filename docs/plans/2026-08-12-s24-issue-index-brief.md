# S24 build brief (re-briefed per plan's reshape): the create-time issue-doc index — detection and recovery as ONE mechanism

> Supersedes the stage-1 scan brief (2026-08-11-s24-orphan-scan-brief.md),
> which hatch-stopped correctly: an orphan is unreachable through every
> cheap index BY DEFINITION, so the instrument's precondition must be
> CREATED at create time. Plan ruled the five constraints inline
> (@2604121) — this brief is their transcription. The measured driver:
> ticket create is two uncoupled commits (issue doc, then the
> issues-directory entry); a timeout OR crash between them mints a
> well-formed but invisible ticket (live instances CX-7cpf + one pin
> orphan). CX-0mns's data-integrity face.

## The referents (state these at the module doc — they are the whole design)

- ⭐ THE INDEX records **CREATED** — written atomically with the issue
  doc. "This doc was minted as a ticket."
- ⭐ THE DIRECTORY records **VISIBLE** — the schema link. "This ticket
  appears in listings." UNCHANGED as the listing authority.
- These are DIFFERENT QUESTIONS. This is NOT the dual-write family the
  tix migration rejected: the index is never authoritative for "exists
  as a ticket," the directory stays the listing, and the invariant
  index ⊇ directory-issues is checkable. ⭐ THEIR DIFFERENCE IS THE
  RECOVERY QUEUE — the WAL/CX-z0sa shape in-store: an intent record
  whose reconciliation against the outcome record IS the torn-state
  detector.

## The five ruled constraints (transcribe exactly)

1. ⭐ THE INDEX ENTRY RIDES IN THE CREATE'S FIRST COMMIT — the same
   commit that writes the issue doc, NEVER a third write. A separate
   index write could itself tear; riding commit-1 means the index can
   never be more torn than the doc it records.
2. The index is an APPEND-ONLY INTENT RECORD, never authoritative for
   "exists as a ticket." The directory stays the listing. Referents
   named at the module doc (constraint above).
3. The scan is INDEX-MINUS-DIRECTORY (issue-doc-ids in the index, minus
   the ids the issues-directory links). ⭐ OPEN CHOICE (yours to decide
   and state the basis): when the scan runs — list-time, on a cadence,
   or on demand. Pick one with a stated reason; do not build all three.
4. The BACKFILL is ONE-TIME, THROUGH THE GATED PATH, with declared-
   denominator discipline: LANDED ∪ REFUSED == input (the importer
   family). Every existing issue doc is either indexed or its refusal
   is named; no silent drop. ⚠️ The backfill RUN against the live serve
   is the OPERATOR's daylight step — build it + a fixture backfill test,
   name the live run UNVERIFIED-in-sandbox.
5. ⛔ RECOVERY NEVER AUTO-COMPLETES SILENTLY. A torn create's
   completion (linking the orphan into the directory) is a VISIBLE ACT
   — manual or verb-gated, until the mechanism has earned trust. v1
   surfaces the torn list LOUDLY; it does not quietly finish the link.
   (Tonight's no-hand-repair discipline, mechanized.)

## ⛔ Escape hatches, up front

- If riding the index entry in create's first commit is not possible
  because the issue doc and its index live in different stores/commit
  streams with no shared atomic write — STOP AND REPORT the seam. The
  whole design rests on constraint 1.
- If the index needs a new durable record shape beyond a
  {doc_uuid → true}-style append entry — that is plan's, stop.
- If backfill enumeration requires the whole-store walk the stage-1
  brief forbade — the backfill is ONE-TIME and operator-run, so a
  bounded one-shot walk IS acceptable HERE (unlike a standing
  instrument); but say so explicitly and bound it.

## Tests (red-first where behavior exists)

- ⭐ TORN-CREATE ARM (the mechanism's reason to exist): create an issue
  doc's commit-1 (with the index entry) but DO NOT complete the
  directory link (mirror the timeout). Assert: the index HAS it, the
  directory does NOT, and index-minus-directory returns exactly it.
  This is the CX-7cpf shape as a fixture — the positive control the
  stage-1 scan couldn't have without the index.
- Clean create: doc + index + directory all present; scan returns [].
  (Paired with the torn arm so [] is falsifiable.)
- Invariant: index ⊇ directory-issues after any sequence of
  clean creates.
- Backfill fixture: a store with pre-index issue docs (some linked,
  some orphaned) → backfill indexes all, LANDED∪REFUSED==input asserted,
  no silent drop; the orphaned ones then show in index-minus-directory.
- Recovery is a visible act: assert there is NO code path that
  auto-links an orphan; the torn list is surfaced, completion is
  separate and gated.

## Gates

bd/workspace + view-action-dispatch (the create path) + the new index
+ scan test files, then FULL core suite (mix test apps/commonplace/test)
+ `mix compile --warnings-as-errors`; counts reported. Tmp stores only.
sol-run.log is the OPERATOR'S artifact — never delete it; no repo-wide
formatting; work UNCOMMITTED.

## Deliverable

Report: the index record shape + where its entry rides in create, the
scan-timing choice + basis, the torn-create arm verbatim, the backfill
reconciliation, the no-auto-complete assertion, test counts, the live
backfill run named UNVERIFIED, deviations.
