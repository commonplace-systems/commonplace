# S2v3 build brief: workspace root write policy — one chokepoint at the root-attach seam

> Supersedes s2v2 after its hatch fired twice over (incomplete mint-site
> inventory; zero sentinel-capable callers). Design RULED by plan
> (msg 11190): substrate-owned root entries are DECLARED BY WORKSPACE
> CLASS, enforced at ONE chokepoint — the root-attach seam — so all
> current mint sites AND FUTURE ONES are covered by construction.
> Refusals ride the EXISTING gated-write failure channel; no sentinels.

## ⛔ MANDATORY STEP ONE — the attach-seam confirmation (measurement before build)

Confirm that EVERY inventoried mint site reaches the root through the same
attach call (the write that links a child entry into the root doc — find
the seam; Schema.add_file/add_directory feeding a root-doc chained commit
is the expected shape). The inventory, from the S2v2 run (file:line):

- chat/: application.ex:208 → Chat.TemplateBootstrap (:196)
- bd/: Bd.Workspace.ensure_bd_dir (bd/workspace.ex:46)
- __bursar.json + __bursar.log: green/bursar.ex:887 (Mode B, runtime.exs:77)
- __reflog/: reflog/snapshot.ex:564
- __system/scheduler: scheduler/agent.ex:221
- user-triggered: __identities__, __pulls/, __processes.json, imports

Deliverable of step one: per-site, the call path to the root attach. ⛔ Any
site with a PRIVATE attach path (reaching the root doc without the common
seam) is a FINDING that must be reported — the build then covers it by
closure or STOPS if the closure isn't mechanical. The chokepoint claim is
honest only after this table exists.

## The property

1. `Workspace.initialize/2` accepts and RECORDS the profile (as in s2v2:
   `:default` | `:minimal`, default `:default`, readable artifact,
   temporal absence exception with the closed-membership boundary — all
   ratified wording carries over from the s2v2 brief §1-2).
2. The profile enumerates WHICH ROOT ENTRIES the class accepts:
   `:default` = the current full set (every existing workspace and caller
   byte-for-byte unchanged); `:minimal` = the minimal set (plan: no bd, no
   chat; decide the rest of the minimal set FROM the inventory — substrate
   bookkeeping the cell genuinely needs stays, everything else is out —
   and LIST the decision in the report).
3. Enforcement at the ONE root-attach chokepoint: an attach of an entry the
   class does not accept REFUSES with a named reason
   ("workspace class 'cell' does not accept root entry 'bd' — declared in
   profile").
4. Refusal semantics per plan: BOOT HOOKS treat the refusal as
   skip-with-info (boot proceeds, one log line); lazy and user-triggered
   sites let it PROPAGATE AS AN ORDINARY GATED-WRITE FAILURE — callers
   already must handle those. ⛔ Do NOT fix the three discard-and-proceed
   callers here (CX-305k, filed, its own round) — but your tests must not
   depend on their broken behavior either.
5. Security note to carry in the code comment at the chokepoint (plan's ④):
   class-gating root writes class-gates the auto-execution mint surface —
   a cell workspace refuses __processes.json unless its class declares it.

## Tests (red-first)

- RED-FIRST on unmodified code: boot-mint chat, lazily mint bd on a fresh
  workspace → both land (record). After: `:minimal` — chat skipped at boot
  (with the info line), ensure_bd_dir's attach REFUSES through the gated
  channel, root schema clean of both — asserted by reading the schema back.
- THE RE-MINT ARM (mandatory, carried from s2v2): second invocation of both
  paths on `:minimal` → still clean. Lifetime, not birth.
- CHOKEPOINT arm: at least one NON-bd/chat inventoried entry (e.g. the
  scheduler's) refused for `:minimal` WITHOUT any per-site code — proving
  the coverage is the seam, not the site.
- `__processes.json` refused for `:minimal` (the security arm).
- `:default` and legacy-absent workspaces: byte-for-byte today across the
  same sequences.

## Gates

Workspace/init/bd/chat/sync test files + CLI app suite + full core suite;
counts reported. `mix compile --warnings-as-errors` clean. Tmp stores.
⚠️ Sandbox: fixture contexts; trust anchors empty in here.

## Deliverable

Work left UNCOMMITTED for the operator to land. Report: the step-one
attach-path table (per-site), any private-path findings and their closures,
the ruled minimal set, red-first verbatim including re-mint and chokepoint
arms, test counts, deviations.
