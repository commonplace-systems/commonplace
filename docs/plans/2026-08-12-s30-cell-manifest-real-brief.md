# S30 build brief: the cell manifest becomes REAL — CX-brxx (runner arc, Track A round 1)

> **The work's ticket is CX-brxx.** Any doc line citing a ticket cites
> CX-brxx — no other id. Context roles only, none the citation: the
> schema is plan's `docs/plans/2026-08-12-cell-manifest-schema.md`
> @b8d8154 in the commonplace-plan repo (carried below where needed —
> cite-a-mechanism: the implementer's repo is THIS one, so the schema's
> operative content is restated here, not referenced across repos);
> e2a6e0e is the S20 `__reflog` registry-amendment precedent; S1b/S2v2-v4,
> b38c, fm7x, S23 are the rulings the schema composes.
> This brief is transcription: the schema doc already made every design
> decision. Where it is silent, STOP rather than decide.

## What lands (and what deliberately does not)

S30 makes the birth certificate REAL for the existing population: the
manifest module, its registry entry, its gated write path, its validator
with named refusals, and a backfill function whose real-store runs are
the OPERATOR's daylight step. **S30 does NOT build any runner step** —
provisioning (S32) consumes the validator later; the mint ceremony (S33)
turns `authors_code` into a cert later. A manifest field never CARRIES
authority — certs are referenced by CID only; if any part of the build
seems to need the manifest to BE authority, stop: that is the second
trust root rejected at S2v3 and b38c.

## Tasks

1. **Manifest module** (suggest `Commonplace.Cell.Manifest`; naming
   yours): struct + encode/decode for the schema's fields —
   `id, parent, mission, principal, workspace_class, root_entries
   (amendments only), authority{certs[], authors_code, scope_note},
   sync_scope{rule, excludes[], binary_extensions}, sla{tier, retention,
   note}, environments{may_declare, requires_allowed[]}, stewards[],
   auditors[], escalate_to, outputs[], environment_faced[]` — stored as
   a JSON text doc, the substrate's standard content shape.
2. **Registry amendment**: the manifest entry is ABSENT from
   `workspace_root_write_policy.ex` `@registered_entries` (:35) — add
   **`"__cell.json"`** for `:default` AND `:minimal`. The name is
   DECIDED, by the registry's measured semantic convention (2026-08-12,
   reviewer-verified at the attach sites, not inferred from the list):
   bare dunder names are DIRECTORIES (`__recipes`/`__pulls`/`__system`
   attach via dir creation, `__reflog` is the snapshot branch dir);
   suffixed names are SINGLE CONTENT DOCS with the suffix stating the
   kind (`__processes.json` and `__bursar.json` are `:text` JSON docs,
   `__git-bridge.bot` a presence doc). The manifest is a single JSON
   doc, so it takes the doc convention — which also matches the schema
   doc's `__cell.json` verbatim. State this rule in the registry's
   moduledoc line for the new entry so the next addition inherits the
   discrimination instead of the ambiguity. Precedent: the S20
   `__reflog` row (e2a6e0e), including its comment style. Red-first: a
   `:minimal` root attach of `__cell.json` REFUSES before the
   amendment, lands after — both directions in one test, the e2a6e0e
   shape.
3. **Gated write path**: manifest create/amend threads
   `:signing_context` like every governed write; root attach goes
   through the existing chokepoint (no new write ingress, no new
   WriteGuard class — the attach seam and doc-write gates already
   govern this).
4. **Validator with NAMED refusals** (`validate/1` or similar): every
   schema constraint that can be checked statically refuses with the
   FIELD NAMED — the enforce-from-birth generalization. Statically
   checkable now: required fields present and typed; `workspace_class`
   is a known class; `auditors` disjoint from `principal` (the
   independence rule); `sla.tier` in the enum with `retention` required
   for `ephemeral`; `sync_scope.excludes` present when rule is
   git-tracked-set (S1b: absent scope refuses); `authority.certs` all
   CID-shaped. NOT checkable now (don't fake it): cert existence/validity
   (mint ceremony's), pod `requires` matching (S31's).
5. **Temporal exception** (S2v2 verbatim): reading the manifest of a
   PRE-FIELD workspace (no `__cell` entry) returns the class default,
   distinguishable from an error; POST-field workspaces always have one
   (the runner writes it at birth — later). The exception self-retires;
   its read path must say which case it took.
6. **Backfill function** for existing workspaces, S24-backfill-pattern:
   confirmation-gated, takes the manifest values as input, writes doc +
   root attach through the gated path, verifies by re-read.
   **Real-store runs are NOT yours**: cell-3 (root 0eadae3e, values
   from its evidence docs: id cell-3, parent commonplace-factory,
   mission "Contribute to yelixer via chit", principal
   0f38d1b7-6ab8-484b-a98f-c0ddcff7dc69, class minimal, excludes
   [".beads", ".claude"], rule git-tracked-set) and the factory root
   (default class, durable SLA, full root-entry set) are the OPERATOR's
   daylight step — name them UNVERIFIED in the report.

## ⛔ Escape hatches, up front

- A field value the evidence does NOT determine (cell-3's `auditors`
  needs a real second principal; `sla.tier` for cell-3 is not ruled
  anywhere I can cite) → the backfill fixture uses a placeholder ONLY in
  tests; for the real-store input, STOP and report the undetermined
  fields — the operator supplies them. Do not invent governance values.
- If the registry amendment needs anything beyond adding the row
  (grammar change, new class semantics) → STOP, that is plan's.
- If the manifest write path would need a NEW gate or a WriteGuard
  change → STOP; the existing seams should suffice and a new one is a
  design call.
- Telemetry events in scope: NONE.

## Tests (red-first; suites named with on-main counts)

Baseline: full core 3,400/0 + 1 skipped @016db3b8 (S28 may land first —
take the then-current baseline and say which).

- Registry arm (task 2): refuse-then-accept, both directions.
- Validator arms: one per named refusal (missing field, unknown class,
  auditors==principal, bad tier, ephemeral-without-retention,
  tracked-set-without-excludes, non-CID cert ref) — each asserts the
  refusal NAMES its field; plus one fully-valid manifest accepted.
- Temporal arm: pre-field workspace fixture reads class default WITH the
  which-case marker; post-field fixture reads the stored manifest.
- Backfill arm: fixture workspace backfilled end-to-end, verified by
  re-read (doc content + root entry both), idempotent re-run is a
  visible no-op not a duplicate.
- Round-trip: encode→decode byte-stable for a full manifest.
- Prove any "pre-existing/unrelated" failure with an isolated rerun —
  licenses "outside this diff's footprint", not "flaky under load".

## Review criteria

Registry row matches the e2a6e0e precedent's shape; every validator
refusal carries its field name (grep-able); temporal read states its
case; no authority carried in the manifest (references only — reviewer
greps for any capability construction in the module); backfill
re-read-verified and confirmation-gated; real-store runs named
UNVERIFIED-operator; undetermined governance fields reported not
invented; the registry moduledoc carries the dir-bare/doc-suffixed
naming rule alongside the new `__cell.json` row.

## Filing path (standing)

Findings file through the gated `ticket_create` verb (tix). bd is a
frozen archive and answers "no issue found" for everything since
2026-08-05. A round that cannot file via the verb reports identities for
the operator, stated as a deviation.
