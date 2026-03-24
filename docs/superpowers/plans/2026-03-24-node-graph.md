# Node Graph Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reactive dataflow where smart documents declare typed color-channel ports, the Orchestrator auto-wires PubSub subscriptions, and a GraphRegistry provides introspection

**Architecture:** Smart docs declare `@blue_inputs`, `@cyan_outputs`, `@red_inputs`, `@magenta_outputs` via module attributes. The `use Commonplace.SmartDoc` macro compiles these into `__ports__/0`. The Orchestrator resolves docrefs, subscribes to PubSub, dispatches to `handle_blue/2` and `handle_red/2` callbacks. A GraphRegistry tracks all edges. Depth metadata in commits prevents infinite propagation.

**Tech Stack:** Elixir/OTP (GenServer, Registry, PubSub), existing CommitStore, Yelixer CRDT, Docref resolution

**Spec:** `docs/superpowers/specs/2026-03-24-node-graph-design.md`

---

## File Map

### New Files
| File | Responsibility |
|------|---------------|
| `apps/commonplace/lib/commonplace/smart_doc.ex` | `use Commonplace.SmartDoc` macro — port declarations, `__ports__/0`, callbacks |
| `apps/commonplace/lib/commonplace/dataflow/graph_registry.ex` | Named GenServer tracking edges for introspection |
| `apps/commonplace/lib/commonplace/dataflow/wiring.ex` | Resolve docrefs, subscribe PubSub, dispatch callbacks |
| `apps/commonplace/test/commonplace/smart_doc_test.exs` | Macro and port declaration tests |
| `apps/commonplace/test/commonplace/dataflow/graph_registry_test.exs` | Edge management and cycle detection tests |
| `apps/commonplace/test/commonplace/dataflow/wiring_test.exs` | Docref resolution in context, subscription management |
| `apps/commonplace/test/commonplace/dataflow/node_graph_integration_test.exs` | End-to-end: two smart docs react to each other |

### Modified Files
| File | Change |
|------|--------|
| `apps/commonplace/lib/commonplace/store/commit_store.ex` | Extend commit broadcast to 4-tuple with metadata |
| `apps/commonplace/lib/commonplace/application.ex` | Add GraphRegistry to supervision tree |
| `apps/commonplace/lib/commonplace/process/orchestrator.ex` | Read `__ports__/0`, wire via Wiring module, register in GraphRegistry |
| `apps/commonplace/lib/commonplace/tree/docref.ex` | Add resolution context (current dir, repo root, tree root) |

---

## Task 1: Extend CommitStore Broadcast with Metadata

**Files:**
- Modify: `apps/commonplace/lib/commonplace/store/commit_store.ex`
- Modify: `apps/commonplace/test/commonplace/store/commit_pubsub_test.exs`
- Modify: all files that pattern-match on `{:commit, uuid, commit_id}` (grep and update)

- [ ] **Step 1: Find all existing commit message subscribers**

Run: `grep -rn "{:commit," apps/commonplace/lib/ apps/commonplace/test/ --include="*.ex" --include="*.exs" | grep -v "commit_store.ex"`

- [ ] **Step 2: Update CommitStore to broadcast 4-tuple**

In `commit_store.ex`, change the broadcast line to:
```elixir
Phoenix.PubSub.broadcast(Commonplace.PubSub, "commits:#{doc_uuid}", {:commit, doc_uuid, commit.id, %{}})
```

- [ ] **Step 3: Add `create_commit` variant that accepts metadata**

```elixir
def create_commit(server \\ __MODULE__, doc_uuid, update, parent_id, metadata \\ %{})
```
Pass metadata through to the broadcast.

- [ ] **Step 4: Update all existing subscribers to match 4-tuple**

Update pattern matches from `{:commit, uuid, id}` to `{:commit, uuid, id, _meta}`.

- [ ] **Step 5: Update pubsub tests**

- [ ] **Step 6: Run all tests**

Run: `cd /home/jes/commonplace && mix test apps/commonplace/test/ --no-color`

- [ ] **Step 7: Commit**

```bash
git commit -m "feat(store): extend commit broadcast to 4-tuple with metadata for depth tracking"
```

---

## Task 2: Extend Docref with Resolution Context

**Files:**
- Modify: `apps/commonplace/lib/commonplace/tree/docref.ex`
- Modify: `apps/commonplace/test/commonplace/tree/docref_test.exs`

- [ ] **Step 1: Add tests for `/` (repo-absolute) and `!` (tree-absolute) resolution**

```elixir
test "repo-absolute ref resolves from repo root" do
  assert {:ok, "uuid-shared"} = Docref.resolve("/shared/config",
    root_uuid: root, loader: loader, repo_root_uuid: repo_root)
end

test "tree-absolute ref resolves from tree root" do
  assert {:ok, "uuid-global"} = Docref.resolve("!global/settings",
    root_uuid: root, loader: loader, tree_root_uuid: tree_root)
end

test "relative path with .. traverses parent" do
  assert {:ok, "uuid-sibling"} = Docref.resolve("../sibling/doc",
    root_uuid: current_dir, loader: loader, parent_uuid: parent)
end
```

- [ ] **Step 2: Implement `/` and `!` resolution**

In `docref.ex`, extend `resolve/2` to detect leading `/` and `!`:

```elixir
cond do
  ref == "" -> {:error, :empty_ref}
  uuid?(ref) -> {:ok, ref}
  String.starts_with?(ref, "!") ->
    resolve_from(String.trim_leading(ref, "!"), Keyword.get(opts, :tree_root_uuid), opts)
  String.starts_with?(ref, "/") ->
    resolve_from(String.trim_leading(ref, "/"), Keyword.get(opts, :repo_root_uuid), opts)
  String.starts_with?(ref, "..") ->
    resolve_relative(ref, opts)
  true ->
    resolve_from(ref, Keyword.get(opts, :root_uuid), opts)
end
```

- [ ] **Step 3: Implement `..` relative traversal**

Accept `parent_uuid` in opts. For each `..` segment, walk to the parent. The caller (Orchestrator) provides the parent chain.

- [ ] **Step 4: Run all tests**

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(tree): extend Docref with repo-absolute (/), tree-absolute (!), and relative (..) resolution"
```

---

## Task 3: SmartDoc Macro

**Files:**
- Create: `apps/commonplace/lib/commonplace/smart_doc.ex`
- Create: `apps/commonplace/test/commonplace/smart_doc_test.exs`

- [ ] **Step 1: Write failing test — `__ports__/0` returns port declarations**

```elixir
defmodule TestSmartDoc do
  use Commonplace.SmartDoc
  @blue_inputs ["config"]
  @cyan_outputs ["output"]
  @red_inputs ["events"]
  @magenta_outputs ["alerts"]
end

test "__ports__/0 returns declared ports" do
  ports = TestSmartDoc.__ports__()
  assert ports.blue_inputs == ["config"]
  assert ports.cyan_outputs == ["output"]
  assert ports.red_inputs == ["events"]
  assert ports.magenta_outputs == ["alerts"]
end
```

- [ ] **Step 2: Implement SmartDoc macro**

```elixir
defmodule Commonplace.SmartDoc do
  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :blue_inputs, accumulate: false)
      Module.register_attribute(__MODULE__, :cyan_outputs, accumulate: false)
      Module.register_attribute(__MODULE__, :red_inputs, accumulate: false)
      Module.register_attribute(__MODULE__, :magenta_outputs, accumulate: false)

      @before_compile Commonplace.SmartDoc
    end
  end

  defmacro __before_compile__(env) do
    blue = Module.get_attribute(env.module, :blue_inputs) || []
    cyan = Module.get_attribute(env.module, :cyan_outputs) || []
    red = Module.get_attribute(env.module, :red_inputs) || []
    magenta = Module.get_attribute(env.module, :magenta_outputs) || []

    quote do
      def __ports__ do
        %{
          blue_inputs: unquote(blue),
          cyan_outputs: unquote(cyan),
          red_inputs: unquote(red),
          magenta_outputs: unquote(magenta)
        }
      end

      # Default callbacks — overridable
      def handle_blue(_ref, _doc), do: :ok
      def handle_red(_ref, _event), do: :ok

      defoverridable handle_blue: 2, handle_red: 2
    end
  end
end
```

- [ ] **Step 3: Add test for overridable callbacks**

- [ ] **Step 4: Add test for empty declarations (no attributes set)**

- [ ] **Step 5: Run tests**

- [ ] **Step 6: Commit**

```bash
git commit -m "feat: add SmartDoc macro for port declarations and callbacks"
```

---

## Task 4: GraphRegistry

**Files:**
- Create: `apps/commonplace/lib/commonplace/dataflow/graph_registry.ex`
- Create: `apps/commonplace/test/commonplace/dataflow/graph_registry_test.exs`
- Modify: `apps/commonplace/lib/commonplace/application.ex`

- [ ] **Step 1: Write failing test — add and list edges**

```elixir
test "add_edges and get_graph" do
  GraphRegistry.add_edges("proc_a", [
    %{from: "uuid-config", to: "uuid-output", color: :blue, process: "proc_a"}
  ])
  graph = GraphRegistry.get_graph()
  assert length(graph) == 1
end
```

- [ ] **Step 2: Implement GraphRegistry GenServer**

Named `Commonplace.Dataflow.GraphRegistry`. State: `%{edges: []}`.
API: `add_edges/2`, `remove_edges/1`, `get_graph/0`, `find_cycles/0`, `dependents/1`, `dependencies/1`.

- [ ] **Step 3: Add to application.ex supervision tree**

- [ ] **Step 4: Add test for remove_edges**

- [ ] **Step 5: Add test for find_cycles (DFS)**

Create edges A→B→C→A, verify `find_cycles/0` returns it.

- [ ] **Step 6: Add test for cyan cycle warning**

Add cyan cycle edges, verify Logger warning emitted.

- [ ] **Step 7: Add test for dependents and dependencies**

- [ ] **Step 8: Run all tests**

- [ ] **Step 9: Commit**

```bash
git commit -m "feat(dataflow): add GraphRegistry for edge tracking and cycle detection"
```

---

## Task 5: Wiring Module

**Files:**
- Create: `apps/commonplace/lib/commonplace/dataflow/wiring.ex`
- Create: `apps/commonplace/test/commonplace/dataflow/wiring_test.exs`

- [ ] **Step 1: Write failing test — wire blue inputs**

```elixir
test "wire_ports subscribes to PubSub for blue inputs" do
  ports = %{blue_inputs: ["config"], cyan_outputs: [], red_inputs: [], magenta_outputs: []}
  resolved = %{"config" => "uuid-config"}

  {:ok, subscriptions} = Wiring.wire_ports(ports, resolved, self())

  # Simulate a commit on uuid-config
  Phoenix.PubSub.broadcast(Commonplace.PubSub, "commits:uuid-config", {:commit, "uuid-config", "cid-1", %{}})

  assert_receive {:commit, "uuid-config", "cid-1", %{}}, 1000
end
```

- [ ] **Step 2: Implement Wiring.wire_ports/3**

Subscribes to PubSub topics based on resolved port UUIDs. Returns subscription info for cleanup.

- [ ] **Step 3: Add test — cyan outputs also subscribe to blue**

- [ ] **Step 4: Add Wiring.resolve_ports/3**

Takes port declarations, resolution context, and returns `%{docref => uuid}` map. Uses `Docref.resolve/2`.

- [ ] **Step 5: Add Wiring.unwire/1 for cleanup**

Unsubscribes from all PubSub topics for a set of subscriptions.

- [ ] **Step 6: Add Wiring.dispatch/4**

Routes incoming `{:commit, uuid, commit_id, meta}` to the correct `handle_blue/2` or `handle_red/2` callback based on the resolved mapping. Checks depth before dispatching.

- [ ] **Step 7: Run all tests**

- [ ] **Step 8: Commit**

```bash
git commit -m "feat(dataflow): add Wiring module for PubSub subscription management and dispatch"
```

---

## Task 6: Orchestrator Integration

**Files:**
- Modify: `apps/commonplace/lib/commonplace/process/orchestrator.ex`

- [ ] **Step 1: Detect SmartDoc modules**

After compiling a process source, check if the module has `__ports__/0`:
```elixir
if function_exported?(module, :__ports__, 0) do
  ports = module.__ports__()
  # wire ports...
end
```

- [ ] **Step 2: Build resolution context**

When spawning a process, the Orchestrator knows:
- `scope_uuid` — the directory containing the process
- `root_uuid` — the workspace root
Track parent UUIDs during schema walking for relative path support.

- [ ] **Step 3: Wire ports on process start**

Call `Wiring.resolve_ports/3` and `Wiring.wire_ports/3`. Pass subscription info to the process or store in ProcessInfo.

- [ ] **Step 4: Register edges in GraphRegistry**

After wiring, call `GraphRegistry.add_edges/2` with the resolved edges.

- [ ] **Step 5: Unwire on process stop**

Call `Wiring.unwire/1` and `GraphRegistry.remove_edges/1` when stopping a process.

- [ ] **Step 6: Handle incoming PubSub messages**

Add `handle_info` clause for `{:commit, uuid, commit_id, meta}` that dispatches via `Wiring.dispatch/4` to the correct process's callbacks.

- [ ] **Step 7: Run all tests**

Run: `cd /home/jes/commonplace && mix test apps/commonplace/test/ --no-color`

- [ ] **Step 8: Commit**

```bash
git commit -m "feat(process): integrate SmartDoc port wiring into Orchestrator"
```

---

## Task 7: Runtime Helpers (push_cyan, push_magenta)

**Files:**
- Modify: `apps/commonplace/lib/commonplace/smart_doc.ex`

- [ ] **Step 1: Add push_cyan/2 to SmartDoc macro**

```elixir
def push_cyan(docref, content) do
  # Look up pre-resolved UUID from process state
  uuid = get_resolved_uuid(docref)
  doc = Commonplace.Document.ContentType.new_text_doc(content)
  update = Yelixer.Encoding.encode_update(doc)
  meta = %{depth: get_current_depth() + 1}
  CommitStore.create_chained_commit(CommitStore, uuid, update, meta)
end
```

- [ ] **Step 2: Add push_magenta/2**

```elixir
def push_magenta(docref, event) do
  uuid = resolve_or_lookup(docref)
  Commonplace.Dataflow.Magenta.publish(uuid, event)
end
```

- [ ] **Step 3: Add test for push_cyan creating a commit with depth metadata**

- [ ] **Step 4: Run all tests**

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(smart_doc): add push_cyan and push_magenta runtime helpers"
```

---

## Task 8: Integration Test — Two Smart Docs React to Each Other

**Files:**
- Create: `apps/commonplace/test/commonplace/dataflow/node_graph_integration_test.exs`

- [ ] **Step 1: Write end-to-end test**

1. Create two source docs in the store:
   - `watcher.exs`: `@blue_inputs ["data"]`, `@cyan_outputs ["summary"]`, handle_blue writes a summary
   - `data.txt`: a plain text doc
   - `summary.txt`: the output doc
2. Start Orchestrator
3. Edit `data.txt` (create a commit)
4. Verify `summary.txt` gets updated via the watcher's reactive logic
5. Verify GraphRegistry shows edges: data→watcher (blue), watcher→summary (cyan)

- [ ] **Step 2: Write depth protection test**

Wire A→B→A via cyan. Edit A. Verify depth counter stops propagation before infinite loop. Verify max depth warning logged.

- [ ] **Step 3: Write graph introspection test**

After wiring, call `GraphRegistry.dependents/1` and `GraphRegistry.dependencies/1`, verify correct results.

- [ ] **Step 4: Run all tests**

Run: `cd /home/jes/commonplace && mix test --no-color`

- [ ] **Step 5: Commit**

```bash
git commit -m "test(dataflow): add integration tests for node graph reactive wiring"
```

---

## Task 9: Final Cleanup

- [ ] **Step 1: Run full test suite with warnings-as-errors**

```bash
mix compile --warnings-as-errors && mix test --no-color
```

- [ ] **Step 2: Update CLAUDE.md with new modules**

Add SmartDoc, GraphRegistry, Wiring to the key modules table.

- [ ] **Step 3: Close CX-x1f**

```bash
bd close CX-x1f --reason="Implemented: SmartDoc macro, GraphRegistry, Wiring, Orchestrator integration, depth tracking, push_cyan/push_magenta"
```

- [ ] **Step 4: Push**

```bash
git push
```
