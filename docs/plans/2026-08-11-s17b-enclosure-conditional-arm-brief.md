# S17b build brief: the wall-clock arm becomes enclosure-conditional — plan's S17 follow-up ruling

> Plan's ruling (msg 11286/11287), transcribed. Small round, one file:
> `apps/commonplace/test/commonplace/trust/audit_choke_perf_test.exs`
> as landed @5d3ac55. The structural arm (ops-per-denial == 4) stays
> BLOCKING EVERYWHERE, untouched — it carries the invariant. This round
> changes only the wall-clock ratio arms' RIGHT TO SPEAK.

## The ruled shape

1. ⭐ Each wall-clock ratio arm CHECKS ITS ENCLOSURE FIRST, measured:
   1-minute load average under a stated line AND no concurrent-build
   markers (mechanism yours: /proc/loadavg read + a cheap
   compile-in-progress probe such as another beam.smp/cc1 presence or a
   build-lock file — state what you chose and its false-positive/
   negative trade).
2. The load line is justified A PRIORI and NEVER tuned to pass: derive
   it from a stated basis (e.g. core count and the measured spread data
   already in the file's site comments — the CX-d0sc runs at load
   8.6–9.5 produced 0.38–3.26 spreads; the S17 5-run distribution ran
   quiet). Record the basis in the site comment.
3. Enclosure HOLDS ⇒ the arm gives its BLOCKING verdict exactly as
   today. Enclosure FAILS ⇒ NO-VERDICT-NAMING-LOAD: a logged, named
   skip carrying the measured load and the marker that tripped —
   never red, never green. (The sub-1.0 impossibility no-verdict
   generalized to the load axis; the instrument says "cannot answer
   here" instead of answering wrong.)
4. ⛔ WHY THE ARM KEEPS BLOCKING-WHERE-IT-CAN (record in the module
   doc, plan's ③): the structural arm is BLIND to a constant-factor
   blowup — every op 100× slower still counts 4 ops. The wall-clock
   arm is the only instrument on that class; demoting it flat would
   silently lose it.
5. Scope: THIS file only. Plan's ④ makes the shape precedent for other
   timing arms as-touched, not a refactor sweep.

## Tests

- Enclosure-holds arm: with the probe reporting quiet, the ratio arms
  run and can go red (the existing positive controls still fire).
- Enclosure-fails arm: force the probe (inject load reading / marker
  via the test's own seam — the probe must be injectable for exactly
  this) → the arm emits the named no-verdict with the measured values,
  and the ExUnit result is a skip/pass-with-log, NOT a failure.
- The structural arm runs in BOTH enclosure states (it is
  load-immune by design — pin that with an assertion that it gave a
  verdict even when the wall-clock arms declined).
- No budget value changes anywhere.

## Gates

The perf file (both enclosure states) + FULL core suite (mix test
apps/commonplace/test) + `mix compile --warnings-as-errors`; counts
reported. sol-run.log is the OPERATOR'S artifact — never delete it; no
repo-wide formatting; work UNCOMMITTED.

## Deliverable

Report: the probe mechanism + its trade, the load line + basis, the
no-verdict text verbatim, the structural-arm-still-speaks pin, test
counts, deviations.
