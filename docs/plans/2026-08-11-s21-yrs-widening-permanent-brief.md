# S21 build brief: the yrs map/array widening becomes permanent — CX-xqfw's fix, shaped by the census

> S8-disc's census (@3f1dd52, docs/plans/2026-08-11-s8-disc-assertion-
> census-results.md) decided this brief's entire form: **0 failures over
> 5,320 full map/array validations** — the cap-100 hid nothing, and
> widening is safe. The only open choice was +21s-always vs a tagged CI
> run; DECIDED HERE: always-on. Basis: the full pass costs 49.6s vs
> 28.3s text-only (+21.3s measured) against a full-umbrella CI run
> already in the hundreds of seconds, and a tagged suite nobody runs is
> the silently-unrun trap this repo keeps paying for (the census knob's
> own OFF-default would rot the same way).

## The build

1. Full text+map+array validation over all 5,320 cases becomes the
   UNCONDITIONAL behavior of
   `apps/yelixer/test/yelixer/yrs_dataset_test.exs` — the `min(count,
   100)` cap and the `YELIXER_YRS_FULL_CENSUS` census knob both retire
   (the knob was the census's instrument; the census is done and its
   verdict recorded — dead switches are how stale claims start).
2. The un-capped error reporting from the census switch stays (a
   failure lists every identity, never a truncated sample).
3. The dataset-count nonzero assertion stays (a 0-over-0 run is VOID).
4. State the cost in a site comment WITH its basis: +21.3s measured
   (28.3s → 49.6s), census @3f1dd52, verdict 0/5,320.

## ⛔ Escape hatch, up front

If the widened run is NOT green on current main (the census measured
@3f1dd52; yelixer has changed since), STOP — a new red is a REAL
DIVERGENCE FINDING with its identity, exactly what the widening exists
to catch, and it gets a ticket before any fix. Do not fix divergences
in this round.

## Tests

- The file's two tests remain two tests; the second now validates all
  5,320 (assert the run_count == the decoded dataset count — the
  100-cap's absence is pinned by that assertion, not by comment).
- Red-first where behavior exists: on unmodified code the second test
  validates 100 (record the count); after, 5,320.
- Timing recorded before/after (the +21s claim re-measured).

## Gates

The dataset file + FULL yelixer app suite (mix test apps/yelixer/test)
+ `mix compile --warnings-as-errors`; counts reported. sol-run.log is
the OPERATOR'S artifact — never delete it; no repo-wide formatting;
work UNCOMMITTED.

## Deliverable

Report: the run_count pin, red-first counts, before/after timing,
test counts, deviations.
