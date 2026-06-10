# Commonplace Architecture Review

**Date:** 2026-06-10
**Reviewer:** Claude (Fable 5), at jes's request via boss-clod
**Scope:** The whole Elixir system — store, tree/merge, sync, compute/views/dataflow,
processes/bots/MCP, presence, crypto/gold, yelixer, web/CLI edges — read through the
literate moduledocs (merged at 2848adf), the design docs in `commonplace-plan/docs/`,
and the code. This is a holistic review, not a module inventory. File:line citations
are to the state of the tree at the time of review.

---

## 1. Executive summary

Commonplace is an unusually coherent system. The through-line — *everything is a CRDT
document in one content-addressed substrate, and every capability is built by putting
more things into that substrate rather than beside it* — is applied with rare
discipline. Issues, schedules, process definitions, executable code, chat logs,
identities, MCP tool catalogs, even the reflog all live as documents that sync, fork,
merge, and audit identically. That choice compounds: each new feature inherits
branching, history, replication, and malleability for free, and the design docs show
the team consciously paying short-term costs (e.g. JSON-blob encodings) to preserve it.

The deepest technical strength is **determinism as a substitute for coordination**:
byte-deterministic CRDT encoding, deterministic-anyone snapshots, content-addressed
commits, and synthetic genesis roots let independent nodes converge on identical bytes
without leader election or consensus. The deepest structural risk is the mirror image
of the system's honesty: a consistent pattern of **mechanism built, enforcement
deferred**. Signatures exist but are never verified on import; attestation chains are
written but never checked; code from documents executes with full BEAM privileges; the
exclusive-lock bursar trusts caller-supplied identity. Each deferral is documented and
defensible under the current single-tenant threat model — but the project vision
(federation, multi-agent collaboration) is exactly the future in which all of them
become load-bearing at once.

The other systemic concerns, in order: the singleton CommitStore GenServer as a
write-throughput ceiling (already showing contention); the yelixer nested-type
snapshot limitation that has quietly reshaped every data model in the system; unbounded
append-only growth with detection-only GC; and an orchestration/reactive layer whose
working pieces (ViewCompute, Reaper) are not yet under supervision, so operational
correctness depends on manual starts.

Overall verdict: **a sound, intellectually serious architecture in the
"mechanisms-complete, hardening-deferred" stage**. The recommendations in §8 are mostly
about sequencing: which deferrals must land before the system's own vision makes them
dangerous.

---

## 2. The through-line: documents all the way down

### 2.1 What the idea actually is

Four layers, each expressed in terms of the one below:

1. **Yelixer** — a pure-functional, wire-compatible Y.js CRDT engine. Documents are
   immutable Elixir structs; every operation returns a new doc.
2. **The commit DAG** — every document's history is a content-addressed Merkle chain
   of Yjs updates in CubDB (`Commonplace.Store.CommitStore`), with snapshots for
   compaction, namespaces for trust, and derivation maps for translating edits across
   compaction epochs.
3. **The tree** — schema documents (YMaps of `name → "type:uuid"`) make documents into
   a filesystem; fork is a DAG branch, merge is three-way over that tree.
4. **The substrate-native applications** — sync agents, processes, views, chat, beads,
   the scheduler, MCP tools: all of them are *documents plus a small process that
   watches documents*, coordinated over Phoenix PubSub "color channels."

The color taxonomy (blue = state, cyan = directed writes, red = durable event logs,
magenta = ephemeral signals, green = exclusive tokens, gold = authority/attestation,
white = credentials) gives every message a declared persistence/authority contract.
Blue/cyan/magenta are fully real; red is real as transport with a working
magenta→red onramp (`Dataflow.RedLog`); green is built but not integrated
(`Green.Bursar`); gold is half-built (attestations written, never verified); white and
black are design-only. The implemented core is the spreadsheet: blue edges are cell
references, ViewCompute processes are formula cells.

### 2.2 Coherence assessment

The coherence is real, and it is *enforced*, not just aspirational:

- **One mutation surface.** Every mutating verb routes through
  `Commonplace.CommandRouter` (command_router.ex), which emits a
  initiated/completed/failed magenta triple per dispatch. Authored edits, computed
  edits (ViewCompute), and MCP edits all converge on the same `Diff.apply_diff/3`
  call site, so they share identical CRDT-correctness guarantees.
- **Self-application.** The issue tracker (beads-on-commonplace), the scheduler's own
  state doc, the MCP tool catalog, and the orchestrator's process declarations are all
  ordinary documents. The system is built out of itself to a degree that most
  "everything is an X" systems only claim.
- **Documented cost-paying.** When the substrate couldn't carry a natural shape
  (nested CRDTs under snapshots, §5.3), the chat, scheduler, and beads designs all
  converged on the same workaround and *wrote down why* — the convention is consistent
  across subsystems rather than ad hoc per feature.

Where coherence frays, it frays in one recognizable way: **the working implementation
and the designed mechanism coexist**. ViewCompute is explicitly a stand-in for the
SmartDoc/Orchestrator reactive wiring (view_compute.ex:13–27: SmartDoc's `push_cyan/3`
has zero callers; the Orchestrator is not in the supervision tree). The storage layer
broadcasts on both `commits:<uuid>` and `blue:<uuid>` (a tracked wart, CX-4im).
Yelixer's `Transaction` module is "partial and possibly vestigial" by its own
moduledoc. None of these are incoherent — they are scaffolding seams — but they are
the places a newcomer will most likely build on the wrong abstraction.

---

## 3. How the subsystems fit together

A single edit, end to end:

```
disk write ──▶ EntryAgent (outbound: content-hash gate, stable client_id)
                  │ encode Yjs diff
                  ▼
            CommandRouter ──▶ CommitStore.create_chained_commit  (atomic :latest bump)
                  │                       │
        magenta event triple       PubSub broadcast  blue:<uuid> (+ commits:<uuid>)
                  │                       │
                  ▼                       ├──▶ ViewCompute → recompute → CommandRouter.write (cyan)
            RedLog onramp                 ├──▶ LiveView re-render (per-selection subscribe)
            (debounced red JSONL)         ├──▶ other nodes (catch-up: CID set diff + import_commit)
                  │                       └──▶ EntryAgent (inbound: commit-id gate → disk)
            maybe_attest (gold, best-effort)
```

Key cross-couplings worth naming:

- **Snapshots couple storage to the CRDT engine.** Snapshot compaction depends on
  `Yelixer.Doc.snapshot_update/1` being byte-deterministic and on derivation maps for
  late-edit translation; the namespace validator depends on the encoder's client-ID
  ordering guarantees (CX-w62). Owning the CRDT engine is what makes the storage
  layer's determinism strategy possible at all — none of this could be done against a
  black-box yjs/yrs.
- **Sync couples to merge.** Node catch-up imports route through
  `LateEditAutoTranslator` (cross-epoch translation) and `MergeAdopter` (B-side
  `:latest` advancement); local/remote concurrent edits become sibling commits folded
  by `SiblingMerger`.
- **The compute layer couples to the process layer.** ViewCompute's M7 path compiles
  its function from a code document via `Code.SourceDoc` — the same compile-from-doc
  primitive the Orchestrator uses for `:elixir` processes. Code, like everything else,
  is a document; editing the code doc restarts the computing process.
- **Everything trusts the storage layer's invariants.** Atomic `:latest` advancement,
  clobber-safe import, content-address verification — the rest of the system is
  written assuming these hold, and (per the deep-dive) they do.

---

## 4. Architectural strengths

### 4.1 Determinism as a distributed-systems strategy

The single most sophisticated idea in the system. Instead of coordinating, independent
nodes are arranged to *produce identical bytes*:

- `encode_update/1` is byte-deterministic across replicas with the same logical state
  (four documented invariants: client sort order, clock order, delete-set sort,
  delete-set merge-not-replace — encoding.ex:68–89).
- Snapshots are "deterministic-anyone" (CX-umz): the snapshotter overrides its random
  client_id with a deterministic function of the source state (snapshotter.ex:138), so
  two nodes snapshotting the same parent produce the same content-addressed commit ID,
  and the CAS write (`{:error, :parent_moved}` on a moved head) collapses the race into
  one commit with zero leader election.
- Genesis commits are a pure function of the doc UUID (commit.ex:104–127) — recreating
  a doc on independent nodes lands on the same root.

This pattern eliminates whole classes of coordination machinery and is the reason the
system can be multi-node without consensus.

### 4.2 Yelixer as an owned, oracle-tested foundation

A pure-Elixir Y.js port, wire-compatible with Yjs V1, validated against 5,320
yrs-generated dataset vectors plus property tests (two/three-peer convergence,
apply-order independence) and an optional differential harness that drives real Yjs in
a Node subprocess. Pure-functional CRDT operations mean no locks and trivially
testable convergence. The strategic payoff is §3's coupling: snapshot derivation maps,
namespace validation, and byte-determinism are all features that required owning the
engine.

### 4.3 Storage-layer concurrency discipline

The `:latest` pointer saga (CX-l7j) was resolved correctly: read-parent + write-child
is bundled in a single `handle_call` so the GenServer mailbox serializes writers;
CAS variants reject rather than silently re-anchor; `import_commit` never clobbers a
local head (remote commits become siblings, merged later); namespace validation
splits *reference* clientIDs (must be witnessed — anti-forgery) from *authorship*
clientIDs (extend the namespace). These invariants are stated in moduledocs and
verifiable in the code. The crash-recovery story is clean because the durable record
is always the CubDB row, with PubSub as best-effort notification on top.

### 4.4 The late-edit / derivation-map machinery

Snapshot compaction usually breaks old in-flight edits; Commonplace's answer is the
most novel mechanism in the system. Derivation maps (`new_item_id → old_item_id`,
composable across epochs without snapshot bytes), an all-or-nothing preflight that
rejects untranslatable edits before any state changes, positional rebase as the
fallback, and an asymmetric two-pass cross-epoch merge (R→C→L). The design doc records
rejected alternatives and the composability constraint that drove the format. This is
the part of the system most likely to be publishable as a standalone idea.

### 4.5 Fork-as-DAG-branch and incremental merge

Fork provenance lives entirely in cross-chain `parent_id` edges — no manifest sidecar
to drift out of sync. Merge recovers ancestry by walking the DAG, uses stored merge
points so the n-th merge costs only the divergence since the (n−1)-th, distinguishes
node-ID replacement from true name collision, and auto-renames real conflicts rather
than blocking. Time-travel fork (CX-65n) anchors each descendant independently at-or-
before a reference time, giving snapshot-consistent forks across unsynchronized
per-doc timelines.

### 4.6 Sync's dual-gate echo suppression and stale-write capture

Outbound disk→CRDT is gated by content hash; inbound CRDT→disk by
last-written-commit-id. Either alone oscillates; together they close the loop
(agent.ex:14–28). The inode shadow-hardlink mechanism catches the genuinely hard case
— a process writing through a stale file descriptor after an atomic rename — and
merges that write as a CRDT delta parented on the commit it actually saw, instead of
losing it. This is filesystem-sync craftsmanship well above the usual bar.

### 4.7 Institutional honesty

Nearly every weakness found by this review is *already admitted somewhere* — in a
moduledoc ("partial and possibly vestigial"), a known-gaps doc, a design doc's
"implemented vs. imagined" section, or a tracked bead (CX-4im, CX-α, CX-0nkq…). The
literate-documentation pass means the codebase audits itself. This drastically lowers
the cost of the hardening work recommended below, because the map of what's deferred
already exists.

---

## 5. Risks, weaknesses, and tech debt

Ordered by severity.

### 5.1 Security is designed, not enforced (the big one)

Every enforcement point in the trust story is currently open:

- **Unsandboxed code execution from documents.** `Code.SourceDoc.compile/2` feeds
  document content to `Code.compile_string/2`; Orchestrator `:elixir` processes,
  ViewCompute M7 functions, and (planned) MUD verbs all run with full BEAM privileges
  — `File.rm_rf!`, `System.cmd`, sockets, the lot. No capability model, no quotas, no
  module-name validation. The MUD design doc itself calls sandboxing "the single
  biggest piece of new substrate."
- **Signatures exist but are never checked.** Ed25519 signing is complete and tested
  (crypto/signing.ex), per-call `SigningContext` works — but `Signing.verify_commit/1`
  has **zero callers**; `import_commit` verifies the content address, not the
  signature. Any peer can inject unsigned or wrongly-signed commits. Meanwhile UI
  edges still stamp placeholder signers (`"wiki-user@local"`, wiki_live.ex:280).
- **Gold attestations are written, never read.** `Gold.Chain.verify_chain/3` has no
  callers; `maybe_attest` swallows errors. The audit chain provides no actual
  assurance today, and without a timekeeper, backdating isn't prevented.
- **Caller-supplied identity everywhere.** Chat actions accept any `signer_id`;
  Bursar accepts any `holder` string; MQTT/PubSub topics are open (white channel
  unimplemented); secrets are plaintext CubDB.
- **The trust root itself can diverge.** Identity docs (which hold the public keys
  verification would consult) do not flow through SiblingMerger
  (presence/identity.ex:244–251) — concurrent key additions from two nodes produce
  unreconciled sibling commits, so a verifier may not see a legitimately added key.

Each is individually fine under the stated threat model ("trust source authors,"
single-tenant personal substrate). The architectural risk is the *conjunction*: the
project's own vision — federation with friends, multi-agent collaboration, an MCP
surface other agents drive — is precisely the future where all of these become attack
surface simultaneously. Today there is no enforced boundary between "my substrate" and
"code/commits that arrived from elsewhere." See R1/R2 in §8.

### 5.2 The CommitStore singleton is the system's throughput ceiling

One GenServer over one exclusively-locked CubDB serializes every write in the system
— sync agents, the orchestrator's reconcile commits, reflog checkpoints (~2k commits
for a full 1000-dir tree walk), snapshot construction, chat posts, and (in remote
mode) every CLI invocation routed over distribution. Contention is not hypothetical:
fork on a deep tree has timed out at 5s under snapshot-task pileup
(snapshot_trigger.ex:46–57), and the mitigations so far are cadence patches (10s
reflog rate limit, 10s snapshot debounce — both acknowledged as best-effort stand-ins
for a proper single-flight worker). Reads also funnel through the same mailbox even
though CubDB supports concurrent readers. As checkouts, agents, and bots multiply —
which the sparse-sync design explicitly intends — this is the wall they hit first.

### 5.3 The nested-CRDT snapshot limitation is silently shaping every data model

`Yelixer.Doc.snapshot_update/1` does not structurally replay sub-types nested inside
maps/arrays; after compaction a nested YMap loses its internal CRDT state
(snapshot-compaction.md:212–285). The workaround — JSON-encode the nested structure as
a string, accept LWW on the blob — is now the *de facto data-model rule*: chat
messages, scheduler entries, beads issue fields, and bursar state all use it. That's
three consequences: (a) field-level concurrent merge is forfeited everywhere the
pattern is used (concurrent edits to two fields of one chat message = one lost write,
LWW); (b) the convention is enforced only by tribal knowledge and doc comments — a new
feature that naïvely nests a YMap will work fine *until its first snapshot*, which is
a delayed, data-losing failure mode; (c) the real fix (CX-α, structural replay in
yelixer) keeps getting deferred while more of the system calcifies around the
workaround. This deserves a decision, not just a backlog entry: either fix the
substrate or bless the convention with a guard (§8 R5).

### 5.4 Unbounded growth, detection-only GC

The store is append-only with no retention policy; cold-storage GC of superseded
snapshots is explicitly deferred; `Store.GC` *finds* orphans but deletes nothing.
Back-of-envelope from the deep-dive: a doc edited once per second for a year is
~9.5 GB of commits. Add: gold attestation chains grow per-event with no pruning; the
SourceDoc ETS compile cache has no eviction (every edit of a code doc permanently
retains a compiled module); yelixer state vectors grow with every distinct client ever
seen (mitigated by stable client_ids in sync/presence — a good catch — but not
elsewhere); tombstones persist in the BlockStore until an opt-in snapshot. None of
this fails fast; all of it degrades a long-lived personal substrate, which is the
exact intended use.

### 5.5 The reactive/orchestration layer isn't operationally anchored

- `Process.Orchestrator` is **not in the application supervision tree** — and the
  presence Reaper runs under it, so stale presence reaping is not guaranteed at all
  unless someone started the orchestrator by hand.
- ViewCompute instances are started lazily/manually (chat rooms re-trigger on mount;
  the wiki's notes view is hand-started) and disappear on BEAM restart — computed
  views silently stop updating.
- Recompute is synchronous in the PubSub handler with no debounce, batching, timeout,
  or shed-load; a slow compute blocks its subscription; a hot source fans out
  recomputes linearly with view count.
- No cycle detection in the view graph: a view wired (or self-modified — this is
  malleable software) into a loop will oscillate; convergence is hoped for, not
  ensured. `Materialize` is cycle-safe internally; the *graph* is not.
- Orchestrator reconcile failures log-and-retry every 5s forever (a corrupted
  `__processes.json` is an eternal silent loop), and process start failures are
  dropped without telemetry on some paths (orchestrator.ex:302–341).

### 5.6 Singletons and split-brain

`MUD.TickBot` and `MUD.Bot` use `:global` names (partition → duplicate owners → the
known name-conflict kill hazard recorded in project memory); the scheduler's
"run at most one per workspace" is documented but unenforced (duplicate fires under
multi-peer); CommandRouter is a local named singleton. Meanwhile `:latest` is
per-node by design, with cross-node convergence relying on MergeAdopter — correct for
commits, but after a partition where both sides authored, neither head dominates and
reconciliation is manual. The system has the right primitive for most of this —
green tokens — sitting unintegrated (§8 R7).

### 5.7 Edge-layer debt (lower severity, listed for completeness)

Remote-mode `snapshot/2` not wired through CommitStoreClient; chained remote writes
take two round-trips; the legacy single-arg `checkout` re-root remains alongside
`reroot`; path-resolution logic is duplicated across LiveViews and CLI commands;
`wiki_live`/`chat_room_live` lack explicit terminate-unsubscribe (framework cleanup
saves them, but tree_live sets the pattern they don't follow); transclusion expansion
is uncached O(includes) store reads per render; yelixer's `Transaction` module is
skeletal and publicly misleading ("complete it or delete it," per its own moduledoc).

---

## 6. Correctness and concurrency assessment

What's solid: the storage layer's serialization points (§4.3) are correct and the
hard races there have been found and fixed with evidence; CRDT convergence is
oracle- and property-tested; sync's dual gates plus reconstruct-before-apply for
computed writes give idempotent, convergent edits; the reflog's clear-dirty-before-
walk ordering re-marks rather than drops concurrent edits; preflight validation is
pure (failed late-edit imports leave no partial state).

Open concerns, beyond those already covered in §5:

1. **Out-of-order import validation.** Namespace validation walks the *local* commit
   table; if commit B (referencing clientIDs introduced by A) arrives before A, B
   fails validation. No documented retry/queue on the import path — peers are assumed
   to send in order. Under PubSub + catch-up interleaving this assumption will
   eventually be violated; the failure is a rejected-but-legitimate commit.
2. **Merge vs. concurrent local writer.** Tree merge reads `latest` then writes
   without CAS; a concurrent local edit becomes a sibling needing SiblingMerger. The
   net result converges, but the merge path quietly depends on a second mechanism
   firing — worth an explicit test.
3. **Presence move is not atomic** (leave/delete/create/enter as separate calls;
   transient double-presence is possible), and a reaped-then-resumed actor mints a new
   presence UUID, leaving the cold identity pointing at a dead hot doc.
4. **Scheduler/bot delivery semantics are mixed at-least-once** (boot catch-up fires
   all past-due entries at once — thundering herd; magenta fire can be lost after the
   entry is marked fired — so it's also at-most-once delivery on a per-subscriber
   basis). Fine for current uses; document the contract before bots depend on it.
5. **TickBot/MUD `:global` registration races** on partition heal (Bot doesn't catch
   `:already_started`; duplicate sessions possible).

Nothing here looks like silent data corruption in the CRDT/storage core — the
concerning cases are availability (rejected imports, stopped computes) and
duplicated/lost *signals*, not lost document state. That's the right place for the
risk to live.

---

## 7. Scalability limits

Roughly in the order they'd be hit:

1. **CommitStore mailbox** (§5.2) — the first wall; already observed.
2. **Recompute storms** — synchronous fan-out, no coalescing; cost = commits/sec ×
   downstream views × compute cost. Materialize is O(n²) worst-case on long edit
   chains and recomputes from scratch each time.
3. **Sync at scale** — one GenServer per file/dir in the sparse model (fine to low
   thousands, then mailbox/scheduling pressure); per-tick full rescans as the watcher
   fallback; full-file reads + MD5 per check (no streaming, no chunking — multi-GB
   files spike memory).
4. **Fork cost** — strictly O(tree) sequential reconstruct + commit per doc, with a
   second `__processes.json` reconstruction pass; no parallelism, batching, or
   progress reporting. A 100k-doc workspace fork is a long, opaque stall that also
   floods the CommitStore (interacts with #1).
5. **Yelixer write paths** — list-append BlockStore writes O(n); delete-set merge
   O(n²) via re-sorting; sequence walks O(n) for anchor finding. Reads are well-served
   by the tuple cache; sustained write-heavy large docs are not. Reconstruction cost
   is well-bounded by the snapshot threshold (good) — the unbounded parts are writes
   and memory, not reads.
6. **Disk** (§5.4) — slow but certain.

Notably absent: scale *measurements*. The benchmark suite covers BlockStore lookups
only. No fork-10k-docs, merge-deep-divergence, insert-heavy, or recompute-storm
numbers exist, so the limits above are derived, not observed (§8 R9).

---

## 8. Recommendations (prioritized)

**P0 — before the next architectural step (federation, multi-agent, public MCP):**

- **R1. Draw the trust boundary in code, not docs.** Wire `Signing.verify_commit/1`
  into the import path behind a per-workspace policy knob (`accept_unsigned:
  true|false`), and route identity docs through SiblingMerger so the key store
  converges. The functions all exist; this is integration, not invention. Until then,
  add a one-line banner to the README/serve startup: *all peers and all code docs are
  fully trusted.*
- **R2. Gate code-doc execution.** Full sandboxing is a project (the MUD doc is right);
  a signer allowlist is a weekend: Orchestrator and ComputeRunner refuse to compile a
  source doc whose introducing commit isn't signed by a configured identity. This
  converts "any write anywhere = RCE" into "key compromise = RCE," which is a
  categorically better place to wait for real sandboxing.
- **R3. Supervise the things that must run.** Put the Orchestrator (or minimally the
  presence Reaper and a ViewCompute registry that re-hydrates computes from substrate
  declarations on boot) into the application supervision tree. Computed views and
  presence reaping should survive a BEAM restart without a human remembering them.

**P1 — the next structural investments:**

- **R4. Relieve the CommitStore.** Three independent steps, in order of cheapness:
  (a) serve reads outside the GenServer (CubDB snapshots support concurrent readers);
  (b) the already-acknowledged single-flight SnapshotWorker, replacing the debounce;
  (c) shard write serialization by doc-UUID hash across N coordinator processes —
  per-doc atomicity is the only invariant that needs a serial point, and it's per-doc.
- **R5. Decide the nested-CRDT question.** Either schedule CX-α (structural sub-type
  replay in yelixer snapshots) or promote the JSON-blob pattern from convention to
  enforced rule (a Schema/content-type guard that rejects nested sub-types in
  snapshot-eligible docs, plus a design-doc edict). The current state — a delayed
  data-loss trap avoided by folklore — is the worst of both.
- **R6. Backpressure and loop-safety for the reactive layer.** Coalesce recomputes
  (drain the mailbox, compute once against latest state — the read side already
  tolerates this), run computes async with a timeout, and add a cheap loop-breaker:
  a ViewCompute ignores commits whose update originated from its own writes, and a
  depth/rate fuse trips a view that recomputes >N times per second. Malleable
  software means users *will* wire cycles eventually.
- **R7. Dogfood green tokens for singletons.** The scheduler's at-most-one rule,
  TickBot, and MUD bot ownership are exactly Bursar's use case, and the bursar is
  built. Integrating it kills the `:global` partition hazards, enforces the scheduler
  caveat, and finally exercises the green channel for real — three birds.
- **R8. A retention story.** Even v1 helps: cold-storage GC for snapshots superseded
  by a higher-watermark snapshot (already sketched in snapshot-compaction.md), an
  archive/export verb for orphan sets that `Store.GC` already computes, and eviction
  for the SourceDoc compile cache.

**P2 — hygiene that compounds:**

- **R9. Measure before the limits are load-bearing.** A small scale-test suite: fork
  10k docs, merge after deep divergence, 1k-entry materialize, insert-heavy yelixer
  doc, 100-view fan-out. The review's scalability claims (§7) are derived; an
  afternoon of benchmarks converts them into a budget.
- **R10. Close the tracked seams.** Unify `commits:`/`blue:` (CX-4im); complete or
  delete `Yelixer.Transaction`; remove the legacy single-arg checkout re-root; factor
  shared path-resolution out of the LiveViews/CLI; add terminate-unsubscribe to
  wiki/chat LiveViews; wire remote `snapshot/2` through CommitStoreClient.
- **R11. Handle out-of-order imports.** A small pending-commit queue that retries
  namespace validation after subsequent imports land (or sorts catch-up batches
  topologically before import) removes the order-sensitivity in §6.1.

---

## 9. Closing assessment

The standard failure mode of "everything is an X" architectures is that the unifying
abstraction gets abandoned at the first inconvenient feature. Commonplace has passed
that test repeatedly — the issue tracker, the scheduler, the code-execution story all
chose the substrate when a sidecar would have been easier. The result is a system
whose conceptual surface area is genuinely small relative to its capability, and whose
documentation (after the literate pass) makes its own deferrals legible.

The flip side: the system is currently *all mechanism, little enforcement* in exactly
the dimensions (identity, authority, isolation, resource bounds) that its vision will
stress first. None of that work is research — the primitives exist and are tested;
they need to be wired in and turned on. The recommendations above are sequenced so
that the trust boundary lands before federation, the throughput ceiling is raised
before agent count grows, and the substrate's one real data-model trap is either
fixed or fenced.

Build 7's instinct — cross-epoch merge, derivation maps, deterministic snapshots —
shows the project doing the hardest distributed-systems thinking correctly. The next
phase's hardest work is less glamorous: turning the keys that are already in the locks.
