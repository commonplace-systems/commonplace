# S12 build brief: the read-gate resolver — same defect class, one door over

> Plan's placement (msg 11236): the CX-579x-side residual documented in the
> S6 census rides as ONE brief. The just-landed S6v2 diff (@c15f91b) is
> LITERALLY the template — read it first and mirror it: resolver, inert
> string, boot refusal, source-scan pin. Lowest-judgment item in the queue
> by design; deviations from the template need naming, not invention.

## The measured defect (census row, docs/notes/2026-08-11-s6-absent-config-posture-census.md)

`:local_read_gate`: absent defaults `:permissive` (multiple readers,
hand-kept). Invalid env value: runtime.exs's read-gate bridge
`String.to_atom`s the raw string, the mint succeeds silently, and the
FIRST GATED READ later dies with `CaseClauseError` — boot itself does not
refuse. Same class the write gate closed at S6v2: a typo'd posture value
that resolves to *something* instead of refusing to *anything*.

## The build (mirror the template)

1. `Trust.local_read_gate/0` + `local_read_gate_resolution/0` in trust.ex,
   beside the write-gate resolver: absent → `:permissive`
   (`:absent_defaulted`), valid set exactly `permissive | dry_run |
   enforce` accepted as atoms or inert strings, anything else raises the
   named refusal listing the valid set.
2. runtime.exs read-gate bridge keeps the raw env STRING inert — its
   `String.to_atom` dies like the write gate's did.
3. Every production reader of `:local_read_gate` migrates to the resolver
   (enumerate them first; Trust.Read.gate/3 at read.ex:188 and posture/0
   are known; report the full list).
4. Resolve at application start before supervisor children, same as the
   write gate — an invalid explicit read-gate value refuses the whole boot.
5. The S6 boot posture block's `local_read_gate` line gains resolver
   provenance (it currently reads the raw app env for source).
6. Census row for the read gate updated: invalid-value column now says
   named boot refusal; the CaseClauseError hazard becomes red-first
   evidence, not current behavior.

## Mandated arms (mirror S6v2's, red-first where behavior exists)

- Resolver unit arms: absent → :permissive; each valid value (atom and
  string forms); invalid → named refusal, text captured verbatim.
- RED-FIRST: record what unmodified code does with an invalid read-gate
  value (the silent mint, then the CaseClauseError at first gated read).
- SINGLE-READ PIN: extend or sibling the existing source-scan test —
  the only production `get_env(:commonplace, :local_read_gate` site under
  apps/*/lib is the resolver; red-first against current code (the raw
  readers make it fail; record the before-list).
- Behaviour-preservation: existing read-gate tests pass unchanged;
  posture resolution identical for absent and valid-set values.

## ⛔ Escape hatch, up front

Stop and REPORT if the reader enumeration finds a read-gate reader whose
absent default is NOT `:permissive` (a second absent-default fork means
the census was incomplete and plan should see it before the resolver
freezes the default), or if any reader consumes the raw value in a way
atoms-or-strings normalization cannot preserve.

## Gates

Trust/read/boot test files + FULL core suite (mix test
apps/commonplace/test) + `mix compile --warnings-as-errors`; counts
reported. Tmp stores only.

## Deliverable

Work left UNCOMMITTED for the operator to land. Report: reader
enumeration, red-first verbatim (invalid mint + pin before-list), refusal
text verbatim, census diff, test counts, deviations.
