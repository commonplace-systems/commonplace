# Flock NIF Design — CX-joi

## Summary

Port the flock(2) + atomic write coordination from commonplace-rs to the Elixir port. Implements real OS-level advisory file locks via a small C NIF, replacing the unused GenServer-based FileLock module.

## Decision Record

- **NIF placement**: In `commonplace` app as `Commonplace.Sync.Flock` (alongside existing sync modules)
- **Lock target**: Lock the target file directly (not sidecar .lock files), matching Rust approach
- **Timeout behavior**: Non-blocking LOCK_NB + 100ms retry + 30s timeout + proceed with warning (never deadlock sync loop)
- **FileLock module**: Remove entirely — replaced by NIF-based Flock

## Architecture

### NIF Layer (`c_src/flock_nif.c`)

Minimal C NIF exposing 3 functions:

- `nif_open(path, mode)` — opens file with O_CREAT, returns fd as NIF resource
- `nif_flock(fd, operation)` — calls `flock(fd, LOCK_EX|LOCK_NB)` or `flock(fd, LOCK_SH|LOCK_NB)`
- `nif_close(fd)` — closes fd, implicitly releases lock

The NIF is stateless — open/flock/close only. No retry logic, no timeouts, no state management in C.

Build: `elixir_make` hex package, source in `apps/commonplace/c_src/flock_nif.c`, compiled via Makefile.

### Elixir Wrapper (`Commonplace.Sync.Flock`)

High-level API:

```elixir
# Acquire exclusive lock, run function, release
Flock.with_exclusive_lock(path, timeout \\ 30_000, fun)

# Acquire shared lock, run function, release
Flock.with_shared_lock(path, timeout \\ 30_000, fun)

# Low-level: returns {:ok, guard} or {:error, :locked}
Flock.try_lock(path, :exclusive | :shared)
```

Retry loop: 100ms interval, configurable timeout. On timeout: `Logger.warning("flock timeout on #{path}")`, proceeds without lock.

Lock release guaranteed via `try/after` (Elixir equivalent of Rust RAII FlockGuard).

## Data Flow

### Write path (SyncAgent inbound / CRDT → disk)

```
SyncAgent detects new commit for file
  → Flock.with_exclusive_lock(file_path, 30_000, fn ->
      Export.atomic_write(file_path, content)
    end)
  → Lock released automatically
```

### Read path (SyncAgent outbound / disk → CRDT)

```
SyncAgent detects disk change
  → Flock.with_shared_lock(file_path, 30_000, fn ->
      File.read!(file_path)
    end)
  → Content hashed, compared, committed to store
```

### Sandbox process coordination

```
SandboxExecRunner spawns "sh -c ..."
  → Sandbox process can: flock --shared /path/to/file cat /path/to/file
  → Advisory locks are cooperative, not mandatory
```

### Timeout behavior

```
try_lock returns :would_block
  → sleep 100ms, retry
  → after 30s: Logger.warning("flock timeout on #{path}"), proceed without lock
  → sync loop continues, never deadlocks
```

## Error Handling

- **File doesn't exist yet**: `nif_open` creates it (O_CREAT). Lock on empty file is valid; atomic_write fills it.
- **Permission denied**: `nif_open` returns `{:error, :eacces}`. Wrapper logs warning, proceeds without lock.
- **NIF crash**: flock(2) is a trivial syscall, extremely unlikely. NIF surface kept minimal to reduce risk.
- **Process dies holding lock**: OS releases flock when fd closes. BEAM process death closes all fds. No leaked locks.
- **Stale locks**: Not possible with flock(2) — lock is tied to fd lifetime, unlike lockfiles.

## Integration Points

1. **Export.atomic_write/2** — wrap with `Flock.with_exclusive_lock/3`
2. **SyncAgent outbound reads** — wrap file reads with `Flock.with_shared_lock/3`
3. **SandboxExecRunner** — sandbox processes coordinate via system `flock` command on same files

## Removed

- `Commonplace.Sync.FileLock` module (`lib/commonplace/sync/file_lock.ex`)
- `Commonplace.Sync.FileLockTest` (`test/commonplace/sync/file_lock_test.exs`)

## Testing Strategy

- **NIF unit tests**: open/lock/unlock/close cycle, shared locks concurrent, exclusive blocks shared
- **Integration test**: two BEAM processes racing on the same file, verify serialization
- **Timeout test**: hold lock in one process, verify other process times out and proceeds with warning
- **Atomic write integration**: verify `Export.atomic_write` works correctly under lock
- **Negative tests**: permission denied, lock on nonexistent path (auto-creates)

## Reference

- Rust implementation: `commonplace-rs/crates/commonplace-watcher/src/flock.rs`
- Rust atomic writes: `commonplace-rs/src/sync/transport/shadow.rs`
- Existing Elixir atomic write: `apps/commonplace/lib/commonplace/sync/export.ex` (`atomic_write/2`)
