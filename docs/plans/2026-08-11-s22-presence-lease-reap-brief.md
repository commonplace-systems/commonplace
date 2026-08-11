# S22 build brief: the presence reap becomes the lease family's first member — CX-9jds

> Plan's ruling (msg 11280/11281), transcribed whole. Slot S22, BEHIND
> S20/S21 (the enforce denial is containing the defect; permissive
> damage is display-severity). The measured mechanism (CX-9jds, from
> the bba7d56 boot capture + live store reads): the bridge presence
> lands signed then never heartbeats; Presence.Reaper's global 30s TTL
> marks it permanently stale; the reaper's unsigned root removal is
> DENIED every cycle under enforce and it logs "removed 1 stale
> entries" after each denial; under permissive the same pair silently
> deletes the bridge presence 30s after every boot.
>
> ⭐ THE FAMILY CONSTRAINT (plan's, binding): reaper-expiry and the
> coming Green-lease expiry are ONE mechanism family — build the
> family's FIRST MEMBER, not a one-off, and LEAVE THE SEAM NAMED for
> the progress-witness lease work to plug into (a module doc naming
> the seam and what plugs in is the deliverable form).

## The ruled design

1. ⭐ AUTHORITY IS THE OWNER'S, PRE-SIGNED; EXECUTION IS THE NODE'S,
   SCOPED. The presence entry carries its TTL as an OWNER-SIGNED field
   AT CREATION — "remove when expired-unrenewed" is consent given at
   signing time (the lease pattern verbatim: expiry pre-agreed at
   issuance). The reaper needs no authority OVER the entry; it executes
   authority already IN it.
2. The node signs the removal as SCOPED JANITOR: the write is valid
   ONLY against an entry whose own TTL is expired, and the removal
   commit CARRIES ITS EVIDENCE (last-heartbeat, TTL, now) so the reap
   is verifiable from the record, never trusted. (Why neither half
   alone: node-decides-presence is ambient authority, rejected on the
   model's grounds; owner-only leaves crashed principals unreapable.)
3. ⛔ THE 30s GLOBAL CONSTANT DIES: TTL becomes a PER-ENTRY field, set
   per class at creation (player-interactive vs service/bot classes —
   propose the class values with a stated basis; the constant's only
   remaining role is a declared per-class default). Migration rides the
   S2v2 TEMPORAL-EXCEPTION pattern: pre-field entries get the declared
   per-class default, new entries always carry the field explicitly,
   and the exception self-retires (a versioned marker distinguishes
   legacy-absent from post-field corruption, same as workspace_profile).
4. (Separate defect, same round) THE BRIDGE HEARTBEATS: a persistent
   participant asserting "present" forever off one boot-time heartbeat
   is a liveness lie independent of any reaper. The GitBridge gains a
   heartbeat cycle (signed as itself, riding its existing presence
   carve) at an interval with a stated basis vs its declared TTL.
5. (Own defect) VERIFY-BY-EFFECT AT THE REAPER: the log line derives
   from the WRITE RESULT — landed / denied / skipped reported
   DISTINCTLY; a denial is an ERROR line, never a success count. Under
   permissive, the scoped reap (valid only against
   genuinely-expired-per-own-terms entries) no longer fires on a
   heartbeating bridge at all.

## ⛔ Escape hatches, up front

- If the owner-signed TTL field cannot ride the existing presence doc
  shape without a new durable record shape beyond a map key — stop;
  record shapes are plan's.
- If scoping the janitor signature ("valid only against expired
  entries") cannot be expressed as a checkable property of the removal
  commit (the evidence fields) plus a gate-side check, and seems to
  need a new trust verb — stop and report the seam.
- If migration finds presence entries that are neither legacy-absent
  nor well-formed — the torn-state is a finding, name it.

## Tests (red-first, driving the measured loop)

- RED-FIRST (the measured pair): fixture bridge presence + enforce; on
  unmodified code the reaper's removal is denied AND the success line
  logs (capture both). After: the reap carries the node-janitor
  signature + evidence fields, lands, and the log reports the landed
  outcome; a denial arm (construct one — e.g. gate refusing) reports
  ERROR, never a count.
- Scope pin: a reap attempted against a NON-expired entry (fresh
  heartbeat within its own TTL) is REFUSED/refuses-to-fire — the
  janitor scope holding (the arm that makes "scoped" a property, not a
  comment).
- Per-class TTL: entries created with explicit TTLs honor them; a
  legacy-absent entry gets the declared class default (temporal arm);
  the bridge's class outlives the old 30s constant.
- Bridge heartbeat: the presence doc's heartbeat advances across the
  interval (fixture clock or real wait with basis); reaper does not
  fire on it under permissive OR enforce.
- Under-permissive control: the silent-delete pair is dead — a
  heartbeating bridge survives; an expired entry still reaps.
- ⭐ THE SEAM: module doc names where lease-expiry plugs in
  (progress-witness TTL work) and the test file carries one
  commented-out-or-skipped named placeholder arm for it — the seam
  visible in the artifact, not the report.

## Gates

Presence + reaper + GitBridge test files, then FULL core suite (mix
test apps/commonplace/test) + `mix compile --warnings-as-errors`;
counts reported. sol-run.log is the OPERATOR'S artifact — never delete
it; no repo-wide formatting; work UNCOMMITTED.

## Deliverable

Report: the entry-field shape as shipped, per-class TTL table with
bases, the janitor-scope pin demonstrated, red-first verbatim (both
the denial and the false-success line), the named seam quoted, test
counts, deviations.
