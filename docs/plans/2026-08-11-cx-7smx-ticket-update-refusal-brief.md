# CX-7smx build brief: ticket_update refuses unknown change keys loudly — no silent drops

> BUFFER ITEM — dispatch when the Sol lane empties. No serve dependency;
> the verb dispatch layer is fully testable with fixture signing contexts
> and tmp stores like the existing TicketVerbsTest does.

## ⛔ Escape hatch, up front

Stop and REPORT instead of building if:
- Enumerating callers (below) shows a caller that DEPENDS on the silent
  drop for legitimate batch behavior — that becomes a design question, not
  a fix.
- The fix seems to require changing which fields ARE updatable (adding
  `description` or `status` to @ticket_update_fields is explicitly NOT this
  ticket — both have deliberate separate paths).

## The defect (CX-7smx, hit live 2026-08-11 ~01:50Z)

`ViewActionDispatch.do_dispatch("ticket_update", ...)` filters `changes_map`
through `@ticket_update_fields` (~line 1670,
`atomize_ticket_changes/1` ~line 1696): unknown keys are SILENTLY DROPPED
and the verb still returns `{:ok, :tree_mutation, ...}`. Measured live: a
`changes: %{"description" => ...}` call returned success while writing
nothing — caught only by a re-read. The marker comment at the site (commit
6058839) documents the defect and says someone will come to fix it; this is
that fix.

## The property

1. Every key in `changes_map` is either APPLIED or NAMED IN A REFUSAL —
   never dropped. A request containing any non-updatable key is refused as
   a WHOLE (`{:error, ...}` naming every offending key); no partial apply.
2. The refusal message is actionable: for `description` it points at the
   real path (`Bd.Issue.write_description/5` — descriptions live in a
   separate doc, deliberately); for `status` it points at `ticket_close`
   (the one status path); for anything else it lists the updatable set.
3. Existing valid updates unchanged (title/priority/type/owner/labels/
   needs/done_when/done_witness/claimed_by/legacy_id, and whatever
   WriteGuard already refuses stays refused with its existing shapes).

## Callers to enumerate before building

`grep -rn "ticket_update" apps/ tools/ bin/` — enumerate every caller
(known: MCP bd_update tooling, Bd.CLI, tests). For each, confirm it does
not rely on extra keys passing silently; report the enumeration. If the
MCP layer forwards user-supplied maps verbatim, its tests are in scope.

## Tests (red-first)

- RED-FIRST: `ticket_update` with `changes: %{"description" => "x"}` on the
  unmodified code returns `{:ok, ...}` — record it — then after the fix
  returns the named refusal, and a re-read shows nothing changed.
- A mixed request (one valid + one unknown key) refuses as a whole and the
  valid key is NOT applied (verify by re-read).
- Control: a fully-valid update still lands.
- The `status` and `description` refusal messages carry their pointers.

## Gates

- The ticket verbs test files, then the full core suite
  `mix test apps/commonplace/test` from the worktree root (dispatch is a
  shared seam) — counts reported, pre-existing failures shown pre-existing.
- `mix compile --warnings-as-errors` clean.

## Deliverable

One commit on the branch you are given, not pushed. Report: red-first
verbatim, the caller enumeration, test counts, deviations.
