# S34 build brief: deadline-threading through the ticket-create chain — CX-gc7q (deadline arc, build round 1)

> **The work's ticket is CX-gc7q.** Any doc line citing a ticket cites
> CX-gc7q — no other id. Context labels, none the citation: CX-11ms is
> the census this ruling consumed (docs/notes/2026-08-12-time-budget-
> seam-census.md, on main — READ IT, it is the map); CX-0mns is the
> class instance whose reproduction is this round's acceptance; S24's
> issue-doc index is the existing residual-tear catcher. This is
> transcription from plan's build ruling; the four constraints and the
> pre-mint addition are DECIDED — where the brief is silent, the census
> plus the constraints answer before you improvise.

## The chain (from the census, verified lines)

MCP tool → `bd_route.ex:49` — `:rpc.call(node, mod, fun, args,
rpc_timeout())`, dynamic 30,000ms: **the BOUNDARY, where the deadline
is born** → serve-side `ticket_create` dispatch → `Issue.create`'s
SEQUENTIAL document writes (issue doc → description → comments dir →
dir schema → issues-dir link; the id is minted before the writes) →
each write landing through `CommitStore.put_built_commit`'s bare call
at `commit_store.ex:759` — **invisible DEFAULT-5000, the census's
located orphan-minting seam**.

## The four constraints (ruled; violations are review failures)

1. **The deadline originates at the boundary — nothing internal invents
   one.** The MCP-side RPC budget is where the total is born; serve-side
   code RECEIVES a deadline, it never conjures a fresh figure.
2. **REMAINING time propagates, never the original.** Each seam gets
   `deadline - now`, so a chain that spent 25s at one seam offers the
   next seam 5s, not 30. Prefer an absolute monotonic deadline carried
   in context over decrementing integers (immune to double-subtraction),
   but the mechanism is yours within constraint 4.
3. **Mid-chain expiry is a NAMED refusal naming the exhausted seam** —
   the per-layer attribution today's separate budgets give by accident
   must survive: "deadline exhausted at put_built_commit(description
   doc)" beats "timeout". The refusal travels back to the boundary
   caller intact.
4. **Propagation lands AT the census-located seams** — the existing call
   sites gain a derived timeout argument; no new wrapper layer, no
   smeared sleeps, no framework. Converge, don't smear.

## ⭐ The pre-mint check (plan's addition — the round's strongest property)

At the mint boundary — BEFORE the id exists — compare remaining budget
against the chain's **declared floor**. Below the floor: **REFUSE
BEFORE MINTING** with a named refusal ("insufficient remaining budget
for create: <remaining> < floor <floor>"). The floor is a DECLARED
constant with a MEASURED basis stated in a comment (size it from the
chain's own cost: five sequential writes on a healthy store — measure,
state, don't guess; the census's row conventions apply: a number with
basis NONE is what this arc exists to kill). Result: a create **lands
whole, refuses pre-mint, or names its exhausted seam — never
mints-then-vanishes**. The outcome-unknown case becomes structurally
impossible on this chain; S24's index remains the catcher for any
residual tear (crash between commits is still possible — the index is
why that's recoverable; say this in the moduledoc rather than claiming
total impossibility).

## Compatibility (constraint 1's flip side)

Absent-deadline callers keep current behavior: the CLI path, internal
callers, and tests that call `Issue.create` without a deadline run
exactly as today (existing per-seam budgets stand). The deadline is
born at the boundary that has one; it does not become a mandatory
argument everywhere. The propagation plumbing must therefore be
optional-and-threaded (context/opts), with the absent case
byte-equivalent to today — pin that with a test.

## ⛔ Escape hatches, up front

- **THIS CHAIN ONLY.** No other chain, no sweep, no generic deadline
  framework. The report STATES the transcribable pattern (what a
  subsequent chain copies: where the deadline rides, how a seam derives
  remaining, how expiry names itself) — a section, not an abstraction.
- If threading remaining time to `put_built_commit` requires changing a
  public function signature with many non-chain callers, enumerate the
  callers and STOP if the compatible route (new optional argument /
  opts) doesn't cover it cleanly.
- If the floor cannot get a measured basis in-round, STOP and report
  the measurement gap rather than shipping a guessed constant.
- The MCP-side `rpc_timeout()` figure itself is NOT this round's to
  resize — the boundary keeps its budget; this round makes the budget
  TRAVEL.
- Telemetry events in scope: NONE (expiry refusals are return values /
  named errors, not new events; if observability wants more, name it in
  the report).

## Tests (red-first; the CX-0mns reproduction is the acceptance)

Baseline: take the then-current full core count and SAY IT (my last
measured: 3,403/0 + 1 skipped @93b105bc; S30/S31 may land first —
reconcile against your base).

- **RED-FIRST — the CX-0mns shape**: drive a create whose inner seam is
  made slow (injectable delay or a store stub) past the inner budget
  with a generous outer deadline. TODAY: the id mints, an inner timeout
  fires, the outcome is unknown (the torn-create S24 catches). AFTER:
  the create either completes (inner seam got the remaining time, which
  exceeds the old invisible 5s), refuses pre-mint, or returns the
  seam-named refusal — assert NO ID EXISTS in store or index for the
  refusal cases.
- **Pre-mint refusal arm**: deadline nearly exhausted at entry →
  named refusal, zero commits written, zero index rows, no id minted.
- **Seam-naming arm**: expiry mid-chain → the refusal names the
  exhausted seam and which document write it was processing.
- **Remaining-not-original arm**: capture the timeout the inner seam
  receives (injectable clock or captured argument) after burning time
  upstream — assert it is less than the boundary figure.
- **Compatibility pin**: absent-deadline call runs today's path with
  today's budgets — before and after byte-equivalent behavior.
- Focused suites named with counts; full core in-round with the count
  reconciled.
- Prove any "pre-existing/unrelated" failure with an isolated rerun —
  licenses "outside this diff's footprint", not "flaky under load".

## Review criteria

Deadline born at the boundary only (grep for any serve-side literal
that could be a second origin); remaining-time arithmetic monotonic-
clock-based; expiry refusals carry seam + document names; pre-mint
floor has a measured, stated basis; absent-deadline path pinned
byte-equivalent; the transcribable-pattern section present and
sufficient for a second chain's author; S24 index interplay stated
honestly (structural narrowing, not total impossibility); full core
count reconciled.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). bd is a
frozen archive and answers "no issue found" for everything since
2026-08-05. A round that cannot file via the verb reports identities
for the operator, stated as a deviation.
