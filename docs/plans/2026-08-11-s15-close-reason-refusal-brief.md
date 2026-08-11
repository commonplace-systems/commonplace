# S15 build brief: ticket_close stops silently dropping args — CX-8hvt

> Plan ranked this S15 in the refill (msg 11253): S5's mandatory-reason
> principle applied to the verb that predates it. The mechanism is
> MEASURED (2026-08-11, CX-3hv0's live walk): `ticket_close` with args
> `%{"ticket" => id, "reason" => text}` succeeded and silently DROPPED
> the reason — the verb reads only `"ticket"` and optional `"witnesses"`
> (view_action_dispatch.ex ~:731), unknown keys are ignored,
> `closed_reason` stayed nil. Exactly the class CX-7smx closed for
> `ticket_update` (@0ef5448) — that fix is your template.

## ⛔ Escape hatch, up front

Stop and REPORT if you find that some existing caller DEPENDS on
ticket_close ignoring extra keys (enumerate callers of the verb across
apps/ first — dispatch surfaces, Bd.CLI, MCP tools, bots — and report
the list either way). A caller passing junk today would start refusing;
that's the intended behavior change, but a caller doing it from
PRODUCTION code is a finding to name before it starts failing.

## The fix (CX-7smx's shape, one verb over)

1. `ticket_close` validates its args key set as a whole: known keys are
   exactly `"ticket"` and `"witnesses"` — plus `"reason"`, which becomes
   REAL (see 2). Any other key refuses naming the unknown keys and the
   accepted set (mirror validate_ticket_change_keys' message shape).
2. ⭐ `"reason"` lands in `closed_reason`: the close path already writes
   `closed_reason` (Issue.close sets status/closed_at/closed_reason
   atomically — the field exists and is nil-able today). Thread the
   optional arg through to it. The S5 principle applied: a decision
   verb should be able to record WHY; unlike set_status the reason stays
   OPTIONAL here (close's contract predates the principle and existing
   callers pass none — do not break them).
3. The defect was the SILENCE, not the missing feature: an arg that
   is neither accepted nor refused must not exist on this verb after
   this round.

## Tests (red-first)

- RED-FIRST (the measured trap): close with `"reason"` on unmodified
  code succeeds with closed_reason nil — record it. After: closed_reason
  carries the text, verified by re-reading the ticket from the store.
- Unknown key (e.g. `"resaon"` typo, or `"foo"`) → refusal naming the
  key and the accepted set; the close does NOT execute (verify status
  unchanged by re-read).
- No-reason close unchanged: existing callers' shape (`ticket` alone,
  `ticket`+`witnesses`) closes exactly as today; closed_reason nil.
- Close-gate controls untouched: close still requires open; the
  witnesses path unchanged.

## Gates

Ticket verb + close-gate test files, then FULL core suite (mix test
apps/commonplace/test) + `mix compile --warnings-as-errors`; counts
reported. Tmp stores only.

## Deliverable

Work left UNCOMMITTED for the operator to land. Report: the caller
enumeration, red-first verbatim, refusal text verbatim, test counts,
deviations.
