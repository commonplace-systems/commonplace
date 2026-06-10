# Data-model rule: no nested CRDT sub-types in snapshot-eligible docs

**Status:** Enforced (CX-tdkq.5 / architecture-review R5). 2026-06-10.
**Supersedes:** the previous "tribal knowledge + doc comments" convention.

## The rule

A document that can be snapshotted (i.e. any document in the store — all
docs are snapshot-eligible) **MUST NOT** store CRDT sub-types (a `YMap` or
`YArray`) nested *inside* a map or array value. Structured values go in as
**JSON-encoded strings** at a top-level type, accepting last-writer-wins on
the blob.

Permitted, and used by every current data model (chat, scheduler, beads
issue fields, bursar state):

- Top-level `YArray` of JSON-encoded string entries (e.g. chat `_messages`).
- Top-level `YMap` with flat composite string keys → primitive values
  (e.g. chat `_reactions`: `"{msg}:{emoji}:{signer}" => true`).
- Top-level `Text`, primitive map/array values.
- XML sub-types (`XMLElement`/`XMLText` children) — these *are* replayed
  structurally by `snapshot_update/1` and are exempt.

Forbidden:

- A `YMap` value inside another `YMap`/`YArray`.
- A `YArray` value inside a `YMap`/`YArray`.

## Why

`Yelixer.Doc.snapshot_update/1` rebuilds a doc's state into a fresh doc by
replaying its top-level named types. Sub-types nested inside maps/arrays are
registered under synthetic `"__sub:CLIENT:CLOCK"` names, and
`replay_named_type/3` **short-circuits on the `__sub:` prefix** — their
internal CRDT state is *not* replayed and is silently dropped on snapshot.

The failure mode this rule prevents is the nasty one: a doc using nested
sub-types works perfectly **until its first snapshot**, at which point the
nested state vanishes. That's a delayed, data-losing trap gated only by
whether anyone remembered the convention.

## Trade-off

The cost of the JSON-blob form is **field-level concurrent merge**: two
peers editing two different fields of the same JSON entry concurrently
resolve as one lost write (LWW on the whole blob), not a clean per-field
merge. Every current data model has accepted this deliberately. If a future
feature genuinely needs per-field concurrent merge of structured data, that
is the signal to schedule the real substrate fix (below), not to reach for
nested sub-types and lose data at the next snapshot.

## Enforcement (the guard)

The convention is no longer enforced by memory:

- `Yelixer.Doc.nested_subtype_names/1` surfaces any `__sub:`-keyed
  (lossy) sub-types in a doc.
- `Commonplace.Store.Snapshotter.build_payload/2` **refuses** to build a
  snapshot for a doc that has them, returning
  `{:error, {:nested_subtypes, names}}`. Refusing is safe: the full commit
  chain is retained, so the nested CRDT state is preserved — the doc simply
  doesn't compact.
- `SnapshotTrigger` maps that refusal to a `{:ok, :skipped,
  {:nested_subtypes, names}}` no-op and emits the
  `[:commonplace, :snapshot, :skipped, :nested_subtypes]` telemetry event;
  `CommitStore.snapshot/2` returns the `{:error, {:nested_subtypes, names}}`
  to an explicit caller.

So a feature that naively nests a `YMap` now produces a **visible** signal
(a telemetry event / a loud no-op and an un-compacting doc) instead of
silent data loss.

## The real fix (deferred, tracked)

The substrate fix is to make `snapshot_update/1` replay nested map/array
sub-types structurally — the same way XML sub-types already are. That is
**CX-α** (filed as a tracked bead, see the architecture-review epic). It is
a non-trivial change to the CRDT core and is explicitly a "next structural
investment," not do-now. Until it lands, this rule + guard is the standing
policy. When it lands, the guard becomes a no-op (no doc will have lossy
nested sub-types) and can be relaxed.
