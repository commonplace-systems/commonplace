# S25b micro-brief: the torn-create scan reports its own COVERAGE — plan's report-your-coverage pattern (msg 11402 ①)

> Plan ruled this from the S25 live run: the re-scan returned `[]` and
> the emptiness was TRUE for post-marker docs but VACUOUS for pre-S24
> orphans — a torn create by definition never wrote its `__issue.json`
> declaration, and pre-S24 docs have no creation marker, so the
> declared-facts detector cannot see a pre-marker orphan BY
> CONSTRUCTION. CX-7cpf's own doc was superseded along with the 257
> spurious rows (258 total), and the one real orphan was recovered only
> by bounded manual review of the superseded set. Plan's ruling: THE
> TRUTH BELONGS WHERE THE READER IS — the scan's own output carries its
> coverage, with the moduledoc line as the maintainer-facing statement
> of the same fact. Same defect shape as the same-morning CubDB
> integrity-probe line ("healthy" from a partial scan): a report must
> state what it scanned, not just what it found.

## The change (small by design)

1. `ticket_torn_creates`' payload (ViewActionDispatch) gains coverage
   fields alongside `torn_creates`. The claim it must make, in data:
   the result covers DECLARED docs only (creation marker or historic
   `__issue.json` declaration); docs with neither declaration are
   structurally outside this instrument; the recorded supersession set
   is the reviewable residue. Suggested shape (names yours, meaning
   fixed):
   - `covered`: count of effective CREATED entries (post-supersession)
   - `outside_coverage`: count of recorded supersessions, with the
     standing sentence that their instrument is manual review of the
     superseded set, not this scan
   - keep the existing `auto_link: false` + warning line untouched.
2. `IssueDocIndex` moduledoc gains the maintainer-facing line: a
   pre-marker orphan is invisible to declared facts by construction;
   its instrument is manual review of `supersessions/1`.
3. All numbers come from reads the module already does cheaply
   (`entries/1`, `supersessions/1`). The scan stays read-only and
   on-demand — zero writes, no new walks.

## ⛔ Escape hatches, up front

- If a coverage number would require a whole-store walk or any
  non-cheap enumeration, STOP and report — the coverage line must not
  buy the scan a scan.
- The scan's result semantics, the backfill, and the going-forward
  marker path are all CORRECT — do not touch them. This is
  output-shape + doc truth only.

## Tests (red-first)

- RED-FIRST: assert the dispatch payload carries the coverage fields
  with values sourced FROM THE STORE (seed a supersession, expect it
  counted) — fails against current output by construction.
- Coexistence arm: a torn-create fixture (the S25 suite already has
  one) asserts a NON-EMPTY `torn_creates` still carries the coverage
  fields — coverage is unconditional, not an empty-result apology.
- Zero-supersession arm: fresh store reports `outside_coverage: 0` —
  the line can say "full coverage" and mean it.
- Existing S24/S25 suites stay green untouched; full core counts
  reported.

## Review criteria

Coverage values measured-not-hardcoded; payload names state the claim
(a reader who never opens the module understands what `[]` does and
does not mean); moduledoc line present; scan still performs zero
writes; red-first transcript included.
