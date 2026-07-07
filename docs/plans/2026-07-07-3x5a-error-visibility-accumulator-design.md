# CX-3x5a — Error-visibility accumulator: closed-by-default for what a verb SILENTLY DROPS

**Status:** shaped, pending plan design-loop (2026-07-07)
**Bead:** CX-3x5a (P2)
**Throughline:** the error-visibility analog of the two closed-by-default surfaces
(execution allowlist + data thin-handle). This closes the THIRD surface:
*what a verb silently swallows*.

## The pattern (5 instances, each found one playtest at a time)

A facade method returns `{:error, reason}`; the verb's control flow IGNORES the
return and continues; the error vanishes. `map_safe_result/3` only sees the
verb's FINAL return value, so it can special-case a TAIL error but never an
intermediate one. Instances: CX-v6j4 (room-meta put_state loss), tail-`:state_bounds`
swallow, `:requires_object_host`, `{:moved}`, off-room-give `:recipient_not_here`.
Three are patched with dedicated `map_safe_result` arms — the DENYLIST shape
("surface the errors we thought of"). A NEW facade error added next year is
silently swallowed until the next playtest finds it.

## Design: the accumulator (structural, not enumerated)

Same lesson as the P0 (scrub-known-secrets → closed-by-default) and CX-r8vp
(thin-handle): replace "surface the N we listed" with "surface ALL non-`:ok` by
construction." A NEW facade error is then visible automatically.

Mechanism (rides the existing per-run-child process-dict pattern — lifecycle
counter, backing, whisper counters all use it):
1. `@facade_errors_key` — a per-run accumulator list. A facade method, whenever
   it is about to `return {:error, reason}`, ALSO appends `{method, reason}` to
   the accumulator (a single choke point: nearly all errors flow through
   `write_guarded` / a small set of return points — or wrap at the public-method
   boundary).
2. After the verb runs, `map_safe_result` (or `SafeVerb.run`) DRAINS the
   accumulator; if non-empty, surface to the invoker.
3. This SUPERSEDES the dedicated `:state_bounds` / `:requires_object_host` arms
   (they become just two more accumulated reasons with friendly messages) —
   unifying the special cases into the one structural path.

## The genuine nuances (for plan's design nod)

### N1. Precedence — which error wins the player message? (boss #6226 flagged)
Multiple non-`:ok` in one run. Options: (a) the FIRST error (earliest failure =
likely root cause), (b) the LAST, (c) ALL (list/summary). Lean: **FIRST**, with a
`(+N more)` suffix if several — root-cause-first, not noise.

### N2. Handled-vs-ignored — the double-report problem (the thorny one)
We CANNOT distinguish "verb inspected the error and handled it" from "verb ignored
it" by observing returns — the return value is consumed by the verb's own control
flow either way. So a verb that does
`case consume(w,x) do {:error,:not_carrying} -> say(w,"you don't have it"); :ok -> ... end`
HANDLED the error (narrated "you don't have it") but the accumulator still recorded
`:not_carrying` → surfacing it double-reports.
Options:
- (a) **Author-diagnostic framing** (lean): surface accumulated errors as a DIM,
  invoker-only diagnostic line (`(verb note: consume → not_carrying)`), distinct
  from gameplay narration — so a handled error is a tolerable dim note, not a
  competing gameplay message, while a truly-silent drop becomes VISIBLE to the
  author. This is "make silent-swallow visible" without polluting gameplay.
- (b) Gate on the verb's own outcome: only surface accumulated errors if the verb
  returned `:ok`/non-error AND produced no actor-facing output of its own —
  requires tracking whether say/emit/whisper fired (more machinery, still
  heuristic).
- (c) Accept the double as a loud player message (simplest, noisiest).
Lean (a): it matches the goal (author-visibility of drops) and degrades gracefully
on handled errors.

### N3. Scope — which returns accumulate?
Only `{:error, _}` returns. Pure reads that return `nil`/`false`
(`get_state`, `actor_carries?`, `pick` empty) are NOT errors and must NOT
accumulate — a verb branching on `actor_carries? == false` is normal control flow,
not a swallowed failure.

### N4. Interaction with the tail case
If the verb's FINAL return IS the accumulated error (tail case), surface ONCE (the
loud player reply), not tail-arm + accumulator both. Drain-and-dedup, or let the
accumulator own it entirely and drop the tail arms.

## Net
Structural (accumulator) over enumerated (arms) makes silent-swallow impossible by
construction, at the cost of the N2 double-report nuance — resolved by the
author-diagnostic framing. Completes the trio: what a verb can DO (allowlist),
what a verb can SEE (thin-handle), what a verb silently DROPS (accumulator) — all
closed-by-default.
