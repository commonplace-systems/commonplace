# S5v2 brief: `ticket_set_status` — the decision-axis transition verb; release-resets-to-open is RETRACTED

> You are resuming S5 in this worktree after its escape hatch fired
> correctly: your writer enumeration refuted the ratified premise, and
> plan RETRACTED release-resets-to-open (msg 11229). The verbs you
> measured are CORRECT AS BUILT — claim/release never touch status and
> MUST NOT START. Custody events (release, lease expiry, forced release)
> stay status-silent forever. Your enumeration IS this brief's
> measurement; do not redo it.

## The ruled defect (plan's, from the S5 measurement)

THE VALID SET IS WIDER THAN THE TRANSITION GRAMMAR. On the verb surface,
status carries one axis — decision (open at create, closed at close) —
with custody in the Bursar token and claimed_by as display. But import
and the legacy bd-CLI mint in_progress/blocked/review/wontfix: decision
values the verb grammar can neither reach nor exit. Import IS gated, so
these are gated-reachable states with no gated exit. The exit lives on
the decision axis, as an explicit decision by a principal — never as a
side effect of any custody event.

## ⛔ Escape hatches, up front

Stop and REPORT if:
- Implementing the table seems to require weakening `ticket_close`'s
  close-requires-open, or touching WriteGuard's close-gate semantics —
  both are CORRECT and stay.
- Recording actor+reason for a transition cannot ride the existing gated
  write surface / existing record fields without inventing a NEW record
  shape — a new durable record shape is plan's to rule, not yours.
- You find a status writer your S5 enumeration missed.

## The verb (ruled shape; table finalized by the operator)

`ticket_set_status` — ONE gated verb, explicit transition table over the
FULL valid set (open, in_progress, blocked, review, closed, wontfix),
CLOSED BY DEFAULT: only named transitions execute; everything else is a
refusal naming the from-state, requested to-state, and the named set of
legal targets. Every executed transition is recorded as a DECISION —
actor (resolved server-side from signing_context, same as
claim/release; never client-supplied) and a required non-empty reason.

The table:

| from                                | to        | named as            |
|-------------------------------------|-----------|---------------------|
| open / in_progress / blocked / review | open      | decision            |
| open / in_progress / blocked / review | blocked   | decision            |
| open / in_progress / blocked / review | review    | decision            |
| open / in_progress / blocked / review | wontfix   | decision (reason)   |
| closed / wontfix                    | open      | reopen-with-reason  |
| any                                 | in_progress | ⛔ REFUSED — no inbound edges |
| non-closed                          | closed    | ⛔ REFUSED — points at ticket_close |

Rationale you may cite in refusal text and module doc:
- `in_progress` is EXIT-ONLY: it was never verb-reachable (import/legacy
  CLI artifact); custody is witnessed by the claim token and displayed
  via claimed_by, so a status value asserting "being worked" duplicates
  the custody axis. Existing instances keep their exits; the value goes
  extinct by attrition, and history is untouched.
- `closed` keeps its single door: `ticket_close` owns the atomic
  status+closed_at+done_witness write and its close-requires-open gate.
  A blocked/review/in_progress ticket closes by decision-to-open, then
  close — two recorded decisions, which is what actually happened.

## One door, not two (ruled ⑤)

The legacy bd-CLI `update --status` path must route through the SAME
transition check — no second grammar-free door. (Its writes already
refuse under enforce per CX-3nf4; the point is that even permissive-mode
writes obey the table.) Import stays AS-ADMITTED (ruled ④): the importer
keeps writing imported statuses as legitimate history — now with exits.

## Tests (red-first, driving the gated verbs)

- RED-FIRST (the measured trap): construct an import-minted
  `in_progress` ticket (mirror the cutover residue); on unmodified code
  record the walk verbatim — no gated path exits it (close refuses,
  release refuses/no-ops on status). After: `ticket_set_status` → open
  (with reason) then `ticket_close` succeeds end-to-end.
- Table arms: each named transition executes and its decision record
  carries actor + reason (verify by re-reading the ticket from the
  store, never from verb returns — the CX-3nf4 lesson). Each refused
  edge refuses naming from/to/legal set: at minimum any→in_progress,
  non-closed→closed (pointer to ticket_close), and a
  missing/empty-reason refusal.
- Reopen: closed→open and wontfix→open record reopen-with-reason;
  close-requires-open still holds afterwards (reopened ticket can close
  again).
- Custody-silence controls: claim then release leaves status UNCHANGED
  (the retraction pinned as a regression test); close on
  in_progress-WITH-claim still refuses until release.
- CLI single-door arm: the bd-CLI status path hits the same table
  (red-first: today it writes arbitrary valid-set values under
  permissive).
- Do NOT touch the live ticket CX-3hv0 — walking it through the new
  verb is the operator's live-store follow-up.

## Gates

Ticket verb + claim + close-gate + WriteGuard test files, then FULL core
suite (mix test apps/commonplace/test) + `mix compile
--warnings-as-errors`; counts reported. Tmp stores only; fixture
signing contexts (trust anchors empty in the sandbox).

## Deliverable

Work left UNCOMMITTED for the operator to land. Report: the table as
shipped, red-first verbatim for the trap walk and the CLI arm, refusal
texts verbatim, test counts, deviations.
