# S25 build brief: the issue-doc detector becomes a DECLARED MARKER, not a heuristic — S24's live false-positive fix

> Plan ruled this (msg 11387/@8531e13) from the live finding: S24's
> backfill `issue_doc?/2` typed issue docs BY SHAPE (any doc decoding to
> an Issue with non-empty id+created_at), and on the live serve that
> matched 257 comment docs (ids `c-XXXX`) and chat-message docs (v7-uuid
> ids) against 1 real orphan (CX-7cpf) — a 257:1 false-positive ratio.
> The going-forward create-time index marker is FINE (only real
> `Issue.create` sets it); this is purely the BACKFILL heuristic.
> ⭐ discriminator-before-brief is ALREADY SATISFIED — the live-run
> corpus (258 flagged, 1 real, sample comment/chat docs) IS the
> measurement; do not re-measure, fix against it.

## The ruled constraint (the whole design)

⭐ THE FIX IS A DECLARED FACT, NEVER A TIGHTER SHAPE. A stricter
heuristic (CX- id regex, more field checks) is the SAME DEFECT with a
smaller error rate — plan cites the rs binary-sniffing ruling as
already governing this family: key on WHAT ONLY `Issue.create` WRITES
(a declared fact), not on what an issue doc looks like.

1. GOING-FORWARD: the create-time index marker
   (`bd_issue_doc_created`, riding create's first commit) IS the
   declared fact. New tickets are correctly indexed by it — verify this
   path is untouched and remains the sole going-forward source.
2. ⭐ THE BACKFILL NEEDS THE HISTORIC EQUIVALENT: a declared fact that
   distinguishes a pre-S24 TICKET doc from a comment/chat doc WITHOUT
   shape-typing. Candidates to investigate (find the real one, don't
   assume): the doc's schema-entry NAME (`__issue.json` — a declared
   name only the issue-dir create writes), directory-membership as the
   declaration for the visible population, or a commit-metadata fact on
   the historic create path.
3. ⚠️ IF NO SUCH DECLARED FACT EXISTS FOR OLD DOCS — that is ITSELF the
   finding, and the ruled answer is a BOUNDED MANUAL REVIEW of the
   residue, NOT an unbounded heuristic. STOP AND REPORT: enumerate the
   residue (issue-shaped-but-unmarked-and-unlinked docs), state its
   size, and hand it to the operator — CX-7cpf is a known member found
   by hand last night, so the residue is small and bounded. Do NOT
   invent a shape-heuristic to close it.

## Superseding the spurious rows (constraint 2)

The 257 spurious `{:bd_issue_doc, doc_uuid}` index rows the first
backfill wrote for comment/chat docs are SUPERSEDED VISIBLY on the
re-run — the correction is itself recorded, never a silent removal.
Design how: a re-backfill under the corrected declaration writes a
superseding record / the scan's declaration-check excludes them with a
recorded reason. State the mechanism; the 257 rows are append-only and
harmless (they never touched the directory/VISIBLE) but must not
silently vanish.

## ⛔ Escape hatches, up front

- The historic-declared-fact question above: if none exists, STOP and
  report the residue for bounded manual review — do NOT ship a
  shape-heuristic as the "fix."
- If tightening the going-forward path is even touched — it is CORRECT,
  leave it; the defect is backfill-only.

## Tests (the live corpus is the red-first)

- RED-FIRST reproduction of the false-positive class: a fixture with a
  comment doc (id `c-XXXX`) and a chat-message doc alongside a real
  issue doc → the OLD `issue_doc?/2` flags all three; the NEW
  declared-fact detector flags only the issue doc.
- CX-7cpf-shape (a real marked/declared issue doc, unlinked) is still
  found — the fix must not lose the one true orphan while dropping the
  257 false ones.
- Going-forward: a freshly created ticket is indexed by its marker and
  the detector agrees; a freshly created comment/chat doc is NOT.
- Supersession: after the corrected re-backfill, the scan returns only
  genuinely torn issue docs; assert the spurious-row correction is
  recorded (not silently gone).

## Gates

bd/issue-doc-index + bd/workspace + the create/comment paths' test
files, then FULL core suite (mix test apps/commonplace/test) + `mix
compile --warnings-as-errors`; counts reported. Tmp stores only. The
LIVE re-backfill + re-scan against the serve is the OPERATOR's daylight
step (UNVERIFIED-in-sandbox). sol-run.log is the OPERATOR'S artifact —
never delete it; no repo-wide formatting; work UNCOMMITTED.

## Deliverable

Report: the historic declared fact used (or the residue report if none
exists), the going-forward path confirmed untouched, the false-positive
red-first verbatim, the CX-7cpf-still-found arm, the supersession
mechanism, test counts, the live re-run named UNVERIFIED, deviations.
