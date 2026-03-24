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
  use Commonplace.UserProcess

  @blue_inputs ["config", "/shared/settings"]
  @cyan_outputs ["output"]
  @red_inputs ["!ops/main/events/system-log"]
  @magenta_outputs ["!ops/main/commands/alerts"]

  def handle_blue("config", doc_state) do
    # sibling "config" changed — react
  end

  def handle_blue("/shared/settings", doc_state) do
    # branch-level shared settings changed
  end

  def handle_red("!ops/main/events/system-log", event) do
    # cross-repo event received
  end
end
```

### Port types

- `@blue_inputs` — subscribe to these docs' commit streams. Triggers `handle_blue/2`.
- `@cyan_outputs` — push edits to these docs. Provides `push_cyan/2` runtime helper. Implicitly subscribes to their blue channels.
- `@red_inputs` — subscribe to these docs' event logs. Triggers `handle_red/2`.
- `@magenta_outputs` — docs this process intends to push events to. Provides `push_magenta/2`. Optional — events can be sent without declaration.

## 3. Document Reference Resolution

Port declarations use document references (docrefs) with four resolution modes:

| Syntax | Example | Resolution |
|--------|---------|------------|
| Bare name | `"config"` | Sibling in same schema directory |
| Relative path | `"../shared/config"` | Relative from current directory |
| Repo-absolute | `"/shared/config"` | From repo root (top two tree levels: repo/branch) |
| Tree-absolute | `"!other-repo/main/config"` | From absolute tree root |

The `!` sigil escapes above the repo/branch level to the tree root. No `@commit` pinning — ports connect to live documents only.

Resolution happens at process spawn time. The Orchestrator resolves each docref to a UUID using the process's location in the tree as context. Resolved UUIDs are stored — the wiring doesn't follow renames.

## 4. Orchestrator Wiring

When the Orchestrator spawns a smart document process:

1. **Load module** — compile the `.exs` source
2. **Read ports** — call `Module.__ports__()` to get compiled declarations
3. **Resolve refs** — for each port, resolve docref to UUID using process location as context
4. **Subscribe** — for `@blue_inputs`: subscribe to `commits:{uuid}`. For `@cyan_outputs`: also subscribe to target's blue channel. For `@red_inputs`: subscribe to `red:{uuid}`.
5. **Register edges** — record all edges in GraphRegistry
6. **Dispatch** — route incoming PubSub messages to `handle_blue/2` or `handle_red/2` callbacks

### On hot-reload

If port declarations change after hot-reload, the Orchestrator restarts the process (initial implementation). Port diffing with incremental re-wiring is a follow-up.

### On shutdown

Orchestrator unsubscribes all PubSub topics and removes edges from GraphRegistry.

## 5. GraphRegistry

A GenServer that maintains the directed edge graph for introspection:

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
| `find_cycles()` | Return list of cycles in the graph |
| `dependents(uuid)` | What processes read this doc? |
| `dependencies(process_name)` | What docs does this process read? |

### Cycle handling

- **No enforcement** — the registry records edges and reports cycles but does not prevent wiring
- **Cyan cycle warning** — when `add_edges/2` detects a cycle in cyan edges, logs a warning (cyan cycles are the most likely to cause runaway edits)
- **Introspection** — `find_cycles/0` returns all cycles for debugging and visualization

## 6. Runtime Loop Protection

Each PubSub commit message carries a propagation depth counter:

```elixir
{:commit, uuid, commit_id, %{depth: 0}}
```

### Flow

1. CommitStore broadcasts with `depth: 0`
2. Process receives blue message, reacts, pushes cyan edit
3. The resulting commit broadcasts with `depth: depth + 1`
4. Next process checks depth: if `depth > @max_propagation_depth` (default 10), drop and log

```elixir
def handle_blue(ref, doc_state, %{depth: depth}) when depth > @max_propagation_depth do
  Logger.warning("Edit propagation depth #{depth} exceeded for #{ref}, dropping")
  :drop
end
```

This is per-propagation-chain — a process can handle many independent chains concurrently. Depth travels in the message metadata, not in process state.

## 7. `use Commonplace.UserProcess` Macro

The `__using__` macro provides:

### Compile-time

- Reads `@blue_inputs`, `@cyan_outputs`, `@red_inputs`, `@magenta_outputs` from the module
- Defines `__ports__/0` returning the compiled port declarations
- Provides overridable `handle_blue/2` and `handle_red/2` callbacks (default: no-op)

### Runtime helpers

- `push_cyan(docref, update)` — push a CRDT edit to a declared cyan output
- `push_magenta(docref, event)` — push an event to any doc (declared or not)

### Example compiled output

```elixir
def __ports__ do
  %{
    blue_inputs: ["config", "/shared/settings"],
    cyan_outputs: ["output"],
    red_inputs: ["!ops/main/events/system-log"],
    magenta_outputs: ["!ops/main/commands/alerts"]
  }
end
```

## 8. Testing Strategy

- **GraphRegistry unit tests**: add/remove edges, find_cycles, dependents/dependencies, cyan cycle warning
- **UserProcess macro tests**: port declaration parsing, `__ports__/0` output, ref resolution (sibling, relative, `/`, `!`)
- **Depth tracking tests**: propagation counter increment, drop at max depth, logging
- **Integration test**: two smart docs with port declarations, spawn via Orchestrator, edit one, verify the other reacts, verify GraphRegistry shows edges
- **Cycle integration test**: wire A->B->A via cyan, verify warning logged, verify runtime depth protection prevents infinite loop

## 9. Not In Scope

- **Green channel** (exclusive locks) — separate feature (CX-6gv)
- **Multi-repo resolution** — `!` syntax supports it syntactically but resolution stops at current tree root
- **Visual graph rendering** — GraphRegistry provides data, UI is separate
- **Hot-reload port diffing** — initial implementation restarts process on port change
- **Process-to-process direct messaging** — all communication goes through documents
