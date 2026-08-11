# S5 build brief: every gated-reachable ticket state has a gated exit — the in_progress-without-claim trap closes

> ✅ RATIFIED by plan (msg 11200) — dispatchable. The basis is stronger than
> the parsimony this brief argued from: this is the five-axes derivation in
> miniature — status was one field carrying TWO axes (custody AND decision),
> and the stranded state is custody-released with the mirror still asserting
> in-progress. Release-resets-to-open makes the mirror follow the axes:
> custody ended, no decision was made, the projection reads eligible — which
> is also the frontier semantics the lease design already assumes.
> Alternatives killed on their own terms: close-accepts-stranded records a
> completion decision nobody made (a false durable fact, worse than the
> trap); a reset verb adds gated surface for a state that should not exist.
>
> TWO FORWARD-BINDING CONDITIONS (plan's), for the builder and the record:
> ① The reset is a PROJECTION update, never an erasure — history keeps
>   claimed→released as facts; candidate/work artifacts survive; "back to
>   open" must not read as "nothing happened."
> ② The rule generalizes BY NAME to every custody-ending-without-decision
>   transition: voluntary release now; lease EXPIRY and FORCED RELEASE
>   inherit this ruling when the progress-witness TTL work lands.

> Basis: CX-2jq6, whose mechanism is ALREADY MEASURED in the ticket (the
> 2026-08-05 verb walk): a ticket can sit `in_progress` with NO claim token
> (the cutover import minted display status without custody); `ticket_close`
> refuses ("not open"), `ticket_release` refuses ("not claimed"), and
> claim-then-release SUCCEEDS but leaves `status=in_progress` because
> release clears `claimed_by` WITHOUT resetting the status mirror — so
> close still refuses. Live instance: CX-3hv0. Plan's ruling (msg 11165):
> the live trap closes NOW; the five-axes derivation retires the class
> LATER (not this round).

## ⛔ Escape hatch, up front

Stop and REPORT if:
- The status mirror turns out to be written by something other than the
  claim/release verbs (a second writer would mean the mirror has its own
  drift class and the fix belongs at that writer too — enumerate writers
  of the status field as your first step and report the list either way).
- Fixing release seems to require touching WriteGuard's close-gate
  semantics ("close requires open" is CORRECT and stays; the defect is the
  state that can't reach open, not the gate).

## The property

1. `ticket_release` resets the status mirror to `open` when it clears
   custody — release means released: no claim AND no stale in_progress.
2. The stranded-state exit exists: a ticket in `in_progress`-without-claim
   can reach closed through gated verbs alone (the measured walk
   claim → release → close now succeeds end-to-end).
3. No new verb, no gate weakening: close still requires open; claim/release
   semantics otherwise unchanged; every write stays on the gated surface.
4. The live instance CX-3hv0 is NOT fixed by hand in this round — the
   deliverable is the verb behavior; walking the real ticket through the
   fixed verbs is the operator's follow-up (it is a live-store write).

## Tests (red-first, driving the SAME gated verbs the ticket's walk used)

- RED-FIRST: construct in_progress-without-claim (import path or direct
  store write with fixture context — mirror the cutover residue), then the
  measured walk on unmodified code: close refuses, release refuses,
  claim+release leaves in_progress, close refuses again (record verbatim).
  After: claim → release yields status=open, claimed_by nil; close succeeds.
- Direct release of a normally-claimed open→in_progress ticket: status
  returns to open (the general property, not just the stranded case).
- Control: close on a genuinely open ticket unchanged; close on
  in_progress-WITH-claim still refuses until release (the gate holding).
- Verify by re-reading the ticket state from the store after each verb,
  never from the verb's return alone (the CX-3nf4 lesson).

## Gates

Ticket verb + claim + close-gate test files, then full core suite; counts
reported. `mix compile --warnings-as-errors` clean. Tmp stores only.
⚠️ Sandbox: fixture contexts; trust anchors empty in here.

## Deliverable

Work left UNCOMMITTED for the operator to land. Report: the status-field
writer enumeration, red-first verbatim, test counts, deviations.
