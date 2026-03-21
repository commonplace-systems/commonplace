# Commonplace Elixir — Design Document

Date: 2026-03-21

## Overview

Commonplace is a CRDT document store where everything is a document with a UUID, organized in a tree. Documents sync between peers using Yjs-compatible CRDTs. The Elixir version builds on yelixer (a pure Elixir Yjs port) and leverages BEAM primitives — GenServers, supervision trees, Phoenix PubSub — as the native dataflow layer.

Key principle: **BEAM fundamentals first**. No HTTP or MQTT until the core is solid. GenServer-per-document, PubSub for dataflow, supervision trees for lifecycle — these ARE the dataflow layer. External interfaces come later.

### Differences from Rust Version

- **CRDT lib**: Native Elixir (yelixer) instead of yrs Rust bindings. Wire-compatible with Yjs V1 binary protocol for interop.
- **Dataflow**: Phoenix PubSub + BEAM distribution instead of MQTT. Preserves color channel semantics and observability.
- **Web rendering**: Phoenix LiveView (server-side rendered, live updates) instead of client-only Yjs rendering.
- **Distribution**: BEAM node clustering instead of MQTT broker coordination.
- **Storage**: CubDB (pure Elixir embedded KV) instead of redb.
- **Process isolation**: BEAM process boundaries + ETS access control instead of filesystem sandboxing.

### Core Concepts (from architecture discussions)

- **Everything is documents, dataflow is the only verb.** Documents have UUIDs, are organized in a tree. Reachability from root = liveness.
- **Color channels** define communication semantics:
  - **Blue** — CRDT state (the documents themselves)
  - **Cyan** — directed writes into blue
  - **Red** — persistent event logs (YArray-backed)
  - **Magenta** — ephemeral fire-and-forget messages
  - **Green** — exclusive locks managed by a bursar process
- **Commit DAG** — Merkle-CRDT pattern (per arXiv:2004.00107). Content-addressed commits storing Yjs update deltas on top of live CRDT merge. Gives tamper-evident history and time-travel.
- **Branching** — deep-copy fork with new UUIDs. ForkManifest tracks old-to-new UUID mappings and fork-point commit. Branches are fully independent document trees.

## Project Structure

Elixir umbrella application:

```
commonplace/
├── apps/
│   ├── yelixer/            # CRDT lib (git subtree from jes5199/yelixer)
│   ├── commonplace/        # Core: doc store, dataflow, commit DAG
│   └── commonplace_web/    # Phoenix LiveView UI (phase 2)
├── config/
├── docs/plans/
└── mix.exs                 # Umbrella root
```

Yelixer is maintained as a git subtree — editable in-place, pushable back to the upstream repo when changes stabilize.

## Core App: `commonplace`

### Module Layout

```
apps/commonplace/lib/commonplace/
├── document/
│   ├── server.ex           # GenServer per document (wraps Yelixer.Doc)
│   ├── registry.ex         # Registry mapping UUID -> pid
│   └── supervisor.ex       # DynamicSupervisor for document processes
├── store/
│   ├── commit.ex           # Merkle DAG commit struct (content-addressed)
│   ├── commit_store.ex     # CubDB-backed persistent commit storage
│   └── snapshot.ex         # Encode/decode full doc state for commits
├── dataflow/
│   ├── channel.ex          # Color channel abstraction (blue/cyan/red/magenta/green)
│   ├── pubsub.ex           # Phoenix PubSub wrapper with topic conventions
│   └── tap.ex              # Debug observer for message flows
├── tree/
│   ├── schema.ex           # Directory doc schema (children list)
│   ├── reachability.ex     # Walk tree from root, determine liveness
│   └── fork.ex             # Deep-copy branch: new UUIDs + ForkManifest
├── process/
│   ├── orchestrator.ex     # Reads __processes.json, manages lifecycle
│   ├── sandbox.ex          # Scoped document tree view per process
│   └── runner.ex           # Execute processes (evaluate/sandbox/command)
└── application.ex          # Top-level supervisor
```

### Document Server

`Document.Server` is a GenServer wrapping `Yelixer.Doc`. It does NOT use `Yelixer.DocServer` — we need our own GenServer with commit and PubSub integration.

Responsibilities:
- Holds live `Yelixer.Doc` state in memory
- Applies edits via Yelixer type APIs (Text, YMap, Array)
- Publishes changes to PubSub on blue/cyan channels
- Commits state to CubDB on request (or auto-commit)
- Handles sync protocol (step1/step2) for peer exchange

### Storage

**CubDB** for persistent commit storage (the Merkle DAG). Each commit contains:
- Content-addressed ID (hash of update bytes + parent ID)
- Parent commit ID
- Yjs update delta (binary, encoded via `Yelixer.Encoding.encode_update/1`)
- Timestamp and metadata

**ETS** is available for hot indexing if needed, but the primary hot state lives in the Document.Server process memory.

Documents are started on-demand. When a UUID is first accessed, `Document.Supervisor` starts a `Document.Server` which loads state by replaying commits from CubDB. Documents that haven't been touched can be terminated and rehydrated later.

### PubSub Topic Conventions

```
blue:{uuid}      — CRDT state updates for a document
cyan:{uuid}      — directed writes into a document
red:{uuid}       — persistent event log entries
magenta:{path}   — ephemeral commands (supports wildcards)
green:{uuid}     — lock acquisition/release
```

Phoenix PubSub handles topic-based routing and wildcard subscriptions for path-based topics. A `Tap` module provides debug observability for any message flow.

## Supervision Tree

```
Commonplace.Application (top supervisor)
├── Registry (Commonplace.Document.Registry)
├── Phoenix.PubSub (Commonplace.PubSub)
├── Commonplace.Store.CommitStore (CubDB GenServer)
├── Commonplace.Document.Supervisor (DynamicSupervisor)
│   ├── Document.Server {uuid-1}
│   ├── Document.Server {uuid-2}
│   └── ...
├── Commonplace.Process.Orchestrator
│   └── (spawns process runners based on __processes.json)
└── Commonplace.Dataflow.Tap (optional debug observer)
```

### Crash Recovery

If a document server crashes, the supervisor restarts it. On init, it replays commits from CubDB to reconstruct state. Uncommitted changes are lost — this is intentional (same as the Rust version). Frequent auto-commit mitigates this.

### Fork / Branching

Fork creates new UUIDs for every doc in the branch via `UUID.uuid4()`, deep-copies Yjs state via encode/decode roundtrip through `Yelixer.Encoding`, rewrites schema references to point to new UUIDs, and stores a `ForkManifest` document. Each forked doc gets its own new GenServer under the DynamicSupervisor.

## Yelixer Integration

Yelixer lives at `apps/yelixer/` as a git subtree from `jes5199/yelixer`. It provides:

- **Types**: `Yelixer.Types.Text`, `Yelixer.Types.Array`, `Yelixer.Types.YMap`
- **Encoding**: Yjs V1 binary protocol (LEB128, state vectors, delete sets, updates)
- **Sync Protocol**: Step1/Step2 message exchange
- **Doc**: Root document container with type registration
- **Integration**: YATA algorithm for conflict resolution

Current status: all core types implemented, 5320/5320 yrs dataset compatibility tests passing. Wire-compatible with Yjs V1 binary format.

Known gaps to address:
- `Yelixer.Types` helper module for nested type JSON resolution (~50 lines)
- XML types (YXMLElement, YXMLFragment, YXMLText) — if needed for LiveView rendering
- V2 encoding, UndoManager, RelativePosition — nice-to-haves for later

## Yjs Merge Semantics

Critical semantics the CRDT lib must preserve:

1. **YText** — YATA algorithm. Concurrent inserts at the same position are deterministically ordered by client ID (lower ID wins). Character-level operations.
2. **YMap** — Last-writer-wins per key, using lamport timestamps. Rightmost item in sequence wins on conflict.
3. **YArray** — Similar to YText. Ordered items with YATA conflict resolution.
4. **State vector diffing** — Computing "what updates does peer B need that peer A has?"
5. **Delete sets / tombstones** — Yjs tracks deletions separately from insertions. Tombstones are required for convergence. Never rely on key absence in Yjs maps — always use explicit values.

## Merkle-CRDT Commit Layer

Based on arXiv:2004.00107 (Sanjuan et al.). Two composing layers:

1. **CRDT layer** (Yelixer) — live merge, eventual consistency, conflict resolution
2. **Commit DAG layer** — content-addressed history, causal ordering, time-travel

The Merkle-Clock embedded in the DAG acts as a logical clock, replacing version vectors. Each commit node is `(CID, payload, children)` where CID = hash(payload + children). The DAG-Syncer component (future: BEAM distribution) fetches missing nodes by CID. The Broadcaster (Phoenix PubSub) announces new roots.

Key properties:
- Transport-agnostic sync (works over any messaging layer)
- Per-object causal consistency and gap detection
- Self-verified, de-duplicated nodes via content addressing
- Tolerates dropped, reordered, or duplicated messages

## Phases

### Phase 1 — BEAM Fundamentals
- Umbrella scaffold with yelixer subtree
- Document store: GenServer per doc, Registry, DynamicSupervisor
- CubDB commit store with Merkle DAG
- PubSub dataflow with color channel semantics
- CLI tools via Mix tasks
- Tree operations: schema, reachability, fork

### Phase 2 — Phoenix LiveView
- `commonplace_web` app with Phoenix
- Document browsing and tree navigation
- Live document editing with PubSub-driven updates
- Per-user sessions as forked UI branches

### Phase 3 — Distribution
- BEAM node clustering (libcluster)
- Distributed document sync via PubSub + Yelixer sync protocol
- Distributed Registry for cross-node document lookup

### Phase 4 — External Bridges
- MQTT bridge for external tool integration
- HTTP/REST API for non-BEAM clients
- Filesystem sync agent (port of Rust commonplace-sync)
- y-websocket gateway for browser-based Yjs clients
