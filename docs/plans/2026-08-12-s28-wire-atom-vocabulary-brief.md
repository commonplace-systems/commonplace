# S28 build brief: the wire-format atom universe catches up with proto-chit and gains a drift guard — CX-7cpf

> **The work's ticket is CX-7cpf** (federation envelope safe-decode
> fragile to the receiver's lazy-interned atom table). Any doc line
> citing a ticket cites CX-7cpf — no other id. Context roles only:
> CX-5983/S26 is the adoption fix this finding rode along with;
> plan ranked CX-7cpf a runner-arc precondition (#11413 ②-adjacent,
> board ruling of 2026-08-12) because every remote cell is a fresh
> receiving BEAM.

## ⭐ Re-derived TODAY — the fix pattern already exists; the defect is DRIFT

`Commonplace.Federation.Envelope` has carried the ruled mechanism since
2026-06-12 (@wire_atoms, landed with CX-orfw Phase D): the wire format's
CLOSED atom universe is declared in the module and interned at module
load, precisely so `binary_to_term([:safe])` (decision D12 — never
unsafe decode) works on a fresh VM. Its own comment says "Grow the list
when the metadata vocabulary grows." **The vocabulary grew and the list
did not**: proto-chit landed later and emits
`metadata: %{kind: :regular, proto_chit: true}` (proto_chit.ex:278) —
`:proto_chit` is absent from @wire_atoms, so a fresh peer rejects a
proto-chit commit as `:bad_payload` until something else happens to
load the ProtoChit module. Proven live twice: slice-2's first pull
(2026-08-11, the finding's origin) and the pre-force-load control in the
slice-2 completion run (2026-08-12, evidence-full/42). This is NOT
"build safe-decode interning" — it is "the declared universe drifted;
close the gap AND make the next drift turn something red before a live
peer refuses."

## Tasks

1. **Enumerate the current wire metadata vocabulary — measured, not
   assumed.** Every atom that can appear in a `Commit` struct or its
   `metadata` map as written by any current emitter (proto-chit,
   reflog/snapshot, bd creation markers, lease/presence writers, merge
   machinery — sweep the writers, don't trust this parenthetical).
   Report the list with file:line per atom. The known-missing member is
   `:proto_chit`; there may be others younger than 2026-06-12
   (candidates to check, not conclusions: `:bd_issue_doc_created`,
   `:bd_terminal_pin`, lease fields — an atom only matters here if it
   rides a commit that CROSSES the federation wire, so state for each
   whether it does).
2. **Grow `@wire_atoms`** to cover the enumerated set. Keep it a
   declared literal list — that is the mechanism's point.
3. **The drift guard.** PROPERTY: growing the wire metadata vocabulary
   without growing @wire_atoms must turn a test red BEFORE a fresh peer
   refuses live. Shape is yours; a hand-copied second list in a test
   merely moves the drift one file over, so prefer a form where the
   emitters' vocabulary is derived or declared once and compared. If
   every honest form needs emitter-side declarations (a design change),
   STOP at the hatch and report the options instead of building one.
4. **Fresh-VM red-first.** The failing condition is an atom table that
   never loaded the emitting modules, which an in-suite test cannot
   reproduce (the suite's VM interns everything). The honest arm spawns
   a bare VM: `System.cmd` an `elixir -pa <ebin dirs>` script that loads
   ONLY Envelope and decodes a proto-chit envelope fixture — red on
   current main (`{:error, :bad_payload}`), green after the list grows.
   One spawned test, tagged if slow. If the bare-VM arm proves
   infeasible in the suite, say so and ship the closest in-VM
   approximation NAMED as an approximation — do not let the
   approximation masquerade as the fresh-VM claim.

## ⛔ Constraints and escape hatches, up front

- **NEVER `binary_to_term` without `[:safe]`** — the unsafe form is an
  RCE surface and is out of the question regardless of test pressure.
- Do NOT switch the wire metadata to JSON — D12's byte-faithfulness
  (signatures verify over exact bytes) is settled in the moduledoc;
  the declared-universe mechanism is the in-repo ruling.
- If the emitter sweep (task 1) finds an atom vocabulary that is NOT
  closed (dynamic atoms in commit metadata anywhere) — STOP: that is a
  finding, not something to paper over with a longer list.
- Telemetry events in scope: NONE. If observability wants to grow,
  name it in the report instead.

## Tests (red-first; suites named with on-main counts)

On-main baseline: apps/commonplace/test/commonplace/federation/
(envelope_test.exs + pull_client_test.exs) = 19/0, measured @016db3b8.
Full core baseline 3,400/0 + 1 skipped.

- Fresh-VM arm (task 4): red on main, green after.
- Drift guard (task 3): demonstrate it fires by removing one atom from
  the grown list in a scratch run (transcript, not a committed state).
- Decode-coverage arm: an envelope round-trip of a commit carrying the
  FULL enumerated metadata vocabulary decodes on the suite VM.
- Existing 19 federation tests stay green; full core in-round.
- Prove any "pre-existing/unrelated" failure with an isolated rerun —
  licenses "outside this diff's footprint", not "flaky under load".

## Review criteria

Vocabulary enumeration with file:line and wire-crossing stated per atom;
@wire_atoms grown to exactly the enumerated set (no speculative
padding); drift guard fires in the demonstrated direction; fresh-VM arm
red-first transcript or the named approximation with its limits; D12 and
[:safe] untouched; module comment's "grow the list" contract updated to
point at the drift guard.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). bd is a
frozen archive and answers "no issue found" for everything since
2026-08-05. A round that cannot file via the verb reports the identities
for the operator, stated as a deviation.
