# S5v3 amendment brief: the reopen exit goes IN the freeze — the bare-:ok bypass dies

> You are amending YOUR OWN uncommitted S5v2 build in this worktree. The
> review confirmed everything except one seam, and plan has ruled it
> (msg 11241): reopen-with-reason RETIRES WriteGuard's "no reopen in v1"
> — that policy predated any governed transition surface, and your table
> is exactly the governed door it was waiting for. But the exit belongs
> IN check_frozen as a named, shape-validated case — your
> `status_transition_write_guard` bare-`:ok`-on-closed clause is the one
> write in the system that skips the chokepoint, and it is REJECTED.
> Everything else you built stands as-is.

## The ruled amendment (transcribe exactly)

1. DELETE the bypass: `status_transition_write_guard`'s closed clause
   goes away. EVERY transition — reopen included — passes
   `WriteGuard.check/5`.
2. CHECKED == WRITTEN (ratified finding #2, required here anyway): the
   guard is shown the FULL changes map that `Issue.update` will write —
   `%{status: ..., extra: ...}` — never a subset. The chokepoint sees
   exactly what lands.
3. `check_frozen` gains its ONE named exit, under an explicit option
   (e.g. `reopen: true`) that only `ticket_set_status` passes. ⭐ THE
   CONTAINMENT CONDITION — the option is a SHAPE, not a bypass token,
   because any caller can pass an opt: when the option is present and
   the issue is closed, check_frozen VALIDATES THE FULL WRITTEN DELTA
   against the reopen shape and refuses anything else:
   - `status` changes to exactly `"open"`;
   - `extra` differs from the current value ONLY by appending ONE
     well-formed decision record to `extra["status_decisions"]`
     (map with "type" => "DECISION", name/from/to consistent with a
     closed→open reopen, binary actor, non-empty reason, timestamp);
   - NO other field appears in the changes map.
   A caller holding the flag still cannot smuggle any other edit
   through the frozen state. Without the option, or with any delta
   outside that shape, the freeze refuses exactly as today.
4. TRUTH THE FREEZE'S DOCSTRING in the same round: "can never be
   bypassed … no reopen in v1" becomes the current fact — reopen exists
   as this guard's ONE named, shape-validated exit; everything else
   stays frozen.
5. The wontfix asymmetry (freeze matches only "closed") is NOTED in the
   module doc as a later census question — do NOT act on it.
6. Ratified as-built, no changes: the transition table, actor/reason
   handling, CLI routing, custody-silence pin, and the decision records
   riding `extra["status_decisions"]`.

## Mandated arms (red-first where behavior exists to contrast)

- ⭐ THE CONTAINMENT ARM (the test this amendment exists for): a caller
  passing the reopen option with a smuggled delta — an extra field
  changed alongside, a second decision appended, a title edit riding
  along, or status→anything-but-"open" — is REFUSED frozen. Red-first
  against your current v2 code, where the bare-:ok clause lets the
  smuggled delta through: record it.
- Well-formed reopen (closed→open, one appended decision, nothing else)
  passes through WriteGuard — no code path skips check/5 (assert the
  closed clause of status_transition_write_guard is gone; the
  containment arm is the behavioral pin).
- Closed ticket + any non-reopen change (with or without the option)
  still frozen, message unchanged for the without-option case.
- Your existing v2 arms all stand and stay green: table refusals,
  custody-silence, CLI routing, the full trap walk.

## Gates

Same as v2: ticket verb + claim + close-gate + WriteGuard test files,
then FULL core suite (mix test apps/commonplace/test) + `mix compile
--warnings-as-errors`; counts reported. If port 4002 binds again, run
from apps/commonplace as you did and SAY SO.

## Deliverable

Work left UNCOMMITTED for the operator to land (v2+v3 land together).
Report: the reopen shape validator as shipped, containment-arm
red-first verbatim, refusal texts, test counts, deviations.
