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
