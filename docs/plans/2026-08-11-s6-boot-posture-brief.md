# S6 build brief: boot-record truth-telling — the absent-config census, the loud posture fact, and CX-f4vv's named refusal

> Plan's rulings (msg 11165): the absent-config posture is FINALIZED —
> absence is not consent, permissive must be WRITTEN, observe-then-require.
> Step 1 is a loud named boot fact. CX-f4vv rides with it: loud-at-boot
> refusal IS the intended posture for boot-publish failure, so its fix is a
> NAMED refusal replacing the bare `:ok =` match — "the improvement is the
> name, not survival." One brief, one area, both boot-record truth-telling.

## ⛔ Escape hatch, up front

Stop and REPORT if the census (part A) finds a knob whose absent-default is
AMBIGUOUS in code (two readers defaulting differently) — that is a finding
that must reach plan before the boot fact can print a truthful line for it.

## Part A — the census (measurement; the enumeration IS a deliverable)

Enumerate EVERY config knob whose ABSENCE silently selects a posture.
Known members to seed the sweep (find the rest by grepping config reads
with defaults in trust/gate/boot paths): `COMMONPLACE_LOCAL_WRITE_GATE`
(absent => dry_run), `COMMONPLACE_LOCAL_READ_GATE` (absent => permissive,
CX-579x), trust.json absent => accept_unsigned: true (CX-1ern),
`COMMONPLACE_REFLOG_ON_BOOT` (absent => off). Deliverable: a table —
knob / absent-default / posture it selects / where read (file:line) —
committed as a doc (docs/notes/), because the table is the census the
later require-step will be measured against.

## Part B — the loud named boot fact

At boot, ONE log block states the resolved posture of every censused knob
WITH its provenance: `local_write_gate: :dry_run (ABSENT — defaulted)` vs
`local_write_gate: :enforce (env)`. The existing `Trust.posture at boot`
line is the anchor — extend it (or add its sibling) so ABSENT-DEFAULTED and
EXPLICITLY-SET are distinguishable in every boot record. No behavior
change: postures resolve exactly as today; only the RECORD becomes honest.
(Observe-then-require: this is the observe half; requiring written
permissiveness is a later ruled step, not this round.)

## Part C — CX-f4vv's named refusal

`application.ex:14`: `:ok = Commonplace.Crypto.NodeIdentity.publish_public_keys_at_boot()`
— a bare hard-match; any `{:error, _}` is an anonymous MatchError in
Application.start. Plan ruled the POSTURE correct (a node that cannot
publish its keys must not boot quietly) and the defect is the ANONYMITY.
Replace with a named refusal: on error, log a named, self-explaining line
(what failed, why the node refuses to boot, what to check) and halt boot
DELIBERATELY (raise/exit with the named reason — still fail-closed).
Success path unchanged.

## Tests (red-first)

- B: boot a fixture app/config context with a knob absent → the boot fact
  line marks it ABSENT-defaulted; set it explicitly → marked env-set.
  Assert on the LOG CONTENT (capture_log), not on posture resolution
  (which is unchanged and already tested elsewhere).
- C RED-FIRST: force publish_public_keys_at_boot to return {:error, term}
  (fixture: unwritable artifact dir) → unmodified code dies with an
  anonymous MatchError (record it) → after: boot still refuses but the log
  carries the named reason. Success-path boot unchanged.
- A has no tests — its deliverable is the committed table.

## Gates

Boot/application/trust test files + full core suite; counts reported.
`mix compile --warnings-as-errors` clean.
⚠️ Sandbox note for part C's fixture: the node key artifacts are masked in
here — that masking is itself an error-path constructor you may use, but
name it in the test setup so the fixture doesn't look like magic.

## Deliverable

Work left UNCOMMITTED for the operator to land. Report: the census table
(also committed as the doc), red-first verbatim for C, the log-content
evidence for B, test counts, deviations.
