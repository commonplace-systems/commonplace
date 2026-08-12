# S29-DISC brief: the production time-budget seam census — CX-11ms (the deadline-propagation arc's measurement base)

> **The work's ticket is CX-11ms** (filed through the gated verb,
> live-store verified 2026-08-12). Any doc line citing a ticket cites
> CX-11ms — no other id. Context roles only, none of them the citation:
> CX-5gkw is the class ticket whose four test-side victims got sized
> budgets @5ca502c2; CX-7b53 is the Bursar nested-budget instance S18
> sized @93a3051b; CX-0mns is the production create-timeout that minted
> invisible tickets. This is a DISC round: **ZERO production changes.**
> The deliverable is a measured document; the arc's build rounds come
> after plan rules on it.

## The destination frame (plan msg 11298, transcribed — the census serves it, builds none of it)

Deadline propagation is the arc's adopted destination, under four ruled
constraints: (1) the deadline originates at the BOUNDARY; (2) REMAINING
time propagates, never the original figure; (3) mid-chain expiry is a
NAMED refusal saying WHICH SEAM exhausted it — per-layer budgets
accidentally gave layer-attribution and that must not be lost; (4)
propagation lands AT EXISTING BUDGET SEAMS — converge, don't smear.
Constraint (4) is why this census exists: you cannot converge onto
seams nobody has enumerated. Constraint (1) is why the census carries a
boundary-origin column: plan's build ruling needs to know where
deadlines can be born.

## The census

Sweep PRODUCTION code — every umbrella app's `lib/`, tests excluded —
for every fixed time budget:

- **Explicit literals**: `GenServer.call(_, _, timeout)`, `:erpc.call`
  with timeout, `Task.await`/`Task.yield`/`Task.await_many`,
  `receive ... after`, `:timer`-driven deadlines, `Process.send_after`
  where the message enforces a timeout, CubDB options, Req/HTTP
  timeouts (federation), `System.cmd` timeouts, anything else the sweep
  surfaces.
- ⭐ **The implicit-default class** — bare `GenServer.call/2` and
  friends carry an invisible 5000ms. A timeout-literal grep is
  STRUCTURALLY BLIND to these (this is the CX-0mns killer: nobody wrote
  "5000" anywhere near the orphan-minting create). Enumerate by CALL
  SITE, not by literal. State the method.

Per seam, one row: file:line · value (explicit or DEFAULT-5000 or
:infinity) · declared basis (the comment/commit that sized it, or NONE)
· what it bounds (single call vs a chain of budgeted calls) · nesting
(which budgeted seams execute BENEATH it — S18's inner-30s/outer-600s
arithmetic is the model of a stated nesting) · position (BOUNDARY —
verb dispatch, HTTP endpoint, MCP tool, CLI entry, federation pull,
cluster join — or MID-CHAIN).

Then map the corpus onto the rows: CX-0mns's create path, CX-7b53's
Bursar put_built_commit default, S18's sized inner bound, and the five
isolated-green flake sites (room-visibility, sandbox file-flow,
capture-rate, CX-5f86 salvage, cl65 zone-setup) — for each flake, name
the production seam whose crossing the test exposed, or state that it
crossed a test-side budget only.

## Falsifiability (a census that cannot be void is not a census)

- **Known-member controls**: the census must FIND ticket_create's
  internal 5s (CX-0mns), Bursar put_built_commit's default (CX-7b53),
  and S18's 30s inner bound. Missing any known member voids the run —
  say so rather than shipping around it.
- **Seeded-plant control**: add one scratch `GenServer.call(x, y, 1234)`
  in a throwaway branch state, confirm the sweep reports it, remove it;
  transcript in the report, nothing committed.
- **Coverage statement** (report-your-coverage, standing pattern): the
  census document states WHICH pattern families were swept and which it
  is structurally blind to (macro-generated calls? NIF-internal
  timeouts? poolboy/NimblePool checkouts?) — named blind spots, not
  silence. "N seams found" without the instrument's coverage is exactly
  the defect this arc exists to kill.

## ⛔ Escape hatches, up front

- If the implicit-default enumeration cannot be completed (call-site
  population too large to classify), STOP at the measured subset and
  report the uncounted class with its size estimate — a bounded honest
  census beats an unbounded claimed one.
- If the sweep finds a budget seam whose value is computed dynamically
  at runtime (not a literal, not a default), that is a ROW with basis
  "dynamic: <expr>", not a reason to exclude it.
- ZERO production changes, zero test changes. If a defect is found en
  route (a seam with no basis bounding a known-slow chain is an
  OBSERVATION for the doc, not a fix to make), it goes in the report;
  filing is the operator's unless the round can file through the gated
  ticket_create verb (tix) — bd is a frozen archive; a round that
  cannot file reports identities as a stated deviation.
- Telemetry events in scope: NONE.

## Deliverable

`docs/notes/2026-08-12-time-budget-seam-census.md` — the seam table,
the corpus mapping, the coverage statement, the controls' transcripts —
plus the run report. Full core must still pass untouched (it should be
trivially unchanged; run it anyway and report the count against the
3,400/0+1skip baseline so "untouched" is measured, not assumed).

## Review criteria

Known-member controls found; plant control demonstrated; implicit-default
class enumerated by call site with method stated; every row carries all
six columns; corpus mapped with per-flake seam attribution; coverage
statement names blind spots; zero diffs outside docs/; boundary-origin
column populated (it is the build ruling's input).
