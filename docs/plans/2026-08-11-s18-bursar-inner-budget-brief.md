# S18 build brief: the Bursar scale test's INNER call budget — CX-7b53

> Plan ranked this S18 in the refill (msg 11253): the checks-doc row is
> the spine. The mechanism is MEASURED (CX-8wh1's baseline run):
> `Commonplace.Green.BursarTest` "bounded persistence … survives restart
> at scale" raised its OUTER ExUnit timeout to 600s under CX-5gkw with a
> correct basis — and op #152 of 200 then hit the next-tightest budget
> beneath it: `Bursar.acquire`'s DEFAULT 5s GenServer.call timeout,
> under suite load. The sibling test documented this exact mode in July
> and dodged it by cutting cycle count; the scale test keeps 200 ops
> DELIBERATELY (scale is its subject) and kept the default call timeout.
> Budget nesting is the lesson: each raised budget exposes the one
> beneath it.

## ⛔ Escape hatch, up front

Stop and REPORT if giving the test an inner budget requires changing
`Bursar.acquire`'s PRODUCTION signature in a way that reaches other
callers with different timeout needs — an API change with a blast
radius is a design question. (An optional timeout parameter defaulting
to today's 5s, or the test calling `GenServer.call/3` directly with its
budget, are both in-bounds; pick and say why.) Also stop if a sized
single-acquire measurement shows an acquire that CANNOT complete in any
reasonable budget under load — that is a Bursar performance finding,
not a test-budget fix (the bursar-bulk-op hazard class).

## The property (the ticket's, verbatim intent)

1. The INNER call timeout gets an explicit sized value with an A-PRIORI
   BASIS: measure a single durable acquire's cost under load (state the
   measurement), apply stated headroom, put the basis in a site
   comment. NEVER a number crept against red runs.
2. The 200-op count STAYS — it is the deliverable of the test.
3. The outer 600s budget stays as CX-5gkw sized it; check the nesting
   arithmetic explicitly in the comment (200 ops × inner ceiling must
   fit inside the outer budget with margin — state the product).
4. No other test's budgets touched; test code only unless the escape
   hatch's optional-parameter route is chosen (then the default stays
   5s and every existing caller is behavior-identical).

## Tests / verification

- Baseline: the Bursar test file alone on the unmodified tree (pool
  rule — record pass/timing; if it fails ISOLATED on an idle box,
  stop: that is a real bug).
- The single-acquire cost measurement that gives the basis (report the
  numbers).
- After: file alone (timing recorded), and full core.
- Counts unchanged in the file.

## Gates

Bursar test file (isolated) + FULL core suite (mix test
apps/commonplace/test) + `mix compile --warnings-as-errors`; counts
reported. sol-run.log is the OPERATOR'S artifact — never delete it; no
repo-wide formatting; work UNCOMMITTED.

## Deliverable

Report: the chosen mechanism and why, the single-acquire measurement +
chosen ceiling + nesting arithmetic, before/after isolated timings,
test counts, deviations.
