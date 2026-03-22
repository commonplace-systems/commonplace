# Session Learnings — 2026-03-22

## What We Built

### Presence System (Phases 3-4)
- **Cold identity** (`__identities__/`): permanent actor records that survive restarts. Register on start, update `last_seen` on shutdown.
- **CLI `who` command**: lists hot presence + cold identities with `--all` flag.
- **Browser presence**: LiveView spawns `browser-XXXX.usr` on connect, heartbeats every 15s.

### Live Sync
- **SyncLoop GenServer**: wraps the Sync.Agent with a timer for periodic bidirectional sync.
- **Key bug found and fixed**: outbound sync was overwriting remote CRDT updates with stale disk content. Fix: track content hashes to distinguish "I changed this file" from "the CRDT was updated remotely."
- **Peer-to-peer integration tests**: proved files created/modified on one peer propagate to another through the shared CRDT store.

### Commit-Ancestry Version Tracking
- **Content hashes alone aren't enough** — you need causal ordering via the commit DAG.
- **`CommitStore.is_ancestor?/3`**: walks parent pointers to check if one commit is an ancestor of another.
- **Dual-layer approach**: content hashes gate outbound (fast "did disk change?"), commit IDs gate inbound (causal ordering).
- **BEAM simplification**: no "pending outbound" problem because peers share the CommitStore directly — commits land instantly, no upload/ack gap.

### Inode↔Commit_ID Mapping
- **InodeTracker.Registry**: GenServer mapping `{device, inode}` → `{commit_id, doc_uuid, path}`.
- **`atomic_write_with_shadow`**: before atomic rename, creates hardlink to old inode in `.commonplace-shadow/`.
- **Shadow checking**: each sync cycle polls shadows for stale writes (fingerprint changed), reads content, creates merge commit with old commit_id as parent.
- **Key insight**: inode tracking connects the physical filesystem to the logical commit DAG. It's what makes atomic writes safe.

### Process Orchestrator
- **`__processes.json`**: declares processes with mode (elixir/sandbox-exec), source, command, args, env, restart, owns.
- **Elixir mode**: compiles `.exs` from CRDT tree, starts as GenServer with context (store, config, name).
- **Hot code reload (CX-hgv)**: `Code.purge_module` + `Code.compile_string` swaps callbacks without killing the process. State preserved across reload.
- **Sandbox-exec mode**: creates temp dir, starts SyncLoop, spawns via `Port.open`, captures stdout/stderr.

### Cell Macro — Spreadsheet-Style Reactive Processes
- ~30 lines of Elixir macro that subscribes to input docs, recomputes on changes, writes to output.
- Light syntax: `use Commonplace.Process.Cell, inputs: [...], output: "..."` with a `compute/1` callback.
- Polls input commit IDs every 200ms for change detection.

### Stdout/Stderr Capture (CX-bqz)
- Switched from `System.cmd` (blocking) to `Port.open` with `{:line, 8192}` (streaming).
- Stderr separated via bash fd3 redirect wrapper: `{ cmd 2>&1 1>&3 | while read line; do echo PREFIX$line; done; } 3>&1`.
- Each line → JSON event `{type: "stdout"/"stderr", line: "...", timestamp: "..."}` in RedLog.

### Phoenix LiveView + Yjs Bridge
- **TreeLive**: browse document tree, click to view. Sidebar + content pane.
- **Yjs handoff**: LiveView owns the page chrome, JS hook owns the content div.
- **push_event("yjs_init")**: sends raw Yjs binary state as base64 to browser.
- **Browser-side y-js**: creates Y.Doc, applies update, renders content.
- **CodeMirror 6**: bound to Y.Text via y-codemirror.next for collaborative editing.
- **Round-trip**: CodeMirror edit → Yjs update → pushEvent("yjs_edit") → server commits → blue PubSub → other viewers update.

### Sync Sandbox
- **Sandbox GenServer**: creates temp dir, starts scoped SyncLoop.
- **Unix processes see real files**, edit with normal tools, writes flow back to CRDT.
- **End-to-end proven**: `echo 'Sandbox saw:' $(cat input.txt) > output.txt` — input from CRDT, output flows back.
- **Env var support**: `__processes.json` entries can specify `env` field.

### CRDT-Native Hardlinks (`commonplace ln`)
- Same UUID in two schema entries = same document.
- Writes from either path merge via CRDT.
- Works across sandbox boundaries for data sharing.
- No "original" vs "link" — all references equal (like unix hardlinks).

### `commonplace serve`
- Persistent workspace daemon: starts orchestrator, imports `__processes.json`, manages process lifecycle until Ctrl+C.

## Architecture Insights

### BEAM Advantages Over Rust
- Process isolation is free (each GenServer is isolated).
- Hot code reload is native (Code.purge_module + Code.compile_string).
- PubSub replaces MQTT for same-language peers.
- No "pending outbound" problem — commits land instantly in shared CommitStore.
- Supervision tree IS the orchestrator.

### Sync Algorithm (from IRC with commonplace-rs)
The "smartest possible algorithm" for sync:
1. **Outbound (disk → CRDT)**: content hash check (fast), then create commit.
2. **Inbound (CRDT → disk)**: check if latest commit is descendant of `last_written_commit_id`.
   - Same commit → skip (nothing changed).
   - Descendant → safe to write (includes my changes).
   - Not descendant → concurrent edit, still safe (CRDT merge).
3. **Content hashes for fast gating, commit ancestry for causal ordering.**

### Sandbox Architecture
- Each sandbox-exec process gets its own temp dir + SyncLoop.
- Scoped at `__processes.json` location (determines what subtree the process sees).
- The CRDT is the single source of truth — sandboxes are filesystem projections.
- Processes don't know they're in a sandbox — they just see files.

### LiveView + Yjs Boundary
- LiveView owns: sidebar, navigation, status bars (server-rendered, diffed).
- JS hook owns: content div (`phx-update="ignore"`).
- Bridge: `push_event` carries Yjs binary updates over the existing WebSocket.
- No separate WebSocket needed.

## What's Missing / Next Steps

### Immediate (from testing)
- **Process linkage**: text-to-telegram's `content.txt` needs to be linked to bartleby's `prompts.txt` via `commonplace ln`. Currently each sandbox is isolated.
- **Persistent daemon**: `commonplace serve` needs proper daemonization (systemd or similar). Currently orphans processes when BEAM exits.
- **Shutdown ordering**: CommitStore dies before runners can commit event logs during cleanup.

### CX Beads Filed (38 total, 5 closed)
- **P1 completed**: hot reload, stdout capture, bartleby/text-to-telegram/file-tmux-file integration
- **P2 ready**: CLI commands (ps, uuid, replay, event, log), Green channel, GC, rename detection, BEAM distribution
- **P3 blocked**: HTTP API → SSE → MQTT chain, channels, time travel, merge, scheduling

### Designed But Never Built (in either version)
- GC via reachability walk (Walk.reachable_uuids exists — just needs cleanup pass)
- Gold channel (notarized append-only ledger)
- White channel (entitlements / merge gates)
- Black channel (condition engine)
- Snapshots / time-travel checkout
- Merge across branches, cherry-pick
