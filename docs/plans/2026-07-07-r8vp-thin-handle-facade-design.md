# CX-r8vp — Thin-handle facade: data-axis closed-by-default

**Status:** shaped, pending plan two-axis pass (2026-07-07)
**Bead:** CX-r8vp (P2, MEDIUM defense-in-depth — NOT a live exploit)
**Depends on / generalizes:** the P0 key-leak fix (signer material → process dict)

## The gap (reproduced, allowlist probes)

The P0 fix scrubbed the *signing material* from the verb-facing facade, but the
rest of the facade struct + ctx remain verb-reachable. Every `world.<field>` read
plus `Map.get(world, k)`, `%{k: v} = world`, and for-comprehensions over
`world.ctx` are allowlist-`:ok`, so a verb can reach:

- `world.store` — the raw `CommitStoreClient` handle (directly, no ctx needed)
- `world.ctx` — the whole post-scrub ctx map: `player_name, player_uuid,
  player_dir_uuid, inventory_uuid, current_room_uuid, presence_filename,
  root_uuid, store`
- `world.owner_grant` (the grant MapSet), `world.via_verb`, `world.object_uuid`

Not a live exploit today (the store is uncallable — `CommitStoreClient` unlisted +
dynamic dispatch banned; it defaults to a module atom; `inspect` is opaque). But
it's the raw *materials* for a full-store write sitting inert in untrusted scope,
inert only by a **single execution-axis ban** — the data-axis version of the P0
lesson (don't rely on "the call path is blocked" as the only barrier).

## Why field-whitelisting can't fix it

Whitelisting which `world.<field>` reads are allowed does NOT close it: the
`Map.get(world, :ctx)` / `%{ctx: c} = world` / comprehension paths reach the same
data without a field-read. Field-access-control is unwinnable when Map/destructure
reach the same struct. **The only sound close is making the data ABSENT from the
verb-facing value.**

## Design: structural absence (generalize the P0 process-dict move)

The verb-facing `world` becomes a **thin handle** carrying only inert display
data; all capability/identity/store material lives **process-side** (the
per-run `spawn_monitor` child's process dict), exactly like the P0 signer move.
`write_opts/1` already reads the signer from the pdict — this extends the same
pattern to the whole backing.

### Mechanism

1. **One backing pdict entry** (`@facade_backing_key`) holding the full trusted
   context: `%{store, ctx, object_uuid, owner_grant, via_verb, host_kind}`.
   Installed by `SafeVerb.run/3` inside the Bounds child, alongside (and
   subsuming) `install_signer` — the signer keys are just part of `ctx`, so the
   separate `@signer_pdict_key` entry is folded into the backing (one install,
   one read path).

2. **Thin verb-facing struct.** `SafeVerb.run` hands the verb a `%Facade{}` with
   every sensitive field nil/empty: `store: nil, ctx: nil, object_uuid: nil,
   owner_grant: MapSet.new(), via_verb: nil` — leaving only `host_kind` (inert
   `:object|:room`; see open question). It is still a `%Facade{}` so method
   dispatch and the allowlist `facade_receiver?` (literal-`world` first arg) are
   unchanged.

3. **Methods read the backing, with a pdict-OR-`f` fallback.** A private
   `backing(f) = Process.get(@facade_backing_key) || f` — **exactly the shape
   `write_opts/1` already uses** for the signer (`Process.get(@signer_pdict_key)
   || signer_material(f)`). Replace every internal `f.ctx` / `f.store` /
   `f.object_uuid` / `f.owner_grant` / `f.via_verb` with `backing(f).<field>`.
   `host_kind` stays read as `f.host_kind` (it's on the thin struct, inert).
   - **In a verb run:** the pdict backing (the FULL facade) is installed, `f` is
     the thin facade → `backing(f)` returns the full backing; the thin `f`'s nil
     sensitive fields are never read.
   - **In a direct/trusted/test call** (e.g. `Facade.set_attr(full_facade, …)` in
     `world_facade_test`): no pdict entry → `backing(f)` returns `f` (the full
     facade passed directly). This is the load-bearing detail that keeps the
     ~270 existing facade tests and any direct callers working unchanged — the
     methods don't require a verb harness.

   **Signer consolidation:** since the backing is the full facade (its `ctx` still
   carries `signing_context`/`cert_cids`/`signer_id`), `write_opts/1` reads the
   signer from `backing(f).ctx` — so the separate `@signer_pdict_key`,
   `install_signer/1`, `signer_material/1`, and `scrub_signer/1` are REMOVED and
   subsumed by the one backing. `SafeVerb.run/3` changes from
   `install_signer(material) → invoke(scrubbed, …)` to
   `install_backing(full) → invoke(to_verb_facing(full), …)`, where
   `to_verb_facing/1` nils the sensitive fields (keeping `host_kind`).

### Fail-safe direction

Because the thin facade's sensitive fields are **nil**, a missed refactor site
FAILS LOUDLY (nil store → crash) rather than silently leaking or silently
mis-writing — the safe direction. Refactor completeness is the build risk; the
black-box verify (every existing accessor/effect still works) is the backstop.

## What stays reachable (the curated SEE-set)

Only inert display + the sanctioned accessors — the closed data interface:
`actor_name/1`, `actor_ref/1`, `actor_carries?/2`, `get_state/2`, `describe`,
`get_attr`, `random/2`, `pick/2`. Nothing store/root_uuid/grant/capability-shaped.

## Review criterion (plan)

No `field` / `Map.get(world, _)` / `%{_: _} = world` / comprehension path on the
verb-facing facade yields `store`, `root_uuid`, or anything capability-shaped.

## P0-style pins (asserted, not incidental)

Explicit tests that all yield nothing sensitive — the meta-fix for the P0's
incidental-but-unaudited shape:
- `world.store == nil`, `world.ctx == nil`, `world.owner_grant == MapSet.new()`,
  `world.via_verb == nil`, `world.object_uuid == nil`
- `Map.get(world, :ctx) == nil`, `Map.get(world, :store) == nil`
- `%{ctx: c} = world; c == nil`
- and that every curated accessor STILL returns the right value (backing intact)

## The standing pattern (the durable win)

This turns the P0 fix into a rule: the verb-facing handle carries ONLY inert
display data; ALL capability/identity/store material lives process-side; the
curated accessors ARE the interface. Every future facade field then gets one
clean question: **thin-handle (inert display) or process-side (capability/
identity)?** Extends the two-axis discipline from "audit what's reachable" to
"STRUCTURE so only inert display is reachable" — the same self-contained-verifier
/ closed-by-default lesson (CX-bepn) applied to the DATA axis.

## Open questions for plan

1. **host_kind on the thin facade** — it's inert (`:object|:room`, gameplay
   info, not capability/identity/store). Expose it on the thin struct (simplest,
   methods read `f.host_kind`), or route it through an accessor too for
   closed-by-default purity? (Leaning: keep on the thin struct — it's genuinely
   inert and methods use it for guards.)
2. **object_uuid** — the host uuid. Hidden in the backing under this design
   (`world.object_uuid → nil`). Confirm no legitimate verb pattern reads it
   directly (authors use facade methods, not raw uuids); the black-box verify
   catches any breakage.
3. **Build sequencing** — its own reviewed change, its own redeploy + black-box
   verify (agent confirms `world.ctx`/`world.store` no longer verb-reachable AND
   nothing broke). NOT bundled with gameplay findings (touches every facade
   method's ctx access = additive-then-cleanup, earns its own verify pass).
