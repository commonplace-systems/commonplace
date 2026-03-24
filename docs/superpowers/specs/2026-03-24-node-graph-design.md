# Node Graph: Reactive Dataflow with Color Channel Ports

**Date**: 2026-03-24
**Status**: Draft
**Issue**: CX-x1f

## Problem

Smart documents (Elixir source files managed by the Orchestrator) need a formalized way to declare their dataflow connections — which documents they read from and write to. Currently, processes manually subscribe to PubSub topics with no visibility into the overall graph. There's no way to introspect "what reads from this doc?" or detect problematic wiring.

## Design Overview

Every smart document declares its dataflow ports via module attributes. The Orchestrator reads these declarations, resolves document references, wires PubSub subscriptions, and registers edges in a GraphRegistry for introspection. Runtime loop protection prevents infinite propagation chains.

## 1. Color Channel Semantics

Each color channel represents a direction of flow relative to a document:

| Channel | Direction | Purpose | Persistence |
|---------|-----------|---------|-------------|
| **Blue** | Downstream (read) | Subscribe to a doc's commit stream | Yes (CRDT state) |
| **Cyan** | Upstream (write) | Push edits into a doc | Yes (requires blue subscription for state) |
| **Red** | Downstream (read) | Subscribe to a doc's event log | Yes (YArray log doc) |
| **Magenta** | Upstream (write) | Push events to a doc's log | No (fire-and-forget) |

**Cyan implies blue**: To push a valid CRDT edit, you need the doc's current state. Declaring `@cyan_outputs` automatically subscribes to the target's blue channel.

**Magenta is optional to declare**: Any process can fire-and-forget events without declaring them. Declaring `@magenta_outputs` is for graph visibility — the runtime doesn't enforce it.

## 2. Port Declarations

Smart documents declare ports via module attributes:

```elixir
defmodule MyWatcher do
  use Commonplace.SmartDoc

  @blue_inputs ["config", "/shared/settings"]
  @cyan_outputs ["output"]
  @red_inputs ["!ops/main/events/system-log"]
  @magenta_outputs ["!ops/main/commands/alerts"]

  def handle_blue("config", doc_state) do
    # sibling "config" changed — react
    # doc_state is the reconstructed Yelixer.Doc
  end

  def handle_blue("/shared/settings", doc_state) do
    # branch-level shared settings changed
  end

  def handle_red("!ops/main/events/system-log", event) do
    # event is a decoded map from the red log
  end
end
```

### Port types

- `@blue_inputs` — subscribe to these docs' commit streams. Triggers `handle_blue/2` with `(docref, %Yelixer.Doc{})`.
- `@cyan_outputs` — docs this process pushes edits to. Provides `push_cyan/2` runtime helper. Implicitly subscribes to their blue channels.
- `@red_inputs` — subscribe to these docs' event logs. Triggers `handle_red/2` with `(docref, event_map)`.
- `@magenta_outputs` — docs this process intends to push events to. Provides `push_magenta/2`. Optional — events can be sent without declaration.

### Callback arguments

- `handle_blue(docref, doc)` — `doc` is a fully reconstructed `Yelixer.Doc` (the Orchestrator applies the commit update before dispatching). The docref is the original declaration string, not the resolved UUID.
- `handle_red(docref, event)` — `event` is the decoded JSON map from the red log entry.
- Callbacks are arity-2. Depth checking is handled transparently by the Orchestrator before dispatch — the user never sees depth metadata.

## 3. Document Reference Resolution

Port declarations use document references (docrefs) with four resolution modes:

| Syntax | Example | Resolution |
|--------|---------|------------|
| Bare name | `"config"` | Sibling in same schema directory |
| Relative path | `"../shared/config"` | Relative from current directory |
| Repo-absolute | `"/shared/config"` | From repo root (top two tree levels: repo/branch) |
| Tree-absolute | `"!other-repo/main/config"` | From absolute tree root |

The `!` sigil escapes above the repo/branch level to the tree root. No `@commit` pinning — ports connect to live documents only. Multi-repo is not a separate concept — `!` resolves from the tree root, which naturally crosses "repo" boundaries since repos are just top-level directories.

### Resolution context

The Orchestrator must provide resolution context when spawning a process:

- **Current directory UUID** — the schema UUID of the directory containing the smart doc (for bare name and relative path resolution)
- **Repo root UUID** — the UUID two levels up from the process (repo/branch level, for `/` resolution)
- **Tree root UUID** — the absolute root of the document tree (for `!` resolution)

The Orchestrator already knows the process's location in the tree (it walks the schema to find processes). It passes these three context UUIDs to the resolution step. `Docref.resolve/2` is extended to accept resolution context.

### Relative path handling

`..` traversal requires knowing parent UUIDs. The Orchestrator builds a parent-pointer map as it walks the tree during process discovery. This map is used during resolution — `"../shared/config"` walks up one level (parent UUID) then down into "shared/config".

### Unresolvable docrefs

If a docref fails to resolve (target doc doesn't exist yet), the process still starts but that port is marked as `pending`. A background task periodically retries resolution for pending ports. When the target appears, the port is wired. This supports the case where a process is created before its input docs.

## 4. Orchestrator Wiring

When the Orchestrator spawns a smart document process:

1. **Load module** — compile the `.exs` source
2. **Read ports** — call `Module.__ports__()` to get compiled declarations
3. **Resolve refs** — for each port, resolve docref to UUID using process location context
4. **Subscribe** — for blue inputs and cyan outputs: subscribe to `commits:{uuid}` (the existing CommitStore broadcast topic). For red inputs: subscribe to `commits:{red_log_uuid}` (red logs are CRDT docs, so their changes also broadcast on commits).
5. **Register edges** — record all edges in GraphRegistry
6. **Build ref→uuid map** — store resolved `%{docref_string => uuid}` in process state for runtime helpers
7. **Dispatch** — on receiving `{:commit, uuid, commit_id}`, reconstruct the doc, then call the appropriate `handle_blue/2` callback. Depth checking happens here before dispatch.

### PubSub topic unification

All subscriptions use the `commits:{uuid}` topic — the existing CommitStore broadcast. The `Dataflow.PubSub` wrapper module (`blue:`, `red:`, etc.) is not used for node-graph wiring. This avoids introducing a bridge between topic schemes. The `PubSub` wrapper remains available for other uses.

Red log subscriptions also use `commits:{uuid}` since red logs are themselves CRDT documents. When the red log doc gets a new commit, the Orchestrator detects it's a red input, reads the latest log entry, and dispatches to `handle_red/2`.

### On hot-reload

If port declarations change after hot-reload, the Orchestrator restarts the process (initial implementation). Port diffing with incremental re-wiring is a follow-up.

### On shutdown

Orchestrator unsubscribes all PubSub topics and removes edges from GraphRegistry.

## 5. GraphRegistry

A named GenServer (`Commonplace.Dataflow.GraphRegistry`) added to the application supervision tree. Rebuilt from running processes on Orchestrator restart.

### State

```elixir
%{
  edges: [%{from: uuid, to: uuid, color: :blue | :cyan | :red | :magenta, process: name}]
}
```

### API

| Function | Description |
|----------|-------------|
| `add_edges(process_name, edges)` | Record edges when wiring a process |
| `remove_edges(process_name)` | Remove all edges for a process |
| `get_graph()` | Return all edges |
| `find_cycles()` | Return list of cycles (DFS-based) |
| `dependents(uuid)` | What processes read this doc? |
| `dependencies(process_name)` | What docs does this process read? |

### Cycle handling

- **No enforcement** — the registry records edges and reports cycles but does not prevent wiring
- **Cyan cycle warning** — when `add_edges/2` detects a cycle in cyan edges, logs a warning (cyan cycles are the most likely to cause runaway edits)
- **Introspection** — `find_cycles/0` returns all cycles for debugging and visualization

### Durability

GraphRegistry state is in-memory only. On Orchestrator restart, the Orchestrator re-reads all running processes' `__ports__/0` and re-registers edges. No persistence needed.

## 6. Runtime Loop Protection

Propagation depth is tracked per commit via metadata in CommitStore.

### Mechanism

`CommitStore.create_commit` and `create_chained_commit` accept an optional `metadata` map. The Orchestrator's `push_cyan` helper passes `%{depth: current_depth + 1}` as metadata. CommitStore includes metadata in the PubSub broadcast:

```elixir
# CommitStore broadcast (extended)
{:commit, uuid, commit_id, metadata}
# where metadata defaults to %{depth: 0} for direct commits
```

### Backward compatibility

Existing subscribers pattern-matching on `{:commit, uuid, commit_id}` (3-tuple) will not match the new 4-tuple. Migration: update all existing subscribers to match the 4-tuple, or broadcast both formats during transition. The simpler approach: update all subscribers (there are few — sync agents and tests).

### Depth checking

The Orchestrator checks depth before dispatching to `handle_blue/2`:

```elixir
# In the Orchestrator's PubSub message handler:
def handle_info({:commit, uuid, commit_id, meta}, state) do
  depth = Map.get(meta, :depth, 0)
  if depth > @max_propagation_depth do
    Logger.warning("Depth #{depth} exceeded for #{uuid}, dropping")
  else
    # reconstruct doc, dispatch to handle_blue/2
  end
end
```

Users never see depth — it's transparent.

### Ordering guarantees

Each smart doc process is a GenServer. PubSub messages arrive in mailbox order. `handle_blue/2` calls are serial within a process — no concurrent callbacks. This is the natural Elixir/OTP guarantee.

## 7. `use Commonplace.SmartDoc` Macro

The macro module is `Commonplace.SmartDoc` (not `Commonplace.UserProcess`, to avoid collision with the existing `Commonplace.UserProcess` namespace used for compiled module names).

### Compile-time

- Reads `@blue_inputs`, `@cyan_outputs`, `@red_inputs`, `@magenta_outputs` from the module
- Defines `__ports__/0` returning the compiled port declarations
- Provides overridable `handle_blue/2` and `handle_red/2` callbacks (default: no-op)

### Runtime helpers

- `push_cyan(docref, content)` — push a CRDT edit to a declared cyan output. Looks up the pre-resolved UUID from the ref→uuid map in process state. Calls `CommitStore.create_chained_commit` with `%{depth: current_depth + 1}` metadata.
- `push_magenta(docref, event)` — push an event to any doc (declared or not). Resolves on the fly if not pre-resolved.

### Relationship to existing Cell module

The existing `Commonplace.Process.Cell` implements a polling-based version of blue-input/cyan-output. `SmartDoc` supersedes `Cell` with PubSub-driven reactive wiring. `Cell` can be refactored to use `SmartDoc` internally as a follow-up.

## 8. Testing Strategy

- **GraphRegistry unit tests**: add/remove edges, find_cycles (DFS), dependents/dependencies, cyan cycle warning
- **SmartDoc macro tests**: port declaration parsing, `__ports__/0` output, default callbacks
- **Docref resolution tests**: bare name, relative, `/`, `!`, `..` traversal, unresolvable ref (pending)
- **Depth tracking tests**: metadata propagation through CommitStore, drop at max depth, logging
- **Integration test**: two smart docs with port declarations, spawn via Orchestrator, edit one, verify the other reacts, verify GraphRegistry shows edges
- **Cycle integration test**: wire A→B→A via cyan, verify warning logged, verify runtime depth protection prevents infinite loop

## 9. Not In Scope

- **Green channel** (exclusive locks) — separate feature (CX-6gv)
- **Visual graph rendering** — GraphRegistry provides data, UI is separate
- **Hot-reload port diffing** — initial implementation restarts process on port change
- **Process-to-process direct messaging** — all communication goes through documents
- **`Cell` refactoring** — existing Cell module continues to work; refactoring to use SmartDoc is a follow-up
