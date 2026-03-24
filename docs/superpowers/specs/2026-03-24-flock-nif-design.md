# Flock NIF Design — CX-joi

## Summary

Port the flock(2) + atomic write coordination from commonplace-rs to the Elixir port. Implements real OS-level advisory file locks via a small C NIF, replacing the unused GenServer-based FileLock module.

## Decision Record

- **NIF placement**: In `commonplace` app as `Commonplace.Sync.Flock` (alongside existing sync modules)
- **Lock target**: Lock the target file directly (not sidecar .lock files), matching Rust approach
- **Timeout behavior**: Non-blocking LOCK_NB + 100ms retry + 30s timeout + proceed with warning (never deadlock sync loop)
- **FileLock module**: Remove entirely — replaced by NIF-based Flock
- **Platform**: Linux and macOS. Advisory locks only (not enforced). flock(2) does not work on NFS mounts on macOS (silently succeeds without locking).

## Architecture

### NIF Layer (`c_src/flock_nif.c`)

Minimal C NIF exposing 3 functions:

- `nif_open(path, mode)` — opens file (no O_CREAT — returns `{:error, :enoent}` if file doesn't exist, matching Rust behavior). Returns fd wrapped as a NIF resource.
- `nif_flock(fd, operation)` — calls `flock(fd, LOCK_EX|LOCK_NB)` or `flock(fd, LOCK_SH|LOCK_NB)`. Returns `:ok`, `{:error, :would_block}`, or `{:error, :eintr}`. Handles EINTR by returning it to Elixir (retry immediately without sleeping).
- `nif_close(fd)` — closes fd, implicitly releases lock.

**NIF resource destructor**: The fd is wrapped in a NIF resource with a destructor that closes the fd on garbage collection. This ensures lock release even if the owning process crashes without calling `nif_close`. `nif_close` is the primary release mechanism; the destructor is a safety net.

The NIF is stateless — open/flock/close only. No retry logic, no timeouts, no state management in C.

**Build**: `elixir_make` hex package. Source in `apps/commonplace/c_src/flock_nif.c`, compiled via Makefile. Add `elixir_make` as explicit dep in `apps/commonplace/mix.exs` and add `:elixir_make` to compilers list.

### Elixir Wrapper (`Commonplace.Sync.Flock`)

High-level API:

```elixir
# Acquire exclusive lock, run function, release. Returns function result.
# On timeout: logs warning, runs function WITHOUT lock, returns result.
Flock.with_exclusive_lock(path, timeout \\ 30_000, fun)

# Acquire shared lock, run function, release. Returns function result.
Flock.with_shared_lock(path, timeout \\ 30_000, fun)

# Low-level: returns {:ok, ref} or {:error, :would_block | :enoent | :eacces}
Flock.try_lock(path, :exclusive | :shared)

# Release a lock acquired via try_lock
Flock.unlock(ref)
```

**Return contract**: `with_exclusive_lock/3` and `with_shared_lock/3` always return the result of `fun`. On timeout, `fun` still executes (without the lock) after logging a warning. On `:enoent` (file doesn't exist), `fun` still executes without a lock (the file may be about to be created by atomic_write).

**Retry loop**: Reopen the file on each retry iteration (close old fd, open again) to catch inode changes from renames. This matches the Rust behavior. On EINTR, retry immediately without sleeping. On `:would_block`, sleep 100ms then retry.

Lock release guaranteed via `try/after` (Elixir equivalent of Rust RAII FlockGuard).

### Known Limitation: flock + atomic rename window

Atomic writes work via temp file + rename. After rename, the lock holder's fd points to the old (now-unlinked) inode. Any process opening the path after rename gets the new inode with an independent lock namespace. This creates a brief window where the lock is ineffective.

This is the same limitation the Rust implementation has. It is acceptable because:
1. The lock's purpose is to serialize access during the write — the rename itself is atomic.
2. The retry loop reopens on each attempt, catching inode changes.
3. CRDT conflict resolution handles any races that slip through.
4. The inode shadow tracking system catches stale-fd writes.

## Data Flow

### Write path (SyncAgent/EntryAgent inbound / CRDT → disk)

```
Agent detects new commit for file
  → Flock.with_exclusive_lock(file_path, 30_000, fn ->
      Export.atomic_write(file_path, content)
    end)
  → Lock released automatically (fd closed in after block)
```

### Read path (SyncAgent/EntryAgent outbound / disk → CRDT)

```
Agent detects disk change
  → Flock.with_shared_lock(file_path, 30_000, fn ->
      File.read!(file_path)
    end)
  → Content hashed, compared, committed to store
```

### Sandbox process coordination

```
SandboxExecRunner spawns "sh -c ..."
  → Sandbox process can: flock --shared /path/to/file cat /path/to/file
  → Advisory locks are cooperative — this is documentation guidance for
    sandbox command authors, not system-enforced
```

### Timeout behavior

```
try_lock returns :would_block
  → close fd, sleep 100ms
  → reopen file, retry flock
  → on EINTR: retry immediately (no sleep)
  → after 30s: Logger.warning("flock timeout on #{path}"), run fun without lock
  → sync loop continues, never deadlocks
```

## Error Handling

- **File doesn't exist**: `nif_open` returns `{:error, :enoent}`. Wrapper runs fun without lock (file may be about to be created).
- **Permission denied**: `nif_open` returns `{:error, :eacces}`. Wrapper logs warning, runs fun without lock.
- **EINTR**: `nif_flock` returns `{:error, :eintr}`. Retry immediately without sleeping.
- **NIF crash**: flock(2) is a trivial syscall, extremely unlikely. NIF surface kept minimal to reduce risk.
- **Process dies holding lock**: NIF resource destructor closes fd, releasing the lock. No leaked locks.
- **Stale locks**: Not possible with flock(2) — lock is tied to fd lifetime, unlike lockfiles.

## Integration Points

1. **Export.atomic_write/2** — wrap with `Flock.with_exclusive_lock/3`
2. **SyncAgent outbound reads** — wrap file reads with `Flock.with_shared_lock/3`
3. **EntryAgent** — same as SyncAgent; wraps reads and writes with appropriate locks
4. **SandboxExecRunner** — sandbox processes coordinate via system `flock` command (cooperative, not enforced)

## Cleanup

- **Remove** `Commonplace.Sync.FileLock` module (`lib/commonplace/sync/file_lock.ex`)
- **Remove** `Commonplace.Sync.FileLockTest` (`test/commonplace/sync/file_lock_test.exs`)
- **Remove** vestigial `:lock` field from `Agent` struct and related opts (currently set but never used)
- **Note**: `FileLock.wait_stable/2` (polls file metadata for partial write detection) is not needed — flock + atomic writes make it redundant.

## Testing Strategy

- **NIF unit tests**: open/lock/unlock/close cycle, shared locks concurrent, exclusive blocks shared
- **EINTR test**: verify immediate retry on EINTR (may need to simulate)
- **Integration test**: two BEAM processes racing on the same file, verify serialization
- **Timeout test**: hold lock in one process, verify other process times out and proceeds with warning
- **Atomic write + flock test**: one process holds flock, another does atomic_write (rename) over locked file — verify the retry-with-reopen catches the inode change
- **Resource cleanup test**: acquire lock, kill process, verify lock is released (fd closed by destructor)
- **Negative tests**: permission denied, lock on nonexistent path returns :enoent

## Reference

- Rust flock implementation: `commonplace-rs/crates/commonplace-watcher/src/flock.rs`
- Rust atomic writes: `commonplace-rs/src/sync/transport/shadow.rs`
- Existing Elixir atomic write: `apps/commonplace/lib/commonplace/sync/export.ex` (`atomic_write/2`)
- Existing Elixir FileLock (being replaced): `apps/commonplace/lib/commonplace/sync/file_lock.ex`
