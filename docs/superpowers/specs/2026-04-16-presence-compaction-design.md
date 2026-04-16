# Presence Compaction Design (CX-3ty)

Date: 2026-04-16
Status: Design — implementation deferred
Owner: jes
IRC discussion: #loom 2026-04-16 (commonplace-plan, tarot, claude-chat, workspace, hermes)

## Problem statement

Presence documents are small YMaps (name/type/status/started_at/heartbeat)
that are updated every heartbeat interval. In production, a single
presence document has accumulated pathologically:

- `claude-code-2ca.bot` holds **14,360 distinct client_ids** in its
  Yelixer state vector
- Latest commit payload is **~398 KB** (most of which is serialized
  state-vector entries from prior rounds)
- `Yelixer.Encoding.apply_update/2` is `O(clients)` in both work and
  allocation
- Loading any page that reconstructs this document (`Presence.read/2`,
  `Reaper.find_stale/3`, wiki UI with a presence badge) takes **~30 s**
- The reaper (CX-e6s) reduces *count* of entries but does not stop
  *per-entry bloat* on long-lived bots that never die

### Why the state vector grows

Grepping `apps/commonplace/lib/commonplace/presence.ex` shows the
heartbeat path:

```
Yelixer.Doc.new()                                  # fresh random client_id
|> Yelixer.Encoding.apply_update(latest.update)    # replays all history
|> ContentType.set_key("heartbeat", now)           # writes under the *new* client_id
|> Yelixer.Encoding.encode_update()                # re-emits full state
|> CommitStoreClient.create_chained_commit(...)
```

`Yelixer.Doc.new/1` (apps/yelixer/lib/yelixer/doc.ex:14) defaults
`client_id` to `:rand.uniform(1_000_000_000)`. Because the caller never
passes `client_id:`, **every heartbeat call within the same BEAM
process mints a new client_id**. The random ID is then persisted into
the state vector on the next `encode_update`, so the N+1th heartbeat
inherits all N prior client_ids plus its own.

This is a **writer-side bug**, not a property of the CRDT. The
state-vector bloat is driven by unstable client_id minting, not by
legitimate multi-writer interleaving.

## Approaches considered

### (A) Chain-rewrite: replace the head commit with `parent_id = nil`

Compute a fresh snapshot, write it as a new commit whose `parent_id`
is `nil`, point `:latest` at it. Old commits remain on disk but are
unreachable from `:latest`.

Pros: readers are unchanged (`reconstruct_snapshot/2` already reads
only the latest commit for schema-like docs; presence could adopt the
same pattern). Simplest on the reader side.

Cons: **fatal for replication.** A peer holding the old head as its
`:latest` would either
- reject the new commit during catch-up sync (its `commit_ids_for_doc`
  MapSet doesn't contain the new root), or
- keep a divergent chain that never reconverges.
The `import_commit` path in `CommitStore` (line 256) only sets
`:latest` when the peer has *no* latest — it will not willingly cut
its own chain. Getting this right requires a coordinated reset
protocol that does not exist and is outside the scope of a
compaction pass.

### (B) Snapshot-append: append a self-contained commit, reader prefers it

Compute the snapshot payload — a full Yjs update built from a
fresh `Yelixer.Doc.new()` whose state vector contains a single
client_id — and write it as a **chained** commit (normal parent
pointer, normal DAG position). Tag it with a metadata flag
(`:snapshot` or `commit_kind: :snapshot`). Teach the reader, when
loading a presence doc, to walk backwards from `:latest` until it
finds a snapshot commit and apply only that.

Pros:
- Replication-safe. The snapshot is just another commit; peers sync
  it via the existing catch-up machinery.
- Reversible. If compaction turns out to be wrong, the pre-compaction
  chain is still reachable and we can set `:latest` back.
- No protocol change, no new storage path.
- Generalizes trivially to any CRDT doc with state-vector bloat, not
  just presence.

Cons:
- Readers must be taught to short-circuit; any loader that still
  calls `reconstruct_doc` (full replay) pays the old `O(clients)`
  cost. Presence today uses snapshot-style loads (`Doc.new() +
  apply_update(latest.update)`), so the only reader that needs
  updating is whatever walks the chain.
- Disk usage does not decrease (append-only store, per CLAUDE.md).
  This is fine for presence — the old commits were already on disk.

### (C) Presence-as-ephemeral-epoch subdoc

Acknowledge that presence is LWW-with-TTL, not full-CRDT-causality.
Store presence outside the commit DAG (direct CubDB keys, or a
separate "ephemeral" lane), with an epoch counter. On compaction,
bump the epoch; clients drop all state below the new epoch and
re-announce.

Pros: sidesteps CRDT costs entirely for a use case that doesn't need
them. Aligns with tarot's observation that presence is semantically
ephemeral.

Cons: **scope change.** Presence currently lives in the normal
document tree, shows up in `Schema.list_entries`, participates in
`Merge.merge/3`, and is sync'd by the sync agent as honorific-
extension files. Pulling it out of the CRDT substrate affects merge
semantics, filesystem sync, the `who` CLI, and the MCP surface. A
separate design doc is the right scope for this — not a sub-bullet of
a compaction pass.

### (D) Yelixer-level client_id squash (rejected)

Rewrite every block in the doc to use a single synthetic client_id
with synthetic clocks. Rejected by commonplace-plan in IRC: "Yjs
client_ids are random for causality safety, faking them risks future
collisions interleaving updates incorrectly." Breaks the invariant
that a client_id uniquely identifies a producer.

## Recommendation

**Ship (B), but fix the root cause first.**

Order of operations (from commonplace-plan's synthesis in IRC):

1. **Diagnose & root-fix first.** Instrument a one-shot script to
   classify the 14,360 client_ids as live-producers vs
   disconnected-tombstones. The expected finding is that nearly all
   are tombstones from per-heartbeat `Yelixer.Doc.new()` calls with no
   stable client_id. Fix by making `Presence.heartbeat/2` and
   `Presence.update_status/3` reuse a stable per-actor client_id
   (keyed by presence UUID, or by the actor identity) instead of
   minting fresh each call. With this single fix, the bloat stops
   growing on all presence docs — old bloat still needs compaction,
   but new bloat is eliminated.

2. **Ship (B) as a generic compaction primitive**, scoped to
   presence for the first rollout but written without presence-
   specific logic in the CommitStore/reader layers. It becomes
   reusable for any doc hitting state-vector bloat — schema forks
   with many historical forkers, shared documents with many past
   editors, etc.

3. **Own-doc producer only.** For presence, the owning actor
   compacts its own presence (`sync.exe` compacts `sync.exe`
   presence). No race, no leader election needed. For future
   general-doc compaction, snapshots can be made deterministic
   (content-addressed) so concurrent compactors produce identical
   bytes and dedupe on commit CID — defer this to the shared-doc
   follow-up.

4. **Defer (C)** to its own design doc: "presence-as-ephemeral-
   epoch-subdoc." If compaction + stable client_ids doesn't hold
   presence load at reasonable sizes long-term, revisit.

Rationale: (A) is unworkable under replication. (B) is replication-
safe, reversible, and the reader change is minimal because presence
already loads snapshot-style. (D) breaks CRDT semantics. (C) is
architecturally cleaner but out-of-scope for a compaction pass. And
none of (A)/(B)/(C)/(D) matter as much as fixing the writer that
mints a new client_id every tick — without that fix, compaction is a
bailing-a-boat exercise.

## Sync / replication implications

(B) is **safe under replication** by design:

- Snapshot commits are ordinary commits with `parent_id` pointing at
  the pre-snapshot head. Catch-up sync (`commit_ids_for_doc` diff,
  `import_commit`) replicates them like any other commit.
- The pre-snapshot chain remains reachable from the snapshot via
  `parent_id`. Peers that arrive late see the full history and can
  still walk it.
- Readers on older code that don't know about `commit_kind:
  :snapshot` fall through to `reconstruct_snapshot` (latest-only) or
  `reconstruct_doc` (full replay) as they do today — both still
  produce correct documents. The snapshot commit's payload applied on
  top of prior state is idempotent in Yjs: applying an update that
  encodes state the receiver already has is a no-op.
- BEAM-cluster sync over Phoenix PubSub `{:commit, ...}` broadcasts
  carries the new commit ID; receivers fetch it via `get_commit` on
  their usual path.

Contrast (A) (chain-rewrite): any peer holding a commit_id below the
new root has no parent_id to walk toward the new `:latest` and will
permanently diverge. This is why (A) is rejected.

One open sync question (deferred): should `all_doc_uuids` or a new
`snapshot_head` key let peers discover snapshots more cheaply than
walking? Not needed for presence — presence chains are short per-doc
once the writer is fixed. Defer to a general-doc rollout.

## Open questions

- **Trigger policy.** Size-based (state vector > N clients), time-based
  (every M hours), or commit-count-based (every K commits since last
  snapshot)? Proposal: start with size-based (> 256 client_ids) for
  presence, evaluate under real workload. commonplace-plan's note:
  with stable client_ids, the size threshold may essentially never
  fire — which is the desired end state.
- **Who triggers?** Options: the actor itself on heartbeat (simplest,
  no new process), the reaper (already scanning presence docs), or a
  dedicated compactor GenServer. Lean toward the reaper — it already
  walks presence entries on a schedule and has the right frequency.
- **Metadata flag vs side-table.** Tag via `metadata: %{kind:
  :snapshot}` on the commit, or add a separate CubDB key
  `{:snapshot_head, uuid}`? Side-table is faster to look up but adds
  a schema migration; metadata is free. Proposal: metadata for now,
  revisit if the reader's scan-back-for-snapshot traversal shows up
  in profiles.
- **Signing.** Snapshot commits should be signed with the actor's
  identity (so the audit log can attribute them), not with a synthetic
  "__snapshot" signer. CX-hoj (per-call signing context) is the
  relevant prior art.
- **Determinism for concurrent compactors (deferred).** Not a presence
  problem (single-writer). For general docs: normalize snapshot
  payloads (sorted clients, no timestamps in snapshot-only metadata)
  so content-addressing deduplicates concurrent compactors. IRC
  consensus was yes, but defer until the general-doc follow-up.
- **Encode determinism in Yelixer.** workspace raised this: the yrs
  dataset tests cover decode equivalence, not encode byte-for-byte
  determinism. If we ever rely on CID-dedup of concurrent snapshots,
  we need a targeted test that two identical-logical-state Docs
  produce bytewise-equal `encode_update` output. File as a separate
  bead if/when content-addressed dedup matters.

## Implementation sketch (file-level only — no code)

### New primitive

- `Commonplace.Store.CommitStore.create_snapshot_commit/4`: writes a
  normal chained commit with metadata tagging it as a snapshot. Lives
  next to `create_chained_commit/4` in
  `apps/commonplace/lib/commonplace/store/commit_store.ex`.
- `CommitStoreClient.create_snapshot_commit/4`: pass-through, mirrors
  the local/remote pattern already used for every other write.

### Yelixer helper

- `Yelixer.Doc.compact/1` or `Yelixer.Doc.snapshot_update/1`: returns
  a self-contained update whose state vector holds a single client_id
  (the doc's own), encoding the current materialized state with
  tombstones GC'd. Internally: `Doc.new() -> ContentType.set_*` for
  each observable key based on the source doc's current content, then
  `encode_update`. Lives in `apps/yelixer/lib/yelixer/doc.ex`.
- Alternatively: a `Doc.with_client_id/2` + `Doc.gc/1` + re-encode
  pipeline assembled at the `Commonplace.Presence.Compactor` layer.
  Prefer the self-contained helper so Yelixer owns the CRDT-semantics
  guarantees.

### Presence-side compactor

- `Commonplace.Presence.Compactor` module (new file under
  `apps/commonplace/lib/commonplace/presence/compactor.ex`): given a
  presence UUID, load the current doc, rebuild from observable state
  with a fresh stable client_id, write via
  `create_snapshot_commit/4`. Idempotent.
- Called opportunistically from the reaper scan loop (one extra pass
  per cycle) when a presence doc's state-vector size exceeds the
  threshold. Threshold configurable, default 256.

### Reader changes

- `Commonplace.Presence.read/2` and `load_doc/2`: no change needed
  — they already use the snapshot-style `Doc.new() +
  apply_update(latest.update)` pattern, which produces the correct
  state regardless of whether `:latest` is a snapshot commit or a
  normal chained commit. Verify with a test that confirms a compacted
  presence doc's `read/2` returns the same content as the
  pre-compaction version.
- `Commonplace.Tree.DocBuilder.reconstruct_doc/2` (full replay):
  either (a) teach it to stop the backward walk at the first
  `metadata.kind == :snapshot` commit, or (b) leave it alone and note
  that presence docs shouldn't be loaded via `reconstruct_doc/2`.
  Prefer (a) — it's a small change and makes the snapshot primitive
  work for any future caller.

### Writer root-fix (prerequisite, not compaction itself)

- `Commonplace.Presence.heartbeat/2` and `update_status/3`: pass a
  stable `client_id:` to `Yelixer.Doc.new/1`. Derive from the
  presence UUID (e.g., `:erlang.phash2(uuid, 0xFFFF_FFFF)`) so
  different actors writing the same presence doc still get the same
  ID, and the same actor writing across restarts does too.
  - This is the actual bloat-stopper. File separately from
    compaction — see follow-up beads.

### Tests

- Unit: compactor produces doc with `state_vector |> map_size == 1`
  and `ContentType.get_content` equal to pre-compaction.
- Integration: simulate 10,000 heartbeats, verify apply_update time
  pre- and post-compaction; assert >100x speedup (matches acceptance
  criterion).
- Replication: two-node test where node B is offline during
  compaction on node A, comes online, sync converges without error.
- Idempotency: compact twice, no redundant commits beyond the second
  snapshot's own.

### Out of scope for this bead

- Content-addressed dedup of concurrent snapshots (defer with general-
  doc rollout).
- Ephemeral-epoch presence sub-doc (separate design doc).
- Yelixer encode determinism tests (separate bead if/when CID-dedup
  matters).
- Actually doing the trigger selection / rollout — that's
  implementation work, filed as a follow-up bead.

## IRC discussion summary

Full transcript in #loom 2026-04-16 17:38–17:41. Participants:
commonplace-plan, tarot, claude-chat, workspace, hermes. Consensus:

- (B) snapshot-append + reader short-circuit, not (A) chain-rewrite.
  (A) breaks replication.
- (D) synthetic-clock squash is unsafe for CRDT causality.
- (C) epoch-subdoc is valid but out of scope; separate design doc.
- Tarot's meta-point (amplified by commonplace-plan): 14k client_ids
  on a presence doc is a **writer bug**, not just a compaction
  problem. Root-fix stable client_id minting before or alongside
  compaction.
- For general-doc compaction later: content-address snapshots for
  deterministic dedup (tarot, hermes); normalize commit envelope
  (commonplace-plan); verify Yelixer encode determinism (workspace).

No dissent on (B).
