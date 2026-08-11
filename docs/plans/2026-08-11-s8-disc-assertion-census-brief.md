# S8-disc brief: assertion-failure census over the yrs dataset — MEASUREMENT ONLY

> Plan's ruling (msgs 11165/11196): before ANY assertion-widening (CX-xqfw),
> a census. All three verdicts are admissible successes — 0 / few / many
> failures decides the fix brief's ENTIRE shape. ⛔ Zero fixes, zero
> xfail-tagging, zero assertion edits beyond the census switch itself.
> A red finding is a FINDING, not a failed round.

## ⛔ Escape hatch, up front

Stop and REPORT if enabling the wider assertions requires more than a
mechanical switch (an env flag, a tag, or a small harness change in the
dataset runner). If the dataset runner has no seam for it and the census
would mean rewriting the harness, that rewrite is its own round — report
the seam you'd need.

## The protocol

1. Locate the yrs dataset runner (apps/yelixer/test — the 5,320-case suite;
   CX-xqfw's subject is the ~5,220 cases whose map/array assertions are
   narrower than their text ones). Read CX-xqfw's ticket first for the
   exact axis (serve erpc is unavailable in-sandbox — the ticket text is
   quoted in QUEUE.md row S8; if you cannot find the axis stated, the
   escape hatch applies: report what the runner DOES assert per type).
2. Enable the widened map/array assertions across the full dataset in ONE
   run, in the most mechanical way the harness allows (env-gated switch is
   fine and its OFF-default must leave the suite exactly as today).
3. Capture FAILURE IDENTITIES — case id / fixture name + assertion kind —
   never counts alone. Redirect to a file; never pipe to tail.
4. Reconciliation (the LANDED∪REFUSED law at the log layer): identities
   extracted must equal the run's reported failure count; mismatch flags
   the run.
5. Deliverable table: case → assertion kind → failure shape (one line
   each), plus the run's enclosure (seed, counts, duration, command).
   If 0 failures: the census says so with the total case count asserted
   nonzero (a 0-over-0 run is VOID, not green).

## Gates

The dataset suite runs once as-is FIRST (control: today's counts on
unmodified assertions — record them), then once widened. Nothing else.
`mix compile --warnings-as-errors` clean if the switch touches code.

## Deliverable

Work left UNCOMMITTED (the census switch + the table doc). Report: control
counts, census table or its verified emptiness, reconciliation result,
deviations. NO interpretation of failure causes — that is the fix brief's
input, not this round's output.
