# S31 build brief: pod-profile format + `requires` matching — CX-3shs (runner arc, Track A round 2)

> **The work's ticket is CX-3shs.** Any doc line citing a ticket cites
> CX-3shs — no other id. Context labels, none the citation: CX-brxx is
> S30 (the cell manifest, building concurrently — S31 does NOT depend
> on it); the manifest schema and the dev-environments answer are plan
> docs whose operative content is restated below (cite-a-mechanism:
> this repo is the one the implementer searches). This round is SMALL
> and PURE by design: a format module + a matching function + tests.
> No storage, no gating, no wiring — those are S32's.

## The ruled design (transcription; the decisions are made)

Two documents, two owners (manifest schema §1): the **cell manifest**
(substrate, gated — S30's) declares identity/authority/scope; the **pod
profile** is the RUNNER's vessel-inventory document — what the vessel
CONTAINS: harness identity, sandbox shape, and the **service inventory**
(`postgres` etc.) that `requires` matches against.

`requires` comes from the Dirigible measurement (the first real app
forced the field): **named service requirements WITH VERSIONS** —
`{postgres: ">=14"}`. The contract, verbatim in substance from the
ruling: **satisfaction is the PLACEMENT's job: satisfy or REFUSE,
loudly** ("this placement cannot satisfy requirement postgres").
Closed-by-default — **the cert pattern applied to services: declare,
satisfy-or-refuse, never infer.** The substrate matches requirements to
placements and refuses; it NEVER provisions, migrates, or manages a
service (jes's no-devops fence — build caching, registries, migration
orchestration, service discovery all stay OUT).

## Tasks

1. **Pod-profile format module** (naming yours; somewhere
   runner-shaped, e.g. `Commonplace.Runner.PodProfile`): struct +
   decode/validate for the vessel inventory —
   `id`, `harness` (identity string), `sandbox` (shape identifier),
   `services` (map: service name → provided version, e.g.
   `%{"postgres" => "16.2"}`). Validation refuses with the FIELD NAMED
   (S30's validator idiom; the two rounds should read as siblings).
   Keep the field set to what the rulings name — an inventory field
   nobody ruled is speculative padding.
2. **The matcher**: `requires`-vs-profile →
   `:ok | {:refused, [named unsatisfied requirements]}` where each
   refusal names the SERVICE and the unmet requirement in the ruled
   sentence shape ("this placement cannot satisfy requirement
   postgres >=14"). Properties: closed-by-default (a required service
   ABSENT from the inventory refuses — absence is never satisfaction);
   ALL unsatisfied requirements reported, not first-failure (the
   operator fixing a placement wants the whole list); empty `requires`
   matches any profile (a cell that needs nothing places anywhere).
3. **Version-requirement semantics — state them, don't inherit them.**
   The ruled example is `{postgres: ">=14"}` against an inventory like
   `"16.2"`. Elixir's `Version` is semver-strict and `"14"` is not
   semver, so the semantics need a stated choice (normalize to
   major[.minor[.patch]] with numeric comparison is the obvious one).
   Whatever you choose: state it in the moduledoc, make
   `{postgres: ">=14"}` vs `"16.2"` → satisfied and vs `"13.1"` →
   refused the acceptance pair, and refuse UNPARSEABLE requirement or
   inventory strings loudly (an unintelligible requirement is never
   satisfied — closed-by-default again). If you find the semantics
   genuinely need a design ruling (exotic operators, non-numeric
   versions), STOP and report; do not invent a grammar beyond what the
   measured example needs.

## ⛔ Escape hatches, up front

- No storage, no root entries, no gated verbs, no registry rows — the
  profile is runner-side by ruling and its persistence home arrives
  with S32. If any task seems to need substrate wiring, stop.
- No provisioning behavior of any kind — the matcher REPORTS; nothing
  in this round starts, installs, or checks a live service. A
  `pg_isready`-shaped call anywhere is the fence breached.
- S30 collision: none expected (different modules), but if S30's landed
  code offers a shared validation idiom worth reusing, reuse it and say
  so rather than duplicating.
- Telemetry events in scope: NONE.

## Tests (red-first; suites named with counts)

Baseline: take the then-current full core count and SAY IT (S30 may
land first; my last measured baseline is 3,403/0 + 1 skipped
@93b105bc — reconcile against whatever main you base on).

- Acceptance pair: `{postgres: ">=14"}` vs `"16.2"` satisfied; vs
  `"13.1"` refused with the ruled sentence naming postgres.
- Closed-by-default arm: required service absent from inventory →
  refused naming the service.
- All-unsatisfied arm: two unmet requirements → BOTH named.
- Empty-requires arm: matches any profile including an empty one.
- Unparseable arm: garbage requirement string → loud refusal, never
  satisfied.
- Validator arms: each profile field refusal names its field.
- Prove any "pre-existing/unrelated" failure with an isolated rerun —
  licenses "outside this diff's footprint", not "flaky under load".

## Review criteria

Matcher pure (no IO, no process calls — reviewer greps for
GenServer/File/System in the module); refusal sentences carry service +
requirement; closed-by-default holds in all three absence shapes
(missing service, unparseable requirement, unparseable inventory);
version semantics stated in the moduledoc with the Dirigible example;
field set no wider than the rulings; S30-idiom reuse stated if taken.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). bd is a
frozen archive and answers "no issue found" for everything since
2026-08-05. A round that cannot file via the verb reports identities
for the operator, stated as a deviation.
