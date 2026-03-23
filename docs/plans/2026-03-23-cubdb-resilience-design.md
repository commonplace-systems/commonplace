# CubDB Resilience + CLI/Serve Coexistence

**Date:** 2026-03-23
**Issue:** CX-539
**Status:** Design

## Problem

CubDB has two related problems:

1. **Corruption on unclean shutdown.** When the BEAM exits uncleanly (SIGKILL, OOM), CubDB data becomes unreadable ("invalid external representation of a term", "End of file"). The workspace requires re-initialization, losing all CRDT history.

2. **No concurrent access.** CLI commands (`commonplace ls`, `cat`, `import`) start separate BEAM VMs that try to open the same CubDB. This conflicts with a running `commonplace serve` and causes corruption.

### Root Causes

- **Non-atomic dual writes.** `create_commit` issues two sequential `CubDB.put` calls (commit body + latest pointer). A crash between them leaves the DAG inconsistent.
- **No recovery path.** When CubDB raises on corrupt data, CommitStore crash-loops forever.
- **Single-process store, multi-process CLI.** CubDB is designed for one BEAM process. The CLI escript model creates a new BEAM per command.

### What CubDB Already Does Right

- Append-only file format with header-block recovery (`get_latest_good_header`)
- `auto_file_sync: true` by default (fdatasync on every write)
- Compaction cleanup on startup (removes orphaned `.compact` files)

## Design: Two Layers

### Layer 1: CubDB Hardening (defense in depth)

These changes improve crash resilience regardless of the architecture.

#### 1a. Atomic commit writes

Replace two sequential `CubDB.put` calls in `create_commit` with `CubDB.put_multi`:

```elixir
# Before (two writes, crash between them = inconsistent):
CubDB.put(state.db, {:commit, commit.id}, commit)
CubDB.put(state.db, {:latest, doc_uuid}, commit.id)

# After (single atomic write):
CubDB.put_multi(state.db, [
  {{:commit, commit.id}, commit},
  {{:latest, doc_uuid}, commit.id}
])
```

#### 1b. Startup integrity probe

On CommitStore init, probe CubDB with a small `select`. If it raises, archive the corrupt database and start fresh:

```elixir
def init(opts) do
  {:ok, db} = CubDB.start_link(data_dir: path)

  case probe_integrity(db) do
    :ok -> {:ok, %{db: db}}
    {:error, reason} ->
      Logger.warning("CubDB corrupt: #{inspect(reason)}. Archiving and starting fresh.")
      CubDB.stop(db)
      archive_corrupt_db(path)
      {:ok, db2} = CubDB.start_link(data_dir: path)
      {:ok, %{db: db2}}
  end
end
```

The archived database is moved to `commits.corrupt.<timestamp>` for forensic recovery.

#### 1c. Explicit CubDB options

Make durability settings explicit (currently implicit defaults):

```elixir
CubDB.start_link(
  data_dir: path,
  auto_file_sync: true,   # fdatasync on every write
  auto_compact: true       # reclaim space
)
```

#### 1d. Supervisor restart bounds

Set `max_restarts: 2, max_seconds: 10` on CommitStore's supervisor to fail fast instead of crash-looping.

### Layer 2: Distributed Erlang (CLI talks to serve)

When `commonplace serve` is running, CLI commands connect to its BEAM node and call CommitStore remotely instead of opening CubDB directly.

#### 2a. Serve starts as a named node

`commonplace serve` starts the BEAM with `--sname commonplace_<workspace_hash>` and writes the node name to `.commonplace/node_name`:

```
commonplace_a1b2c3@hostname
```

The workspace hash prevents collisions between multiple workspaces on the same machine.

#### 2b. CLI tries to connect before opening CubDB

`CLI.ensure_started` gains a new path:

```
1. Read .commonplace/node_name
2. Start a temporary BEAM node (--sname commonplace_cli_<random>)
3. Node.connect(serve_node_name)
4. If connected: route all CommitStore calls to the remote node
5. If not connected: acquire file lock, open CubDB directly (offline mode)
```

All existing CLI commands work unchanged — the CommitStore API is the same, it just runs on a different node.

#### 2c. File lock for fallback access

When the CLI falls back to direct CubDB access (serve not running), it acquires an exclusive file lock on `.commonplace/commits.lock`:

```elixir
defp acquire_db_lock(data_dir) do
  lock_path = Path.join(data_dir, "commits.lock")
  {:ok, fd} = :file.open(lock_path, [:write])

  case :file.lock(fd, :exclusive, :nonblocking) do
    :ok -> {:ok, fd}
    {:error, :eagain} ->
      :file.close(fd)
      {:error, :locked}
  end
end
```

If the lock is held (serve is running, or another CLI has it), the CLI prints an error:

```
Cannot access database — commonplace serve is running.
Use distributed Erlang connection (automatic) or stop serve first.
```

This prevents the concurrent access corruption. The lock is released when the CLI process exits.

#### 2d. CommitStore client module

A thin client that dispatches calls to either the local or remote CommitStore:

```elixir
defmodule Commonplace.Store.CommitStoreClient do
  def latest_commit(doc_uuid) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:latest_commit, doc_uuid})
      :local ->
        CommitStore.latest_commit(doc_uuid)
    end
  end
end
```

CLI commands use `CommitStoreClient` instead of `CommitStore` directly. The serve command uses `CommitStore` directly (it owns the database).

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Serve running, CLI connects | CLI calls remote CommitStore, no CubDB opened |
| Serve not running, CLI runs | CLI acquires lock, opens CubDB directly |
| Serve starts while CLI holds lock | Serve waits for lock (or errors with "CLI holding database") |
| CLI can't connect (network/cookie issue) | Falls back to lock + direct access |
| Serve crashes, lock is released | OS releases flock on process exit automatically |
| Two CLIs race for fallback access | Second CLI gets lock error, retries or fails |
| CubDB corrupt on startup | Integrity probe archives corrupt DB, starts fresh |

## Implementation Order

| Phase | Tasks | Risk |
|-------|-------|------|
| 1 | 1a: put_multi atomic writes | None — one-line change |
| 1 | 1c: explicit CubDB options | None — documenting defaults |
| 1 | 1d: supervisor restart bounds | Low |
| 2 | 1b: startup integrity probe + archive | Low |
| 3 | 2a: serve as named node | Medium |
| 3 | 2c: file lock for fallback | Low |
| 3 | 2b: CLI distributed Erlang connect | Medium |
| 3 | 2d: CommitStoreClient | Medium |

Phase 1 can ship immediately. Phase 2 is a standalone improvement. Phase 3 is the architecture change.

## Files Changed

| File | Change |
|------|--------|
| `apps/commonplace/lib/commonplace/store/commit_store.ex` | put_multi, integrity probe, explicit options |
| `apps/commonplace/lib/commonplace/store/commit_store_client.ex` | New: remote/local dispatch |
| `apps/commonplace/lib/commonplace/application.ex` | Supervisor restart bounds |
| `apps/commonplace_cli/lib/commonplace/cli.ex` | Node connection logic in ensure_started |
| `apps/commonplace_cli/lib/commonplace/cli/serve.ex` | Start as named node, write node_name file |
