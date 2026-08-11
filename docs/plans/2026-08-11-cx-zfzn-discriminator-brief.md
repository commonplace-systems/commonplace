# CX-zfzn discriminator brief: reproduce-or-refute the pending-item remove no-op — MEASUREMENT ONLY

> BUFFER ITEM — dispatch when the Sol lane empties. No serve dependency.
> ⛔ This is a MEASUREMENT brief: the deliverable is a red test or an
> enumerated refutation. NO FIX in this round regardless of what you find —
> the fix shape depends on the answer and is chosen elsewhere.

## ⛔ Escape hatch, up front

Stop and REPORT if reproducing seems to require anything beyond
Yelixer/Schema/DocBuilder public APIs and tmp-dir stores — e.g. if the live
incident's state seems unreachable through the public write path. A clean
"cannot construct the state via public APIs" is itself one of the possible
answers (it would point at a different mechanism), not a failure of the
round.

## The observed defect (CX-zfzn, live 2026-08-10 ~21:57Z — its description carries the full chain)

During a sync pass over a cell store, `Watcher.apply_delete` for schema
entry "bd" produced a signed commit whose full-state update STILL CONTAINED
the entry being deleted — the remove was silently ineffective and the
re-encode re-asserted it. In the same pass, the identical operation on
"chat" worked (proper tombstone). The emit-time reconstruction showed bd's
item in the Doc's `client_pending` (unintegrated) while chat's was
integrated. A LATER `Schema.remove_entry` against the settled fold DID work.

## The hypothesis to confirm or refute

`Commonplace.Tree.Schema.remove_entry/2` (or the Yelixer delete underneath)
silently no-ops when the target entry's item is still in `client_pending`
rather than integrated into the block store — and
`Yelixer.Encoding.encode_update/1` of the resulting doc then re-emits the
item with no tombstone.

## The protocol

1. Construct a schema doc whose entries arrive in a way that leaves one
   entry's item PENDING at read time. Candidate constructions to try, in
   order, reporting which (if any) achieves a pending item (verify via the
   Doc struct's `client_pending` field before proceeding — constructing the
   state is the hard half, and claiming it without checking is the failure
   mode):
   a. Reconstruct a doc from a chain whose commits interleave clients (the
      live case: an unsigned birth commit adding two entries + later
      full-state commits from a different client) — mirror the shapes in
      CX-zfzn's description (17-commit chain, birth client, import client).
   b. `apply_update` of updates in an order that leaves a dependency gap.
2. With a pending target: `Schema.remove_entry(doc, name)` →
   `Schema.entries/1` still lists it? → `encode_update` + fold into a fresh
   doc → still present, no tombstone? Each step's result recorded.
3. CONTROL (must pass): same operations on a doc where the item IS
   integrated → entry removed, tombstone present after round-trip. This is
   the arm that proves the instrument can see a working remove.
4. Deliverable: a test file (added to the yelixer or commonplace test tree,
   whichever the construction lives in) whose assertions encode the
   CURRENT behavior question — if the hypothesis holds, the test is RED
   with the no-op demonstrated and the control green; if refuted, ALL
   green and your report enumerates which constructions you tried, what
   `client_pending` contained in each, and why the live state remains
   unexplained. Either answer is a full success for this round.

## Gates

- The new test file runs standalone with counts reported; do not run
  umbrella or full-app suites (nothing else is touched).
- `mix compile --warnings-as-errors` clean.
- Tmp-dir stores only.

## Deliverable

One commit (test + nothing else), not pushed. Report: which construction
achieved pending state (with the `client_pending` evidence), step-by-step
results, the control result, and the verdict — REPRODUCED / REFUTED /
STATE-UNREACHABLE — with no fix proposed.
