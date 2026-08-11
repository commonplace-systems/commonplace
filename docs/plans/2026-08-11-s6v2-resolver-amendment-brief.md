# S6v2 amendment brief: one gate resolver, then the boot-posture round resumes

> You are resuming S6 (docs/plans/2026-08-11-s6-boot-posture-brief.md) after
> its escape hatch fired — correctly. Your census found `local_write_gate`
> with divergent absent-handling across four readers (three default
> `:dry_run`; mud/player_session.ex:883 reads with NO default and compares
> `== :enforce`). Plan has ruled the fix (msg 11223, CX-1jh2 precedent).
> Execute THIS amendment first; then the original brief's Parts A/B/C
> proceed on top of it, unchanged except where noted.

## The ruled fix (transcribe exactly)

1. ⭐ DELETE THE DUPLICATION — do not add a fourth hand-kept default. ONE
   resolver (`Trust.local_write_gate/0` or equivalent in the trust area)
   resolves the knob in ONE place; ALL FOUR sites read the RESOLVED value.
   `enforce?` and every other question is asked OF the resolution, never
   of the raw env. (Plan: patching a default into player_session's read
   would be the fourth copy of a policy that already forked once.)
2. ABSENT resolves to `:dry_run`, at that single site only. This is
   behaviour-preserving today (matches the three majority readers; reader
   four's `enforce?` answers identically under nil and :dry_run) — the
   fork closes while the answers still coincide. It is also the
   observe-then-require step-1 posture: absent = OBSERVE mode, declared
   loudly by Part B's boot fact.
3. ⭐ INVALID VALUES REFUSE LOUDLY AT BOOT. The property (mechanism is
   yours): no raw env string may mint an atom or silently resolve —
   the valid set is exactly off | dry_run | enforce, and a value outside
   it halts boot with a named refusal listing the valid set. Today
   runtime.exs:136 does `String.to_atom(gate)` on raw input; that call
   must not survive in any form that can mint an arbitrary atom.
4. facade.ex:36's docstring currently cites the no-default raw read as
   the canonical description of the gate — it documents the defect as
   the reference. Truth it: point it at the resolver.
5. Census consequence: Part A's table gains an INVALID-VALUE column
   (what happens on a value outside the knob's set), because Part B's
   boot fact can only print a truthful line for values the resolver
   defines.

## Mandated arms (red-first where behavior exists to contrast)

- Resolver unit arms: absent → :dry_run; each valid value → itself;
  invalid → the named refusal (capture its text verbatim).
- RED-FIRST for the invalid-value arm: record what unmodified code does
  with an invalid gate value (minted atom falling through readers) before
  the refusal exists.
- ⭐ SINGLE-READ PIN: a source-scan test asserting the only
  `get_env(:commonplace, :local_write_gate` site under apps/*/lib is the
  resolver itself — the regression pin that prevents a fifth hand-kept
  copy. (Test files and the resolver are the only allowed matches; the
  pin must FAIL if player_session's raw read survives — run it red-first
  against current code and record that.)
- Behaviour-preservation: existing gate tests (commit_store, trust,
  audit_canary, player_session enforce paths) pass unchanged.

## Then resume the original S6 brief

Parts A (census doc, + invalid-value column), B (loud boot fact,
ABSENT-defaulted vs env-set), C (CX-f4vv named refusal) exactly as
written there, including its escape hatch and red-firsts. The boot fact
reads postures FROM the resolver.

## Gates

Original brief's gates: boot/application/trust test files + FULL core
suite + `mix compile --warnings-as-errors`; counts reported.

## Deliverable

Work left UNCOMMITTED for the operator to land. Report: resolver arms
red-first verbatim, the single-read pin red-first, census table, Part B
log evidence, Part C red-first, test counts, deviations.
