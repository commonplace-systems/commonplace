# S16 build brief: the two fixed-window singletons become condition-driven — CX-6kxv

> Plan ranked this S16 in the refill (msg 11253): transcription work —
> the ticket states the property, CX-5gkw's merged fix (@2b673e7) is the
> pattern. Two tests observed failing ONCE each during CX-5gkw's
> acceptance runs at loadavg 8–14, both failing INSIDE the test on fixed
> wall-clock constants (same mechanism as the ExUnit-timeout class CX-5gkw
> fixed, different surface):
>
> 1. `Commonplace.Process.SandboxExecTest` "sandbox-exec process can read
>    existing CRDT docs" — sleeps a FIXED 800ms window against a 100ms
>    orchestrator interval, then flunks "doubled.txt not found in CRDT
>    after sandbox-exec" if the window was crossed.
> 2. `Commonplace.Chat.ChatViewComputeSupervisorTest` "posting a message
>    triggers recompute -> _view.xml updates" — an eventually-condition
>    with a fixed 1000ms ceiling.
>
> Corroboration from today (2026-08-11): the sandbox family flaked again
> under concurrent-build load in a reviewer full-core run (SandboxTest
> file-flow arm, green isolated) — the class is live, not historical.

## ⛔ Escape hatch, up front

The POOL RULE first (CX-c93b discipline): run each member ALONE and
measure before treating it as understood — if either test fails
ISOLATED on an idle box, that is a real bug, not a budget crossing:
STOP AND REPORT it (a deterministic red hiding in a "flaky" label is
the exact trap the pool rule exists for). Also stop if making a test
condition-driven seems to require changing PRODUCTION code — the
observable the test needs must already exist.

## The property (the ticket's, verbatim intent)

Every wall-clock constant in these two tests gets an A-PRIORI BASIS or
becomes CONDITION-DRIVEN (poll-until with a sized ceiling) — NEVER a
number crept until green:

1. SandboxExec: the condition is observable (doc present in CRDT) —
   poll-until-condition with a generous sized ceiling replaces the fixed
   800ms sleep. The 100ms orchestrator interval gives the poll step its
   a-priori basis.
2. ChatViewComputeSupervisor: the existing eventually-condition keeps
   its shape but its ceiling gets sized with a stated basis (what work
   happens between post and _view.xml update; what CX-5gkw's budget
   sizing used for comparable paths), or the assertion becomes
   event-driven if a subscription point exists.
3. State each replaced constant, its replacement, and the basis, in the
   report AND in a brief code comment at the site (the constraint the
   code can't show).

## Tests / verification

- Baseline: each test file alone on the unmodified tree (the pool rule's
  measurement) — record pass and timing.
- After: each file alone (record timing delta — condition-driven should
  usually be FASTER than the fixed window, since it stops at readiness).
- Load arm if cheaply constructible: run the two files while a parallel
  compile loads the box (mirror of the observed failure mode); not
  mandatory — say if skipped.
- Full core suite; the two files' counts unchanged (no test deleted or
  weakened).

## Gates

The two test files + FULL core suite (mix test apps/commonplace/test) +
`mix compile --warnings-as-errors`; counts reported. Production code
untouched (or the escape hatch fired). sol-run.log is the OPERATOR'S
artifact — never delete it; no repo-wide formatting.

## Deliverable

Work left UNCOMMITTED for the operator to land. Report: per-constant
table (old constant → replacement → basis), isolated-run measurements
before/after, test counts, deviations.
