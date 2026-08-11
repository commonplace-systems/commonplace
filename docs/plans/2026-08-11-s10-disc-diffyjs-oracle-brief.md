# S10-disc brief: the diff_yjs oracle measurement (CX-ye7n) — MEASUREMENT ONLY

> Plan's rulings (msgs 11165/11196) + jes's named ask: measure the 11
> diff_yjs tests WITH the oracle installed, before any CI wiring — never
> exclude unmeasured. Identities, not counts. Both verdicts are successes:
> PASS ⇒ the follow-up brief is npm-install-in-CI; FAIL ⇒ a finding about
> yelixer that reshapes S10 entirely. ⛔ Zero fixes this round.

## Context you inherit (post-sa5r — read the file first)

`apps/yelixer/test/yelixer/diff_yjs_test.exs` now SKIPS loudly when the
driver import doesn't resolve (CX-sa5r, merged @295181b) and its skip
reason names the setup: `npm ci --prefix apps/yelixer/test/fixtures`.
The sandbox has network; that setup path is documented and was exercised
successfully tonight (11 ran, 0 failures, in the sa5r run's present-arm).
Your round measures it PROPERLY: fresh install, both oracles if the
harness supports them, identities recorded.

## ⛔ Escape hatch, up front

Stop and REPORT if `npm ci` fails or the import still doesn't resolve
after it — that is an environment finding (record the npm output), not a
license to improvise installs beyond the documented path.

## The protocol

1. `npm ci --prefix apps/yelixer/test/fixtures` — record its output tail
   (package count, vulnerabilities line).
2. Run the file: `mix test apps/yelixer/test/yelixer/diff_yjs_test.exs`
   → assert 11 RAN (the count, never "0 failures" — a skip-run is VOID for
   this measurement and means the install check failed silently).
3. Record per-test identities and results. If the harness supports the
   `YJS_ORACLE=preview` arm (the test file reads it), run that too and
   record separately — two enclosures, clearly labeled; if preview's deps
   are not installed by the same npm ci, note it as NOT MEASURED rather
   than installing more.
4. Enclosure per run: node version, driver path, oracle arm, counts,
   duration, command.
5. Deliverable: the measurement table + a one-paragraph factual summary
   (ran/failed identities only — no diagnosis).

## Gates

Nothing beyond the protocol runs. The repo must be left clean of
node_modules side effects OUTSIDE the fixtures prefix (check `git status`
— fixture lockfiles are tracked; node_modules must be ignored already,
verify rather than assume).

## Deliverable

Work left UNCOMMITTED (the table doc only, unless a harness seam needed a
line — report if so). Report: install output tail, both arms' tables (or
the NOT-MEASURED note), the 11-ran assertions, deviations.
