# Sparse Sync: Multiple Checkouts with Per-Entry Agents

**Date**: 2026-03-24
**Status**: Draft
**Issue**: CX-6ib

## Problem

The current sync agent materializes an entire tree to a single disk directory. Users need to:

- Check out arbitrary subtrees (a branch, a subdirectory, a single file) to any location on the filesystem
- Maintain multiple concurrent checkouts of the same or overlapping content
- Change what a checkout points at without losing in-flight writes
- Edit files offline and have changes sync when reconnected

## Design Overview

One shared CommitStore (CubDB), multiple checkouts. Each checkout is a `(sync_dir, root_uuid)` pair with its own supervision tree of lightweight agents — one process per file. The tree of agents mirrors the tree of documents.

## 1. Process Architecture

```
CommonplaceSupervisor
  └── CheckoutRegistry (GenServer)
        └── DynamicSupervisor
              ├── CheckoutSupervisor (dir checkout: /home/jes/workspace → uuid-main)
              │     ├── DirAgent        — watches schema, spawns/kills entry agents
              │     ├── EntryAgent "readme.md"    — syncs one file
              │     ├── DirAgent "src/"            — subdirectory (recursive)
              │     │     ├── EntryAgent "main.ex"
              │     │     └── EntryAgent "utils.ex"
              │     └── EntryAgent "config.txt"
              │
              └── CheckoutSupervisor (file checkout: /tmp/todo.txt → uuid-xyz)
                    └── FileAgent       — syncs one file, no schema
```

### CheckoutRegistry

GenServer that persists checkout definitions and manages their lifecycles.

- Stores checkout list in `.commonplace/checkouts.json` (written atomically via temp+rename to prevent corruption on crash)
- On init, reads the file and spawns a CheckoutSupervisor per entry under a DynamicSupervisor
- API: `register/2`, `unregister/1`, `reroot/2`, `list/0`

### DirAgent

One per directory/schema node. Responsibilities:

- Holds the schema doc UUID and disk path for this directory
- On init: reads schema, spawns an EntryAgent or child DirAgent for each entry
- Watches for schema changes: new entries spawn agents, removed entries stop agents
- Handles inode-based rename detection across sibling files
- Owns the `.commonplace-shadow/` directory for its subtree
- Runs periodic GC on stale shadow hardlinks
- Handles new files appearing on disk: creates doc, adds schema entry, spawns EntryAgent
- Detects deleted files: removes schema entry, stops EntryAgent

### EntryAgent

One per file. Responsibilities:

- Holds doc UUID, file path, last written commit ID, last known content hash
- Bidirectional sync cycle (periodic or triggered by file watcher):
  - **Inbound** (CRDT → disk): if latest commit != last written, check ancestry, write file
  - **Outbound** (disk → CRDT): if file hash changed, read file, create commit
- Shadow hardlink management:
  - Before atomic write: hardlink old file to `.commonplace-shadow/{dev}-{ino}`
  - On next cycle: check if shadow's fingerprint changed (stale write detection)
  - If stale write detected: merge it as a CRDT update with correct parent commit

### FileAgent

An EntryAgent configured with `standalone: true` — no parent DirAgent. Used when a checkout targets a single file rather than a directory. Manages its own shadow directory and hardlinks. Same module as EntryAgent, different init options.

## 2. Docref Resolution

A docref is a flexible pointer to a node in the tree. New module: `Commonplace.Tree.Docref`.

### Supported Formats

| Format | Example | Behavior |
|--------|---------|----------|
| Raw UUID | `abc123-def-456` | Used directly |
| Name | `main` | Looked up in root schema |
| Path | `main/docs/plans` | Walked through nested schemas |
| Path@commit | `main/docs@cid-xyz` | Path resolved, then forked at that commit (deferred — see below) |

### Resolution

```elixir
Docref.resolve(store, "main/docs/plans")
# walks: root schema → "main" → uuid-abc
#        uuid-abc schema → "docs" → uuid-def
#        uuid-def schema → "plans" → uuid-ghi
# => {:ok, uuid-ghi}

Docref.resolve(store, "main/docs@cid-xyz")
# resolves "main/docs" → uuid-def
# forks uuid-def at commit cid-xyz → new-uuid
# => {:ok, new-uuid}
```

The `@commit` form automatically forks, creating a live writable checkout. No special read-only mode — every checkout is always live.

**Deferred: `@commit` syntax.** Forking at an arbitrary commit requires reconstructing the schema at that historical point and recursively forking the subtree as it existed then. This needs `DocBuilder.reconstruct_doc_at/3` plus point-in-time schema walking, which is additional complexity. The initial implementation supports UUID, name, and path docrefs. `@commit` is a follow-up.

Resolution happens at checkout creation and at reroot time. The resolved UUID is stored in the checkout registration. The checkout does not follow renames — if the name-to-UUID mapping changes, the checkout keeps pointing at the same UUID.

## 3. Checkout Registry & Persistence

### Storage

`.commonplace/checkouts.json`:
```json
[
  {"sync_dir": "/home/jes/workspace", "uuid": "uuid-main", "type": "dir"},
  {"sync_dir": "/tmp/todo.txt", "uuid": "uuid-xyz", "type": "file"}
]
```

### API

| Function | Description |
|----------|-------------|
| `register(sync_dir, docref)` | Resolve docref, persist, spawn agents |
| `unregister(sync_dir)` | Shadow-preserve, stop agents, remove from file |
| `reroot(sync_dir, new_docref)` | Shadow-preserve old, resolve new, update, respawn |
| `list()` | Return all active checkouts with status |

### Out-of-Tree Checkouts

For checkouts outside the `.commonplace/` tree (e.g., `/tmp/scratch`), a `.commonplace-ref` breadcrumb file is dropped in the checkout directory. It contains the absolute path to the `.commonplace/` database directory. Created by `register/2`, removed by `unregister/1`. This allows the CLI's tree-climbing logic to find the database from any checkout location.

### CommitStore Access

DirAgent and EntryAgent access the CommitStore through `CommitStoreClient` (not `CommitStore` directly), preserving the ability to sync against a remote serve node in the future.

## 4. DirAgent Sync Behavior

### Directory Scan Cycle

1. File watcher fires (or periodic timer)
2. DirAgent scans its directory, compares against known schema entries:
   - **New inode + new name** → new file created on disk. Create doc, add to schema, spawn EntryAgent
   - **Known inode + different name** → rename detected. Update schema entry name, update EntryAgent's path
   - **Known inode + same name** → no structural change. EntryAgent handles content sync
   - **Missing inode** → file deleted on disk. Remove from schema, stop EntryAgent
3. DirAgent subscribes to CRDT-side schema changes via `Phoenix.PubSub` (broadcasting on `{:commit, schema_uuid}`). When a new commit arrives for this DirAgent's schema:
   - New entry in schema not on disk → spawn EntryAgent, which writes file on first inbound sync
   - Entry removed from schema → stop EntryAgent, delete file from disk
   - EntryAgents similarly subscribe to `{:commit, doc_uuid}` for immediate inbound sync rather than polling

### Subdirectory Handling

When a schema entry has type "dir", DirAgent spawns a child DirAgent instead of an EntryAgent. The child DirAgent reads that subdirectory's schema and manages its own children recursively.

### Schema `sync` Field

The existing `Schema.Entry` has a `sync` boolean field with `activate/deactivate` functions. DirAgent respects this: entries with `sync: false` do not get agents spawned. Note that this flag lives in the shared CRDT schema and affects all nodes — it is not the per-checkout mechanism (which is the CheckoutRegistry). The `sync` field is useful for marking branches that no node should sync (e.g., archived branches).

## 5. EntryAgent Sync Behavior

### Inbound (CRDT → disk)

1. Check latest commit for this doc UUID
2. If `latest_commit_id == last_written_commit_id`: skip (no CRDT changes)
3. Check ancestry: is latest commit a descendant of last written? (prevents sync loops)
4. If yes: reconstruct doc content, hash it
5. If hash differs from `known_hash`: shadow the old file, atomic write, update tracking
6. Update `last_written_commit_id` and `known_hash`

### Outbound (disk → CRDT)

1. Read file, compute hash
2. If `hash == known_hash`: skip (no disk changes)
3. Create new commit with file content, parented on `last_written_commit_id`
4. Update `last_written_commit_id` and `known_hash`

### Shadow Hardlinks

Before each atomic write:

1. `File.ln(file_path, ".commonplace-shadow/{dev}-{ino}")` — preserves the old inode
2. Record the shadow's fingerprint (size + MD5)
3. Perform atomic write (write temp → fsync → rename)
4. On next sync cycle: compare shadow fingerprint to detect stale writes
5. If stale write detected: load the doc at the shadow's parent commit, diff the stale content against it, and produce an incremental CRDT update (not a full-state replacement). This preserves character-level merge semantics

Each DirAgent creates and GCs a `.commonplace-shadow/` in its own directory. EntryAgents write shadow hardlinks into their parent DirAgent's shadow directory. DirAgent runs periodic GC: remove shadow hardlinks that have been idle for >1 hour and lived for >5 minutes (matching Rust implementation's constants).

## 6. CLI Commands

```bash
# Create a directory checkout
commonplace checkout /home/jes/workspace main/docs

# Create a file checkout
commonplace checkout /tmp/todo.txt main/notes/todo.txt --file

# List active checkouts
commonplace checkouts

# Change what a checkout points at (shadow-preserves in-flight writes)
commonplace reroot /home/jes/workspace feature-branch

# Stop syncing a checkout
commonplace checkout --remove /home/jes/workspace

# Checkout at a specific commit (auto-forks for live editing)
commonplace checkout /tmp/snapshot main/docs@commit-abc

# Existing command works unchanged for "current directory" checkout
commonplace sync
```

Docrefs accept any format: raw UUID, name, path, or path@commit.

## 7. Edge Cases

### Overlapping Checkouts

Fully supported. Two checkouts of the same subtree (or overlapping subtrees) sync through the CRDT. Edit in one place, it appears in the other. This is fundamental to the design.

**Schema write coordination**: Overlapping directory checkouts share a schema UUID. When two DirAgents both detect new files simultaneously, their schema mutations must be serialized to avoid CRDT state corruption. Each schema UUID has a coordinating process (registered via `Registry`) that serializes schema mutations. DirAgents send schema edits through this coordinator rather than writing directly. This ensures incremental CRDT updates are applied sequentially against the correct parent state. For leaf document content, no coordination is needed — Y.js CRDTs merge automatically.

### Reroot with Write Preservation

On reroot:

1. Create shadow hardlinks for all tracked files (preserves in-flight writes)
2. Stop all EntryAgents (any in-progress atomic writes complete safely)
3. Resolve new docref
4. Spawn new agent tree
5. On first sync cycle, new EntryAgents detect shadow stale writes if any occurred during the transition

### Root Directory Deleted (`rm -rf`)

Appears as individual file deletions to the DirAgent — each file disappears one at a time. Schema entries are removed, docs remain in CommitStore (append-only, never loses data). Recovery: `commonplace checkout` the same path again, pointing at the same UUID or an older commit.

### Files Kept on Deactivation

When a checkout is removed (`--remove`), files stay on disk. When re-checked-out, EntryAgents detect that files already exist with potentially different content and sync accordingly (catch-up).

### CommitStore Contention

Multiple EntryAgents write commits to the same CubDB. CubDB is single-writer and serializes naturally via its GenServer. No additional coordination needed.

## 8. Migration from Current Sync Agent

The current monolithic `Sync.Agent` handles a single `(sync_dir, root_uuid)` pair. Migration:

1. Extract the per-file sync logic from Agent into EntryAgent
2. Extract the directory-scanning logic into DirAgent
3. The existing `.commonplace/root` file becomes the first entry in `checkouts.json`
4. `commonplace sync` continues to work — it uses the checkout registered for the current directory

The existing `InodeTracker` module and `Export` module provide building blocks that DirAgent and EntryAgent can reuse.

## 9. Not In Scope

- **Multi-database coordination** (CX-108): all checkouts share one CommitStore
- **Network sync**: this design is local-only; network sync is orthogonal
- **Filesystem notifications**: can use polling initially, add `FileSystem` watcher later as optimization
- **Conflict UI**: CRDT handles concurrent edits automatically; schema-level conflicts use existing merge flow
