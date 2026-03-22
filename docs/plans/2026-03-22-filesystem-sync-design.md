# Filesystem Sync — Design Document

Date: 2026-03-22

## Overview

The filesystem sync agent bridges CRDT documents in CubDB with files on disk.
It watches for changes in both directions and keeps them in sync. This is how
users interact with commonplace documents using their normal editors and tools.

## Architecture

```
  ┌─────────────┐         ┌──────────────┐         ┌─────────────┐
  │  Filesystem  │ ◄─────► │  Sync Agent  │ ◄─────► │   CubDB /   │
  │  (files)     │         │  (GenServer) │         │  CommitStore │
  └─────────────┘         └──────────────┘         └─────────────┘
       inotify               │                        Yjs docs
       atomic writes         │ PubSub
       flock locking         ▼
                          magenta notifications
```

The sync agent is a GenServer that:
- Watches a directory tree for file changes (outbound: disk → CRDT)
- Listens for CRDT updates via PubSub (inbound: CRDT → disk)
- Uses the schema tree to map files to document UUIDs

## Implementation Phases

### Phase 1: Export (CRDT → Disk)

Write the document tree to disk. One-shot, no watching.

**What to build:**
- `Commonplace.Sync.Export` module
- Walk the schema tree, load each document, write content to disk
- Atomic writes: write to `.{name}.tmp.{pid}`, fsync, rename
- Create directories for schema docs with type "dir"
- CLI `export` command

**Tests:**
- Import a directory, export it, compare contents
- Roundtrip: import → export → diff should be empty
- Handles nested directories
- Handles empty directories
- Atomic write doesn't leave temp files on success

### Phase 2: File Watcher (Disk → CRDT, one direction)

Watch for filesystem changes and sync them into CRDT documents.

**What to build:**
- `Commonplace.Sync.Watcher` GenServer
- Uses `:file_system` hex package for inotify/FSEvents
- Watch parent directories (not files directly) for atomic rename detection
- Debounce: 100ms for files, 500ms for directories
- Periodic full-tree rescan every 1000ms to catch missed events
- On file change: read content, diff against CRDT state, apply update

**File stability check:**
- Before reading, poll file metadata 3 times at 50ms intervals
- Only read once size/mtime stops changing
- Catches partial writes from editors that don't use flock
- Timeout after 5s: read anyway with a warning

**Tests:**
- Write a file, verify CRDT doc updates
- Modify a file, verify diff is applied
- Delete a file, verify schema entry removed
- Create a new file, verify schema entry + doc created
- Debounce: rapid writes result in single sync

### Phase 3: Flock Locking

Coordinate reads and writes with other processes using the same files.

**What to build:**
- `Commonplace.Sync.FileLock` module
- `with_shared_lock(path, fun)` — LOCK_SH for reading
- `with_exclusive_lock(path, fun)` — LOCK_EX for writing
- Non-blocking attempts with 100ms retry, 30s timeout
- On timeout: proceed with warning (don't deadlock the sync loop)
- Erlang's `:file.open` with `{:lock, :shared}` / `{:lock, :exclusive}`

**Tests:**
- Shared lock allows concurrent reads
- Exclusive lock blocks readers and writers
- Lock released on normal return and on exception
- Timeout behavior: eventually proceeds

### Phase 4: Bidirectional Sync

Combine inbound and outbound sync with conflict prevention.

**What to build:**
- `Commonplace.Sync.Agent` GenServer — the main sync process
- Subscribes to PubSub blue channel for CRDT updates (inbound)
- Subscribes to file watcher for disk changes (outbound)
- Tracks pending outbound commits

**Ancestry check (prevents sync loops):**
- When receiving a CRDT update (inbound), check if our pending outbound
  commits are ancestors of the incoming update
- If yes: safe to write to disk (server already has our changes)
- If no: queue the inbound write until our commits land
- This prevents ping-pong where local edits get overwritten by stale
  server state

**Sync directions:**
- Outbound (disk → CRDT): file event → debounce → stability check →
  LOCK_SH → read content → diff into Yjs update → commit → record pending
- Inbound (CRDT → disk): PubSub update → ancestry check → LOCK_EX →
  atomic write → emit magenta notification

**Tests:**
- Edit file on disk, verify CRDT doc updates
- Update CRDT doc, verify file on disk updates
- Concurrent edits from both sides merge correctly
- Sync loop prevention: local edit doesn't bounce back from server
- New file on disk creates doc + schema entry
- Deleted file on disk removes schema entry

### Phase 5: Inode Shadow Tracking (advanced)

Handle processes that hold stale file descriptors after atomic writes.

**What to build:**
- `Commonplace.Sync.InodeTracker` module
- Before atomic write: create hardlink to old inode in `.commonplace-shadow/`
  named `{dev}-{ino}`
- Shadow watcher watches `.commonplace-shadow/` for modifications
- When a write to an old inode is detected: read content, create a CRDT
  merge commit using the old inode's commit_id as parent
- Rename detection: if a file is deleted then a new file appears with the
  same inode within 10s, treat as rename not delete+create

**This is Unix-specific** — relies on hardlinks preserving inode identity.

**Tests:**
- Write to stale file descriptor after atomic rename, verify merge
- Rename detection works
- Shadow cleanup after sync completes

## Dependencies

- `{:file_system, "~> 1.0"}` — inotify/FSEvents wrapper for Elixir
- Erlang `:file` module — for flock locking
- Existing: CommitStore, Schema, Walk, ContentType, Magenta

## Key Principles

1. **Never show partial content** — atomic writes ensure readers see old or new, never half-written
2. **Don't deadlock** — lock timeouts prevent sync loop stalls
3. **Don't lose data** — inode shadow tracking captures writes to stale FDs
4. **Don't sync-loop** — ancestry checks prevent local→server→local bounce
5. **Degrade gracefully** — if watching fails, periodic rescan catches up
