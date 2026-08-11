# S17 build brief: AuditChokePerfTest — arms get identities, verdicts get a basis — CX-dsqc + CX-d0sc

> Plan ranked this S17 (msg 11253): authorable-now because BOTH tickets
> wrote their acceptances at filing, and both FORBID the lazy fix.
> ⛔⛔ STANDING PROHIBITIONS, from the tickets verbatim: do NOT raise
> `@max_ratio` or any arm's ratio budget to make it pass; do NOT touch
> the DENY OFFERED arm's budget at all (it may be reporting a REAL
> invariant degradation — erasing an alarm while claiming to fix a
> flake is the named failure mode).

## The measured defects

1. (CX-dsqc) `audit_choke_perf_test.exs` is SEVERAL independent arms
   under ONE test name: DENY OFFERED (p50 4.941 vs limit 3.0 — FAILING,
   possibly real), ALLOW (comfortable), and a third arm that passed at
   p99=2.995 vs 3.0 — a 0.17% margin coin-flip that feeds CX-c93b's
   changing failure set precisely because it usually passes.
2. (CX-d0sc) The ratio guard measures noise: 0.38→3.26 on identical
   code, and sub-1.0 ratios (added work measuring FASTER) are
   physically impossible — instrument noise in the pass direction
   implies noise in the fail direction.

## The build (the tickets' own acceptance, transcribed)

1. ⭐ SPLIT THE ARMS: each ratio arm becomes its own ExUnit test with
   its own name, so tooling and triage see WHICH arm failed.
   Demonstrate with a run where one arm fails and the report names it.
2. ⭐ THE DENY-PATH BOUNDED-WORK PROPERTY GOES STRUCTURAL (CX-d0sc's
   fix direction): assert the OPERATIONS ADDED PER DENIAL — directly
   available from AuditLogCounter — is bounded/constant, instead of (or
   alongside, see 4) the wall-clock ratio. A count cannot read 0.38.
   ⚠️ This doubles as the discriminator CX-d0sc needs: if ops-per-denial
   is CONSTANT, the 4.941 ratio was noise; if it GROWS with load or
   denial count, that is the REAL degradation the ticket suspects —
   ⛔ STOP AND REPORT the growth curve; its fix is a different round.
3. The third arm's margin gets a BASIS: measure its ratio distribution
   across ≥5 isolated runs; choose more samples, a trimmed statistic,
   or a justified budget FROM that distribution (never from one
   sample). Record the five-run table in the report and the basis in a
   code comment.
4. Ratio arms that remain keep a sanity guard from CX-d0sc's tell:
   a measured ratio < 1.0 marks the RUN as noise-dominated (the arm
   reports no-verdict / skips with the measured value named) rather
   than passing on an impossible number — overlap means no verdict,
   never a coin-flip.
5. ⛔ POSITIVE CONTROL (CX-dsqc's acceptance): show each re-shaped arm
   can still go RED for the reason it exists to catch (e.g., inflate
   the counted work artificially in a control test, or a deliberately
   tiny budget in a control assertion). A guard that cannot fail is
   not a guard.

## ⛔ Escape hatches, up front

- Ops-per-denial not expressible from AuditLogCounter without touching
  production code → report the seam you'd need.
- The structural count shows GROWTH (the real degradation) → stop and
  report the curve; do not fix it here.
- The five-run distribution for the third arm doesn't separate from
  its budget in either direction → that arm has no verdict to give;
  report the distribution and propose no-verdict shape rather than
  picking a number.

## Gates

The perf test file (isolated, ≥5 runs for the distribution) + trust
suite + FULL core suite (mix test apps/commonplace/test) + `mix compile
--warnings-as-errors`; counts reported. sol-run.log is the OPERATOR'S
artifact — never delete it; no repo-wide formatting; work UNCOMMITTED.

## Deliverable

Report: the arm-split demonstrated (one-fails-names-which run), the
ops-per-denial verdict (constant vs growth — with the curve if growth),
the five-run distribution table + chosen basis, positive-control
evidence, test counts, deviations.
