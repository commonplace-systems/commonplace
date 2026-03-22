# Presence Files — Design Document

Date: 2026-03-22

## Overview

Presence files are how actors advertise "I'm here and alive" in the
document tree. They're regular CRDT documents that appear in the
directory the actor is operating in. Other actors discover them via
glob queries (e.g., `*.exe` for all processes).

Each presence file is a "business card" — identity, status, and
pointers to the actor's IO channels (event log, command topic).

## Honorific Extensions

The filename extension indicates actor type:

| Extension | Type    | Example          |
|-----------|---------|------------------|
| `.exe`    | Process | `sync.exe`       |
| `.usr`    | Human   | `jes.usr`        |
| `.bot`    | AI agent| `bartleby.bot`   |
| `.who`    | Unknown | `anonymous.who`  |

Discovery: `*.exe` finds all processes, `*.*` finds everyone.

Collision handling: if two actors would have the same name, a hash
suffix is appended: `sync-a3f.exe`.

## Presence Document Structure

A presence file is a single YMap document (using the document envelope):

```
root YMap {
  _type: "map"
  _name: "sync.exe"
  content YMap {
    "name": "sync"
    "type": "exe"                    # honorific type
    "status": "running"              # current state
    "pid": "12345"                   # OS/BEAM pid
    "started_at": "2026-03-22T..."   # ISO 8601
    "heartbeat": "2026-03-22T..."    # last heartbeat timestamp
    "event_log_uuid": "uuid-..."     # pointer to red event log doc
    "identity": "path:uuid@cid"      # DocRef for stable identity
  }
}
```

## Hot / Cold Split

### Hot Presence (working directory)

- Lives in the actor's working directory (the branch it's operating in)
- Created on startup, updated with heartbeats
- Heartbeat-gated: orchestrator reaps after timeout (e.g., 30s no heartbeat)
- Deleted on clean shutdown

### Cold Identity (`__identities/` system dir)

- Permanent record at repo level: `__identities/sync.exe.json`
- Survives across restarts
- Contains stable identity, capabilities, configuration
- `__`-prefixed directories are system dirs (not user content)

## Lifecycle

```
Actor starts
  → Create/update hot presence file in working dir
  → Register cold identity in __identities/ (if first time)
  → Begin heartbeat loop (periodic red events)

Running
  → Other actors discover via glob queries
  → Status updates written to presence doc (blue channel)
  → Commands received via PubSub magenta topic
  → Events logged to red event log doc

Actor stops (clean)
  → Delete hot presence file
  → Cold identity persists

Actor crashes
  → Heartbeat stops
  → Orchestrator reaper detects stale presence (timeout)
  → Reaper deletes hot presence file
  → Cold identity persists for restart
```

## BEAM Implementation

### Presence GenServer

```elixir
defmodule Commonplace.Presence do
  use GenServer

  # State: name, type, uuid, event_log_uuid, heartbeat_interval

  def start_link(opts)  # name: "sync", type: :exe, dir_uuid: ...
  def status(pid)       # read current status
  def update(pid, map)  # update status fields
  def stop(pid)         # clean shutdown + delete presence doc
end
```

Each actor's presence is a GenServer that:
- Creates/owns its presence document (YMap in CommitStore)
- Adds itself to the parent schema (so it appears in `ls`)
- Runs a heartbeat loop via `Process.send_after`
- Traps exit for cleanup on shutdown

### Heartbeat

```elixir
def handle_info(:heartbeat, state) do
  # Update heartbeat timestamp in presence doc
  # Commit to store
  # Schedule next heartbeat
  Process.send_after(self(), :heartbeat, state.interval)
  {:noreply, state}
end
```

### Reaper

The orchestrator (or a dedicated reaper GenServer) periodically scans
for stale presence files:

```elixir
def handle_info(:reap, state) do
  # List all *.exe, *.bot, *.usr, *.who entries in the schema
  # For each: check heartbeat timestamp
  # If older than threshold: delete presence doc + schema entry
  Process.send_after(self(), :reap, @reap_interval)
  {:noreply, state}
end
```

On BEAM, we can also use `Process.monitor` for linked processes —
when the monitored process dies, immediately clean up its presence.
This is simpler and faster than timeout-based reaping.

### Discovery

```elixir
# Find all processes in current directory
Presence.discover(schema_doc, :exe)

# Find all actors
Presence.discover(schema_doc, :all)

# Find a specific actor
Presence.find(schema_doc, "bartleby.bot")
```

Uses `Schema.list_entries` filtered by extension.

## CLI Commands

```
commonplace who                # List all actors in current dir
commonplace who --type exe     # List only processes
commonplace who --all          # List across all directories
```

## Implementation Phases

### Phase 1: Presence Document

- `Commonplace.Presence` module: create, read, update presence docs
- Honorific extension parsing
- Collision detection with hash suffix
- Schema integration (add/remove from parent dir)
- Tests

### Phase 2: Heartbeat & Lifecycle

- GenServer with heartbeat loop
- Clean shutdown with presence cleanup
- `Process.monitor`-based reaping for BEAM processes

### Phase 3: Discovery & CLI

- `Presence.discover` for glob-based actor discovery
- `commonplace who` CLI command
- Filter by type, directory

### Phase 4: Cold Identity

- `__identities/` system directory
- Persistent identity across restarts
- Identity reconciliation on startup

## Dependencies

- Existing: Schema, CommitStore, ContentType, Magenta, RedLog
- New: none (uses existing BEAM primitives)
