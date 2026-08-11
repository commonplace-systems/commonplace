# CX-sa5r build brief: diff_yjs absent-driver = loud named SKIP, never invalidation

> BUFFER ITEM — dispatch when the Sol lane empties. No serve dependency.

## ⛔ Escape hatch, up front

Stop and REPORT instead of building if:
- Reading the current guard shows CX-3mj2's import-resolution check ALREADY
  covers fresh-worktree absence and something else invalidates the tests —
  that would mean the diagnosis missed a layer, which is a finding.
- The fix seems to require touching Yelixer.Encoding, the oracle driver
  itself, or vendoring node modules. Scope is the test file's gating only.
- ⚠️ Sandbox note: this sandbox has network access; if you consider
  `npm install` to make the driver PRESENT for the positive-arm test, first
  check whether the repo documents a driver setup path (CX-3mj2's work) and
  use exactly that; if none exists or it fails, the present-arm is
  UNVERIFIED-in-sandbox — say so and stop rather than improvising installs.

## The defect (CX-sa5r, measured 2026-08-11 phase-a enumeration)

In a worktree without node_modules, `Yelixer.DiffYjsTest`'s `setup_all`
crashes (Node `ERR_MODULE_NOT_FOUND`) and INVALIDATES all 11 tests:
summary says "0 failures, 11 invalid", exit code 2. A red run that names no
failing test. Sole red across 3 umbrella seeds × 4,352 tests; deterministic
alone (evidence: docs/measurements/2026-08-11-ci-red/alone-diff-yjs.log).

CX-3mj2 (closed 2026-08-08) ruled: the skip guard must check THE IMPORT
RESOLVES (not merely that node exists), and when the driver IS present,
assert the 11 tests RAN — a count, never "0 failures". Read the guard as it
exists today FIRST and state in your report which of these holds: the guard
is missing, the guard checks the wrong thing, or the guard is present but
bypassed on this path.

## The property

1. Driver absent (import does not resolve) ⇒ the whole module SKIPS with a
   loud, named reason visible in the run output (ExUnit `@moduletag :skip`
   applied conditionally, or the established repo pattern for conditional
   suites — match whatever CX-3mj2 built rather than inventing a second
   mechanism), exit code unaffected, zero invalid tests.
2. Driver present ⇒ all 11 run; the RAN count is asserted somewhere
   CI-checkable (CX-3mj2's own acceptance).
3. Never again: `invalid > 0` from this module, or rc≠0 paired with a
   "0 failures" summary.

## Tests (red-first)

- RED-FIRST in the absent-driver environment (this worktree is one): run the
  file on unmodified code, record "11 invalid, rc=2". After the fix: the
  module skips loudly, 0 invalid, rc=0. Assert on the INVALID count and rc —
  not the failure count, which is 0 in both worlds (the measurement's
  reconciliation lesson).
- The skip reason must name the missing driver and the setup path (so the
  next person knows it is an environment gap, not a code defect).
- Present-arm: per the sandbox note above — use the documented driver setup
  if it exists; otherwise report the arm UNVERIFIED rather than skipping the
  claim silently.

## Gates

- The diff_yjs file itself (both arms as achievable), then the yelixer app
  suite from the umbrella root: `mix test apps/yelixer/test` — count
  asserted nonzero (path-drop guard).
- `mix compile --warnings-as-errors` clean.

## Deliverable

One commit on the branch you are given, not pushed. Report: which of the
three guard-states you found (missing / wrong-check / bypassed), red-first
outputs verbatim, both arms' results with UNVERIFIED named if applicable,
test counts, deviations.
