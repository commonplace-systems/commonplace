# S19 build brief: the diff_yjs oracle runs in CI — CX-ye7n's follow-up (delegated-stream draw #1)

> Basis: S10-disc's measurement (@c2e4138, docs/plans/2026-08-11-s10-disc-
> diffyjs-oracle-measurement.md): `npm ci --prefix apps/yelixer/test/
> fixtures` (4 packages, 0 vulnerabilities, ~1s) resolves both oracle
> aliases and all 11 tests pass on both arms. The classification doc
> (@295e3ea item 1) closed the local invalidation via CX-sa5r's loud
> skip. The remaining gap: CI never installs the oracle, so the 11
> differential tests SKIP in CI — the one place a silent skip costs
> byte-compatibility coverage on every merge.

## The build

1. `.github/workflows/ci.yml` gains the oracle install before the test
   step: node setup (if not present in the runner image — check what
   the workflow already has) + `npm ci --prefix apps/yelixer/test/
   fixtures`. Cache keyed on the fixtures lockfile is nice-to-have,
   not required (the install is ~1s).
2. ⭐ THE SKIP BECOMES REFUSABLE: a new env knob (e.g.
   `YELIXER_REQUIRE_YJS_ORACLE=1`, set in ci.yml) under which the
   module-level skip turns into a FAILURE naming the missing driver —
   so a future runner-image change that breaks the install goes RED
   instead of silently skipping 11 tests forever. OFF-default: local
   fresh worktrees keep CX-sa5r's loud skip exactly as today.
3. The 11-ran property rides the existing tests (with the oracle
   installed they run; with the knob set they cannot silently skip) —
   no new assertion of counts needed beyond the knob's refusal arm.

## ⛔ Escape hatch, up front

Stop and REPORT if the CI workflow's structure means the install can't
precede the umbrella test step cleanly (matrix jobs, split app runs —
name the seam). Do NOT restructure the workflow beyond adding the
install + env line.

## Tests (red-first where behavior exists)

- Knob arm red-first: with `YELIXER_REQUIRE_YJS_ORACLE=1` and NO
  node_modules, the current code SKIPS (record it); after, it FAILS
  naming the driver and the install command. With node_modules present,
  knob set: 11 run, 0 failures. Knob unset, no node_modules: loud skip
  unchanged (CX-sa5r's behavior byte-identical).
- ⚠️ THE CI ARM IS UNVERIFIABLE IN-SANDBOX AND LOCALLY: name it
  UNVERIFIED. Acceptance is CI's own next run on main going green WITH
  the diff_yjs tests counted as run (the operator reads the CI log for
  the 11). Per the env-sensitive-code gate: the operator verifies
  under stripped env locally before merge and confirms CI-green after.

## Gates

yelixer diff_yjs + dataset test files locally (both knob states), FULL
yelixer app suite (mix test apps/yelixer/test), `mix compile
--warnings-as-errors`; counts reported. sol-run.log is the OPERATOR'S
artifact — never delete it; no repo-wide formatting; work UNCOMMITTED.

## Deliverable

Report: the ci.yml diff (small), knob red-first verbatim both arms,
local counts both knob states, the UNVERIFIED CI arm named, deviations.
