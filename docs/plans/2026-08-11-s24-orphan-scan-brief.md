# S24 stage 1 build brief: the orphan-ticket scan — the instrument before the recovery

> Plan ranked this ABOVE the time-budget arc (msg 11335) on a different
> basis: a mechanism that mints well-formed INVISIBLE tickets makes the
> intake surface lie by omission, attacking the queue-owner function
> itself. This is STAGE 1 — the INSTRUMENT — because instruments outrank
> the investigations that need them, and this scan is the precondition
> for both the recovery design (stage 2) and tomorrow's orphan repair.
> The measured instance: CX-7cpf (doc 252c2df9), a well-formed issue
> with an assigned ID that no listing sees because the dir-link commit
> timed out. Ticket create is TWO commits (issue doc, then the
> issues-directory entry) with NO coupling — the timeout merely EXPOSED
> the non-atomicity; a crash between the two commits orphans identically.

## What "orphan" means, precisely (build the scan from this)

An orphan is a doc that IS a well-formed bd issue (its content parses as
an Issue: has `id`, `created_at`, the issue field shape) but whose
`node_id` appears in NO entry of the issues-directory schema — so
`Bd.Workspace.list_issue_entries` and every listing that resolves
through the directory cannot see it. The directory (root → bd →
issues-dir schema) is the authority for "which tickets exist"; a doc
not linked there is real bytes nobody can find by ID.

## The scan (Sol-shaped, one query — MEASUREMENT, not a fix)

1. Enumerate candidate issue docs. ⛔ Escape hatch UP FRONT: if there is
   no store-level way to enumerate docs-that-look-like-issues WITHOUT
   walking every doc in the store (expensive — the store is ~thousands
   of docs), STOP AND REPORT the seam you'd need. A cheap enumeration
   likely rides an existing index (doc-commit index, or issue-doc
   naming) — find it or report its absence; do NOT build a whole-store
   walk as the standing instrument (that is its own tj6b-adjacent
   cost).
2. For each candidate, check membership in the issues-directory schema's
   entry set (the authority). Orphan = well-formed-issue AND
   not-in-directory.
3. Deliverable: a function `Bd.Orphans.scan/2` (name yours) returning
   the orphan list as `{id, doc_uuid, created_at}` — IDENTITIES, never
   a count alone; the list IS the repair tool's input.
4. ⛔ ZERO WRITES. This round reads only. It does not link, refile, or
   GC anything — that is stage 2 / the operator's repair. A scan that
   mutates is not an instrument.

## ⭐ The positive control (this scan MUST be able to find a real orphan)

CX-7cpf (doc 252c2df9-5caf-470d-9e51-fb24bbb9c289) is a KNOWN live
orphan on the serve — but the sandbox can't reach the serve, so build
the control in a fixture: create an issue doc, DO NOT link it in the
directory (mirror the torn create), and assert the scan finds exactly
it; link a second issue normally and assert the scan does NOT flag it.
A scan that returns [] must be provably able to return non-[] — an
empty result is only meaningful against a control that would have shown
a plant. (The checks-that-cannot-fail rule.)

## Tests

- Fixture control above (orphan found, linked-issue not flagged).
- A store with zero orphans → [] AND the control-plant variant → [plant]
  in the same test module (empty is VOID without the paired non-empty).
- Reconciliation: if the enumeration and the directory are both
  available, orphans = well-formed-issue-docs MINUS directory-linked —
  assert the set arithmetic, don't trust a hand-filter.

## Gates

bd/workspace + the new scan test file, then FULL core suite (mix test
apps/commonplace/test) + `mix compile --warnings-as-errors`; counts
reported. Tmp stores only. sol-run.log is the OPERATOR'S artifact —
never delete it; no repo-wide formatting; work UNCOMMITTED.

## Deliverable

Report: the enumeration seam used (or the escape-hatch report if none
cheap), the scan function shape, the positive-control evidence (plant
found, linked not flagged), test counts, deviations. The LIVE run
against the serve (finding CX-7cpf + the pin orphan) is the OPERATOR's,
named UNVERIFIED-in-sandbox.

## Not in this brief (stage 2, plan msg 11335)

The create becomes ordered-with-recovery (doc → link, the scan a
standing tripwire making torn state LOUD — the fadm torn-state family);
the open choice of boot vs cadence vs list-time scan. Stage 2 is
authored after stage 1's instrument lands.
