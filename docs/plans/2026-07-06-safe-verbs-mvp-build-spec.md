# CX-ndvi build spec — Safe-verbs MVP (capability-bounded player code)

Author: commonplace (Fable; Sonnet implements; **commonplace-plan reviews
the SourceDoc gate-class diff + does the close review**). Design authority:
`/home/jes/commonplace-plan/docs/plans/2026-07-06-mud-safe-verbs-plan.md`
(jes-approved with leans, boss #5764). This spec translates that design
into concrete steps against code reality. Honesty boundary is LOAD-BEARING:
facade = least-authority, lint = raised bar, NEITHER is hostile-code
containment (OS isolation is phase-4, banked) — say so in every moduledoc.

## 0. What already exists (do NOT rebuild)

- **Module naming (Axis D)**: DONE by CX-9f62 — `SourceDoc.compile(uuid,
  store, unique_module: key)` derives a collision-free module per key.
  Verbs already pass their source uuid. Reuse it; do not re-derive naming.
- **Verb docs in the tree (Axis D)**: `VerbSource` already stores verbs at
  `<object>/verbs/<name>.elx` and compiles via `SourceDoc`. The registry
  (directory) exists. What's missing is the FACADE, the AUTHORITY model,
  and the DEFINE gate.
- **Section certs + auto-extend**: CX-qat5.4/qat5.5 shipped. `:define_verb`
  derives from section ownership (Axis E) — reuse the cert machinery.
- **Revocation**: CX-bepn shipped — define-grants revoke like any cert.

## 1. The two substrate seams (plan flagged; the real work)

### 1.1 SourceDoc gate-class parameterization — PLAN REVIEWS THIS DIFF

`SourceDoc.compile` hardcodes the Gate-B `:execute` check
(`source_doc.ex:121`, `Trust.authorized_to_execute?`). A verb doc must
NOT be gated on `:execute` (untrusted players never hold it) — it's gated
on `:define_verb`. Change: `compile` accepts `gate: :execute | {:verb,
section_scope}` (default `:execute`, unchanged for compute/view/black).
When `{:verb, scope}`, the pre-compile authorization runs a
`:define_verb` contributor walk over the verb doc's scope instead of the
`:execute` walk — every contributor to the verb doc must hold
`:define_verb` for that section (mirrors the Gate-B contributor walk;
reuse `Trust.walk_contributors`-family, store-threaded per CX-ziye). Keep
this diff MINIMAL and SELF-CONTAINED — plan reviews it as the
security-relevant change. Default path (`:execute`) stays byte-identical.

### 1.2 The World facade — the ONLY effect surface

New `Commonplace.MUD.World.Facade` (or `Commonplace.MUD.VerbFacade`): a
struct/handle closing over `{invoker_signing_context, owner_grant,
section_scope, store, ctx}`. The nine locked methods (jes #5764):
`look/1`, `describe/2`, `get_attr/2`, `move/2`, `set_attr/3`,
`create_child/2`, `transfer/3`, `say/2`, `emit/2`. Each domain op routes
through the standard write funnel (`CommandRouter` / the MUD write path)
with the INVOKER's signing context AND both authority checks (§2). NO
`CommitStoreClient`, NO raw store handle, NO raw uuids required in author
code. The facade is the only capability-bearing binding a verb receives.

## 2. Authority — intersection by two existing checks (Axis B)

A verb's effects are commits SIGNED BY THE INVOKER. Each facade write is
authorized iff BOTH, checked PER-EFFECT (not once per invocation):
(a) `Trust.authorized?(invoker, :write, scope)` — the invoker could do
    this write directly; AND
(b) `scope ⊆ owner_grant` — the verb's owner attached a grant ⊆ their own
    authority (monotone narrowing = "definer can't exceed own authority"
    for free).
Commit metadata carries `via_verb: {verb_doc_ref, owner}` (causal audit).
A write failing either check returns a denied result FROM THE FACADE (the
verb sees a normal error, same as the invoker doing it directly) — never
a crash, never ambient escalation. Setuid/confused-deputy (verb acting on
OWNER's property for a stranger) is OUT (phase 3) — intersection simply
denies it; that's correct MVP behavior, document it.

## 3. Execution bounds + lint (Axis A, defense-in-depth NOT containment)

- Run each invocation in a supervised `Task` with `timeout: 3_000` ms and
  `max_heap_size: 50 * 1024 * 1024` bytes (÷ word size for the OTP flag;
  compute the word count) — jes's locked 3s/50MB, tunable per world via
  config. Timeout/heap-kill → the verb fails cleanly, session survives.
- Lint v1 (AST scan pre-compile, in the verb gate path): reject source
  containing `apply`, `spawn`/`Task`/`Process`, `String.to_atom`/
  `:erlang.binary_to_atom`, `defmodule` (author writes a `run/1` body, not
  a module — see §4), and the modules `Code`, `File`, `System`, `:os`,
  `:erlang` (raw), `Node`. Reject with a clear author-facing message.
  MODULEDOC MUST STATE: lint raises the bar for hostile code but the BEAM
  cannot contain hostile Elixir — true containment is phase-4 OS isolation.

## 4. Authoring model shift (needed for substrate-controlled naming + lint)

Today authors write a full `defmodule`. For safe verbs, authors write a
`run/1` BODY (the facade is the one binding: `def run(world, args)` or a
bare body with `world`/`args` in scope). The substrate wraps it in the
derived module (reusing CX-9f62's naming) — so `defmodule` is banned by
lint (§3) and naming is fully substrate-controlled. Keep the OLD
full-`defmodule` verb path working for TRUSTED/legacy verbs (a verb doc
flagged trusted, or the pre-existing prototype verbs) behind the existing
un-gated path — MVP adds the SAFE path alongside; do not break existing
verbs. Flag the migration boundary clearly.

## 5. Define gate (Axis E)

`:define_verb` authority = section ownership (qat5.4): owners hold it
implicitly (jes lean (c)); delegates need an explicit `:define_verb` cert
(reuse `Capability.delegate` with a `:define_verb` verb). Saving/compiling
a verb doc runs the §1.1 `{:verb, scope}` gate. Revoked definer →
define-walk fails → verb stops dispatching (verify-time, consistent with
CX-bepn P1).

## 6. Test pins (security-critical — be thorough)

1. A safe verb's facade write is authorized by intersection: invoker with
   `:write` on the target + owner-grant covering it → lands, signed by
   INVOKER, `via_verb` metadata present.
2. Intersection denial: invoker WITHOUT `:write` on a doc the verb tries
   to touch → facade denies, verb gets an error, nothing lands (the
   confused-deputy/setuid case denies at MVP — assert).
3. Owner-grant narrowing: a verb whose owner-grant is narrower than the
   invoker's authority → writes outside the grant denied even though the
   invoker COULD do them directly (monotone narrowing).
4. Lint rejects: `apply`, `spawn`, `to_atom`, `File`, `System`,
   `defmodule` in a safe-verb body → compile refused with a clear message.
5. Bounds: an infinite-loop verb → killed at 3s, session survives; a
   memory-bomb verb → heap-killed, session survives.
6. Define gate: a player WITHOUT `:define_verb` for a section cannot
   save/compile a verb there (contributor-walk denial); an owner CAN;
   a revoked definer's verb stops dispatching.
7. No effect surface leak: a safe verb has NO `CommitStoreClient` / raw
   store in scope — only the facade (assert the binding).
8. Existing (legacy/trusted) verbs still compile+run via the old path
   (no regression); compute/view/black SourceDoc callers unchanged
   (default `:execute` gate byte-identical).
9. Full corpus green; `mix compile --warnings-as-errors` clean; the full
   yelixer + core + mcp suites (SourceDoc is shared).

## 7. Constraints

DO NOT SPAWN SUBAGENTS. NEVER use run_in_background — all foreground.
This is SECURITY-CRITICAL: no shortcuts on the authority checks; if a
design point can't be met against code reality, STOP and FLAG (do not
improvise the security model). Keep the §1.1 SourceDoc diff minimal +
self-contained (plan reviews it). Don't touch the trust core
(`trust.ex`/`verify_chain.ex`/`capability.ex`) beyond calling existing
functions; don't change qat5.3/qat5.4/bepn behavior. mix
compile --warnings-as-errors clean. VERIFY: yelixer suite + core +
mcp + your new tests, all foreground. COMMIT: 'CX-ndvi: safe-verbs MVP —
capability-bounded player code (facade + intersection + define gate +
bounds)'. FINAL REPORT: sha, files, per-suite counts, the §1.1 gate diff
called out for plan review, the authoring-model migration boundary,
FLAGS, pre-existing bugs.

## 8. Standing security invariants — post-closure (CX-bg1v / CX-qom0 / CX-n2j2)

The safe-verbs RCE arc closed with these results. The invited-untrusted
`@verb` lift rests on TWO structural pieces, both filename- AND
config-independent (they do NOT rely on the permissive-bypassable
`:execute`/Gate-B walk enforcing):

1. **Safe-path wiring + run-boundary re-check (CX-bg1v / CX-fhz4).**
   `@verb` authors only safe verbs (`save_safe_verb`, bare `run/2` body,
   lint + AST allowlist). `Commonplace.MUD.SafeVerb.Allowlist` is
   closed-by-default; `check_wrapped/1` runs at the `SourceDoc.compile`
   waist (`require_safe_wrapper: true`) on the STORED bytes, verifying the
   exact substrate-wrapper shape then allowlisting the inner body — so the
   `.safe.elx` filename is never trusted as a "was-linted" claim.

2. **Legacy-dispatch gate (CX-qom0).** No author-plantable legacy
   (full-`defmodule`, ambient-reach) verb is dispatchable by ANYONE. The
   player path (`Verbs.dispatch` → `run_legacy_user_verb`) passes
   `require_safe_wrapper: true`, so a legacy module is refused as
   `:not_substrate_wrapped`. `TickBot.fire` dispatches only a
   `tick.safe.elx` via the facade-bound safe path (the legacy
   `run_verb("tick")` call is removed) — a planted `tick.elx` is never
   looked up. The ONLY legacy code that runs is compiled-in system code
   that is NOT doc-sourced.

### THE FORWARD GUARD (re-check on any relevant change)

> **INVARIANT:** No invited-writable doc is a `ComputeRunner` /
> `Orchestrator` input, AND no MUD command creates a runner-input
> (view / compute-spec / `__processes.json`) doc.

This is what keeps CX-n2j2 (the ComputeRunner/Orchestrator confused
deputy — a *trusted runner executing author-plantable doc code*)
OUT of the invited threat model. It holds today by TREE LAYOUT +
REGISTRATION scope, config-independently: invited `:write` = Sections
certs over `{:docs, room/object-uuids}` (`:execute` hard-rejected);
`auto_extend_for_new_room` only adds room uuids; and the MUD command set
(`@dig @create @desc @name @alias @listen @dump @verb @link @unlink
@teleport @go`) creates NO view/compute/`__processes` doc. ComputeRunner
runs only REGISTERED sources, and registration is outside invited scope,
so compute-spec CONTENT written into a room doc is inert. (`__processes.json`
is double-closed: `.28`'s `CodeDocHeuristic` catches it at cert mint AND
MUD never creates it. The `.28`-miss class — view-XML/compute-spec — is
unreachable because no invited path registers it.)

> **REVIEW TRIGGER:** re-run the CX-n2j2 reachability analysis if EITHER
> (a) the MUD command set gains a command that creates/registers a
> runner-input doc (a future `@compute`-style command, a scripted-object
> feature that registers a view, an `@process` entry), OR (b) the invited
> `:write` grant scope widens beyond room/object docs (subtree scopes per
> CX-tdkq.23, a doc-class change). Either silently reopens CX-n2j2 for
> invited players. Do NOT add a runner-input-creating command or widen
> invited scope without re-running this analysis.

Defense-in-depth for the BROADER tier (semi-trusted non-MUD principals
who CAN reach view/compute worlds), NOT invited blockers: **CX-6g0j**
(extend `CodeDocHeuristic` to catch view-XML/compute-spec) and
**CX-n2j2** (a runtime gate on `ComputeRunner`/`Orchestrator` doc-code
execution). Both P2. **CX-n6fv** (OS-level sandbox) remains the phase-4
horizon for genuine hostile-code containment — the allowlist is
"demo-grade safe for untrusted," not a formal sandbox.

### THE OBJECT-ECONOMY TRUST PARTITION (CX-cj3t.7, plan #5991/#5993)

Every effect a safe-verb Facade write can cause falls into exactly one of
three cases — this is the WHOLE object-economy trust story, one line, the
same shape all the way down (no bespoke ACLs):

1. **Own-inventory → INVOKER-AUTHORIZED (owner_grant N/A).** Operating on
   an object in the invoker's OWN inventory is within their own authority
   (it's their property — acquired through gated take/give). `owner_grant`
   does NOT apply, because a stranger's inventory is never in the verb
   owner's grant, so requiring it would wrongly block the intended case.
   Instances: `give_to_actor` (CREATE into own inventory) and the
   inventory arm of `consume` (DESTROY a carried item). Code: the write is
   invoker-signed but SKIPS `write_guarded`; the recipient/target is
   server-fixed to the invoker (never a victim-targeting param).

2. **Owner-scope → FULL INTERSECTION.** Operating on a room / bound object
   / other owner-controlled scope requires BOTH (a) invoker-authority (the
   commit is signed as the invoker → enforced at the local-write gate) AND
   (b) `scope ⊆ owner_grant` (`write_guarded`). Grant-checking ONLY (b) is
   setuid-by-accident. Instances: `spawn` (room), `destroy_child` (bound
   object), the non-inventory arm of `consume`, plus the pre-existing
   `move`/`set_attr`/`create_child`/`transfer`.

3. **Cross-owner-on-a-stranger's-behalf → DEFERRED (phase-3 setuid).** A
   visitor triggering the owner's effect that reaches the owner's property
   (public dispenser, shared workbench, a lever that self-destructs) is
   rights-amplification — correctly BLOCKED today by (a) (the visitor
   holds no `:write` there), and deferred to a per-verb identity + owner
   cert with its own security review. Do NOT let `owner_grant`-only
   smuggle it in early.

> **REVIEW TRIGGER:** any NEW object-effect Facade primitive must be
> classified into one of these three BEFORE it ships. An own-inventory
> primitive drops `owner_grant` but MUST keep the invoker-signed write +
> server-fixed target; an owner-scope primitive MUST route through
> `write_guarded` AND stay invoker-signed (never an ambient/system
> signer — that is the single line where case 2 collapses into setuid).
> Bounds: every object-CREATING path shares the capped creator
> (per-container M=128 + per-invocation N=8, fail-visible); total-world /
> per-principal object budget is broader-tier (CX-n2j2 class), not an
> invited blocker.

### THE FRESH-MINTED-DOC ENFORCE BOUNDARY (plan #6032/#6034) — CX-tdkq.23 is the single convergence keystone

A structural boundary the mint-with-behavior work named, worth recording
because it converges the whole enforce-mode world-building tier onto ONE
dependency:

  * Explicit `{:docs, uuids}` certs gate operations on **existing/known**
    docs — rooms, inventory. These are ENFORCE-CORRECT TODAY (a visitor's
    cert doesn't cover the owner's room → the setuid-refusal holds under
    enforce; own-inventory works because inventory IS in the invoker's
    cert).
  * Operations on a **fresh-minted** doc (configure/define a just-created
    uuid) CANNOT be enforce-authorized by explicit certs — a brand-new
    uuid can't be in a pre-existing `{:docs, uuids}` list. The facade's
    per-run minted-set is a FACADE-level re-gate only (it stops author
    code touching an *arbitrary* uuid); it is NOT gate-level authorization,
    structurally — the local-write gate runs inside the CommitStore
    GenServer, a different process with no channel to the safe-verb child's
    process-dict minted-set (`Commonplace.MUD.World.Facade`'s configure_*
    "CASE B" note).

So ANY create-then-configure/define-a-fresh-doc-under-enforce needs
**subtree-scopes** (CX-tdkq.23 Wrinkle-H: a `{:subtree, section_root}`
cert covers any doc reachable under the section, minted-or-not). That makes
CX-tdkq.23 the SINGLE CONVERGENCE KEYSTONE for the enforce-mode
world-building tier: `define_on` (verbs on minted objects), configure_*
-under-enforce, zone-ownership (players build in their own sections), and
new-room-coverage (the enforce-correct replacement for `auto_extend`, which
must NOT be extended per-uuid before CX-rmuk closes its cert-laundering
hole) ALL depend on it. Object-level auto-extend is the WRONG stopgap
(inherits CX-rmuk); subtree-scopes supersede it.

CURRENT STATUS: `configure_*` ships PERMISSIVE-DOGFOOD-CORRECT (crafting
richness, honestly labeled Case B); the SECURITY-critical setuid-refusal is
enforce-correct independently (explicit-uuid room certs). The expressiveness
tier (mint config + behavior) becomes enforce-correct when CX-tdkq.23 lands.
