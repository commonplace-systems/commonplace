# Robust Orphan Cleanup for Managed Processes

**Date:** 2026-03-23
**Issue:** CX-btk
**Status:** Design

## Problem

Managed processes (bartleby, text-to-telegram, etc.) become orphaned when the orchestrator dies uncleanly. The current `kill_orphans` only kills the previous orchestrator's process group, but child processes spawned via `Port.open` are in their own process groups. When the orchestrator's BEAM exits, these children get reparented to init (PID 1) and persist indefinitely, blocking new instances from starting.

## Constraints

- One daemon per workspace (no multi-daemon coordination needed)
- Kill-and-restart on orchestrator crash (no re-adoption)
- Graceful shutdown: SIGTERM + 5s timeout + SIGKILL
- Must work on Linux (macOS nice-to-have)

## Key Insight

`Port.open({:spawn_executable, "/bin/bash"}, ...)` already creates processes where PID == PGID == SID (the child is a session leader). All descendants (bash -> uv -> python -> ...) inherit this PGID. No `setsid` wrapper is needed — the existing `os_pid` from `Port.info(port, :os_pid)` is already the PGID for the entire process tree.

The orchestrator's `terminate/2` already kills by pgid (`kill -TERM -- -#{os_pid}`). The gap is:
1. `kill_orphans` on startup doesn't read the status file, so it can't find managed process pgids
2. `terminate/2` doesn't wait/escalate to SIGKILL after SIGTERM

## Approach: Status File Cleanup + SIGTERM/SIGKILL Escalation

### 1. PGID Tracking via Status File

The `orchestrator_status.json` (written every reconcile cycle) already records `os_pid` per managed process. Since Port.open children are session leaders, `os_pid == pgid`:

```json
{
  "pid": "12345",
  "processes": {
    "bartleby": {
      "os_pid": 12400,
      "mode": "sandbox_exec",
      "sandbox_dir": "/tmp/cp_sandbox_753114",
      "started_at": "2026-03-23T00:00:00Z",
      "alive": true
    }
  }
}
```

The status file persists across orchestrator crashes, so pgids are available for cleanup even after an unclean exit.

**Atomic writes:** Use write-then-rename to avoid corruption on crash:
```elixir
tmp = status_file <> ".tmp"
File.write!(tmp, Jason.encode!(status, pretty: true))
File.rename!(tmp, status_file)
```

### 2. Startup Cleanup

When `commonplace serve` starts, `kill_orphans` does:

1. Read `orchestrator.pid` — if process alive, SIGTERM its pgid, wait 5s, SIGKILL
2. Read `orchestrator_status.json` — for each process with a non-null `os_pid`:
   - Verify process identity: check `/proc/<pid>/cmdline` or `started_at` vs `/proc/<pid>/stat` to avoid killing a reused PID
   - If verified: `kill -TERM -- -<os_pid>`, wait 5s, `kill -9 -- -<os_pid>`
3. Remove `orchestrator.pid` and `orchestrator_status.json`
4. Clean up `/tmp/cp_sandbox_*` directories (after kills complete, not during grace period)

Step 2 is the key addition — it catches children that escaped the orchestrator's process group.

### 3. Clean Shutdown (terminate/2 refinement)

Orchestrator `terminate/2` already kills by pgid. Add SIGTERM/SIGKILL escalation:

1. For each managed process: `kill -TERM -- -<os_pid>`, wait up to 5s, `kill -9 -- -<os_pid>`
2. Sandbox `terminate` cleans up temp directory
3. Remove `orchestrator_status.json` and `orchestrator.pid`

### 4. Edge Cases

| Scenario | Behavior |
|----------|----------|
| Status file exists, os_pid is null | Skip (process not yet started) |
| Status file shows alive, process is dead | `kill -0` returns non-zero, skip |
| Orchestrator crashes before first reconcile | No status file yet; `orchestrator.pid` pgid kill is sufficient (no children spawned) |
| Multiple rapid serve restarts | Each startup cleans up previous status file before writing its own |
| Status file exists but orchestrator.pid missing | Still read status file and kill managed process groups |
| PID reuse (stale os_pid now belongs to unrelated process) | Verify process identity via `/proc/<pid>/cmdline` before killing |
| Status file corrupted (crash during write) | Atomic write-then-rename prevents this; if file is unparseable, skip and rely on sandbox dir cleanup |
| os_pid not yet recorded (process started, reconcile hasn't run) | Narrow race window (~2s). Accepted limitation — sandbox dir cleanup catches the temp dir |

## Files Changed

| File | Change |
|------|--------|
| `apps/commonplace/lib/commonplace/process/orchestrator.ex` | Atomic status file writes; SIGTERM/SIGKILL escalation in `terminate/2` |
| `apps/commonplace_cli/lib/commonplace/cli/serve.ex` | Read status file in `kill_orphans`, verify PID identity, kill managed process groups |
