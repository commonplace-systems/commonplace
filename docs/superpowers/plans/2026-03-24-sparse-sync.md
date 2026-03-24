# Sparse Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Multiple filesystem checkouts from a single CommitStore, with per-file sync agents

**Architecture:** CheckoutRegistry manages checkout definitions and spawns supervision trees. Each directory checkout gets a DirAgent (watches schema, manages children) and one EntryAgent per file (bidirectional content sync). A Docref module resolves flexible references (UUID, path, name) to UUIDs.

**Tech Stack:** Elixir/OTP (GenServer, DynamicSupervisor, Registry), CubDB (CommitStore), Phoenix.PubSub, existing Sync.Export/InodeTracker modules

**Spec:** `docs/superpowers/specs/2026-03-24-sparse-sync-design.md`

---

## File Map

### New Files
| File | Responsibility |
|------|---------------|
| `apps/commonplace/lib/commonplace/tree/docref.ex` | Parse and resolve docrefs (UUID, name, path) |
| `apps/commonplace/lib/commonplace/sync/entry_agent.ex` | Per-file bidirectional sync GenServer |
| `apps/commonplace/lib/commonplace/sync/dir_agent.ex` | Per-directory schema watcher, spawns/kills entry agents |
| `apps/commonplace/lib/commonplace/sync/checkout_registry.ex` | Persists checkout definitions, manages checkout lifecycles |
| `apps/commonplace/lib/commonplace/sync/schema_coordinator.ex` | Serializes schema mutations per UUID |
| `apps/commonplace_cli/lib/commonplace/cli/checkouts.ex` | CLI for checkout/reroot/list/remove commands |
| `apps/commonplace/test/commonplace/tree/docref_test.exs` | Docref resolution tests |
| `apps/commonplace/test/commonplace/sync/entry_agent_test.exs` | EntryAgent tests |
| `apps/commonplace/test/commonplace/sync/dir_agent_test.exs` | DirAgent tests |
| `apps/commonplace/test/commonplace/sync/checkout_registry_test.exs` | CheckoutRegistry tests |

### Modified Files
| File | Change |
|------|--------|
| `apps/commonplace/lib/commonplace/application.ex` | Add CheckoutRegistry and SchemaCoordinator to supervision tree |
| `apps/commonplace/lib/commonplace/store/commit_store.ex` | Add PubSub broadcast on commit creation |
| `apps/commonplace_cli/lib/commonplace/cli.ex` | Add `checkout` and `checkouts` command routing |

---

## Task 1: Docref Resolution

**Files:**
- Create: `apps/commonplace/lib/commonplace/tree/docref.ex`
- Create: `apps/commonplace/test/commonplace/tree/docref_test.exs`
- Read: `apps/commonplace/lib/commonplace/tree/schema.ex`
- Read: `apps/commonplace/lib/commonplace/tree/walk.ex`

- [ ] **Step 1: Write failing test — UUID passthrough**

```elixir
defmodule Commonplace.Tree.DocrefTest do
  use ExUnit.Case, async: false

  alias Commonplace.Tree.Docref
  alias Commonplace.Store.CommitStore

  setup do
    Commonplace.TestHelpers.start_store()
  end

  test "resolves raw UUID directly" do
    uuid = UUID.uuid4()
    assert {:ok, ^uuid} = Docref.resolve(CommitStore, uuid)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/commonplace && mix test test/commonplace/tree/docref_test.exs --no-color`
Expected: FAIL — module `Docref` not defined

- [ ] **Step 3: Implement UUID passthrough**

```elixir
defmodule Commonplace.Tree.Docref do
  @moduledoc """
  Parse and resolve document references (docrefs).

  Supported formats:
  - Raw UUID: used directly
  - Name: looked up in root schema
  - Path: walked through nested schemas (e.g., "main/docs/plans")
  """

  alias Commonplace.Tree.{Schema, DocBuilder}
  alias Commonplace.Store.CommitStoreClient

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  def resolve(store, ref) when is_binary(ref) do
    if Regex.match?(@uuid_regex, ref) do
      {:ok, ref}
    else
      resolve_path(store, ref)
    end
  end

  defp resolve_path(store, path) do
    segments = String.split(path, "/")
    root_uuid = root_uuid(store)

    case root_uuid do
      nil -> {:error, :no_root}
      uuid -> walk_segments(store, uuid, segments)
    end
  end

  defp walk_segments(_store, uuid, []), do: {:ok, uuid}

  defp walk_segments(store, schema_uuid, [segment | rest]) do
    case DocBuilder.reconstruct_doc(store, schema_uuid) do
      {:ok, doc} ->
        case Schema.get_entry(doc, segment) do
          {:ok, entry} -> walk_segments(store, entry.node_id, rest)
          :error -> {:error, {:not_found, segment}}
        end

      :none ->
        {:error, {:no_commits, schema_uuid}}
    end
  end

  defp root_uuid(store) do
    CommitStoreClient.get_metadata(store, "root_uuid")
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd apps/commonplace && mix test test/commonplace/tree/docref_test.exs --no-color`
Expected: PASS

- [ ] **Step 5: Add path resolution tests**

Add tests for single-name lookup and multi-segment path resolution. These need a store with schema docs set up.

- [ ] **Step 6: Run all tests**

Run: `cd apps/commonplace && mix test --no-color`
Expected: All pass

- [ ] **Step 7: Commit**

```bash
git add apps/commonplace/lib/commonplace/tree/docref.ex apps/commonplace/test/commonplace/tree/docref_test.exs
git commit -m "feat(tree): add Docref module for flexible document reference resolution"
```

---

## Task 2: EntryAgent — Per-File Sync

**Files:**
- Create: `apps/commonplace/lib/commonplace/sync/entry_agent.ex`
- Create: `apps/commonplace/test/commonplace/sync/entry_agent_test.exs`
- Read: `apps/commonplace/lib/commonplace/sync/agent.ex` (extract per-file logic)
- Read: `apps/commonplace/lib/commonplace/sync/export.ex` (atomic write)
- Read: `apps/commonplace/lib/commonplace/sync/inode_tracker.ex` (shadow hardlinks)

- [ ] **Step 1: Write failing test — inbound sync (CRDT → disk)**

Test that EntryAgent writes a file when a CRDT commit exists and no file is on disk.

```elixir
defmodule Commonplace.Sync.EntryAgentTest do
  use ExUnit.Case, async: false

  alias Commonplace.Sync.EntryAgent
  alias Commonplace.Store.CommitStore

  setup do
    Commonplace.TestHelpers.start_store()
    sync_dir = Commonplace.TestHelpers.tmp_dir("entry_agent")
    %{sync_dir: sync_dir}
  end

  test "inbound: writes file when CRDT has content", %{sync_dir: sync_dir} do
    # Create a doc with content in the store
    doc_uuid = create_text_doc("hello from CRDT")
    file_path = Path.join(sync_dir, "test.txt")

    {:ok, pid} = EntryAgent.start_link(
      doc_uuid: doc_uuid,
      file_path: file_path,
      store: CommitStore
    )

    EntryAgent.sync_once(pid)

    assert File.read!(file_path) == "hello from CRDT"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/commonplace && mix test test/commonplace/sync/entry_agent_test.exs --no-color`
Expected: FAIL — module not defined

- [ ] **Step 3: Implement EntryAgent GenServer**

Extract per-file sync logic from `Sync.Agent`. The EntryAgent GenServer should:
- Hold state: `doc_uuid`, `file_path`, `store`, `last_written_commit_id`, `known_hash`, `shadow_dir`, `standalone`
- `sync_once/1` — run one sync cycle (inbound then outbound)
- `sync_inbound/1` — check latest commit, write to disk if newer
- `sync_outbound/1` — check file hash, create commit if changed
- Reuse `Export.atomic_write/2` for writes
- Reuse `InodeTracker.create_shadow/2` for shadow hardlinks

Key: extract the per-doc write logic from `Agent.maybe_write_doc/7` (lines ~133-154 of agent.ex) and the per-doc read logic from `Watcher.sync_file/5`.

- [ ] **Step 4: Run test to verify it passes**

- [ ] **Step 5: Add outbound sync test (disk → CRDT)**

Test that editing a file on disk creates a new commit in the store.

- [ ] **Step 6: Add idempotence test**

Test that running sync_once twice with no changes is a no-op (no duplicate commits).

- [ ] **Step 7: Add shadow hardlink test**

Test that atomic writes create shadow hardlinks in the shadow directory.

- [ ] **Step 8: Run all tests**

Run: `cd apps/commonplace && mix test --no-color`
Expected: All pass

- [ ] **Step 9: Commit**

```bash
git add apps/commonplace/lib/commonplace/sync/entry_agent.ex apps/commonplace/test/commonplace/sync/entry_agent_test.exs
git commit -m "feat(sync): add EntryAgent for per-file bidirectional sync"
```

---

## Task 3: SchemaCoordinator — Serialize Schema Mutations

**Files:**
- Create: `apps/commonplace/lib/commonplace/sync/schema_coordinator.ex`
- Modify: `apps/commonplace/lib/commonplace/application.ex` (add to supervision tree)

- [ ] **Step 1: Write failing test**

Test that two concurrent schema mutations are serialized (second sees first's changes).

- [ ] **Step 2: Implement SchemaCoordinator**

A `Registry`-based approach: each schema UUID gets a coordinating process on-demand. DirAgents call `SchemaCoordinator.mutate(schema_uuid, fn doc -> ... end)` to serialize writes.

```elixir
defmodule Commonplace.Sync.SchemaCoordinator do
  @moduledoc """
  Serializes schema mutations for a given UUID.
  Prevents CRDT state corruption when multiple DirAgents
  modify the same schema concurrently.
  """

  use GenServer

  def mutate(schema_uuid, store, mutation_fn) do
    pid = ensure_coordinator(schema_uuid)
    GenServer.call(pid, {:mutate, store, mutation_fn})
  end

  defp ensure_coordinator(schema_uuid) do
    case Registry.lookup(Commonplace.SchemaCoordinator.Registry, schema_uuid) do
      [{pid, _}] -> pid
      [] ->
        {:ok, pid} = DynamicSupervisor.start_child(
          Commonplace.SchemaCoordinator.Supervisor,
          {__MODULE__, schema_uuid: schema_uuid}
        )
        pid
    end
  end
end
```

- [ ] **Step 3: Add Registry and DynamicSupervisor to application.ex**

Add to the children list in `Commonplace.Application.start/2`:
```elixir
{Registry, keys: :unique, name: Commonplace.SchemaCoordinator.Registry},
{DynamicSupervisor, name: Commonplace.SchemaCoordinator.Supervisor, strategy: :one_for_one},
```

- [ ] **Step 4: Run tests**

- [ ] **Step 5: Commit**

```bash
git add apps/commonplace/lib/commonplace/sync/schema_coordinator.ex apps/commonplace/lib/commonplace/application.ex
git commit -m "feat(sync): add SchemaCoordinator for serialized schema mutations"
```

---

## Task 4: DirAgent — Per-Directory Schema Watcher

**Files:**
- Create: `apps/commonplace/lib/commonplace/sync/dir_agent.ex`
- Create: `apps/commonplace/test/commonplace/sync/dir_agent_test.exs`
- Read: `apps/commonplace/lib/commonplace/sync/watcher.ex` (extract directory scan logic)

- [ ] **Step 1: Write failing test — spawns EntryAgents for schema entries**

Test that DirAgent reads a schema and starts an EntryAgent for each file entry.

- [ ] **Step 2: Implement DirAgent GenServer**

DirAgent should:
- Hold state: `schema_uuid`, `dir_path`, `store`, `children` (map of entry name → child pid)
- On init: read schema via `DocBuilder.reconstruct_doc`, spawn children
- For `:doc` entries: start `EntryAgent`
- For `:dir` entries: start child `DirAgent` (recursive)
- Skip entries with `sync: false`
- Use `DynamicSupervisor` to manage children
- Subscribe to `{:commit, schema_uuid}` via `Phoenix.PubSub`

- [ ] **Step 3: Run test to verify it passes**

- [ ] **Step 4: Add test — new file on disk triggers schema add + EntryAgent spawn**

Create a file in DirAgent's directory, call `scan_disk/1`, verify schema updated and new EntryAgent started.

- [ ] **Step 5: Add test — file deleted on disk triggers schema remove + EntryAgent stop**

- [ ] **Step 6: Add test — new schema entry from CRDT triggers EntryAgent spawn + file write**

- [ ] **Step 7: Add test — subdirectory entry spawns child DirAgent**

- [ ] **Step 8: Add rename detection test**

Create a file, sync it, rename it on disk, scan — verify schema entry name updated and same UUID preserved.

- [ ] **Step 9: Run all tests**

Run: `cd apps/commonplace && mix test --no-color`

- [ ] **Step 10: Commit**

```bash
git add apps/commonplace/lib/commonplace/sync/dir_agent.ex apps/commonplace/test/commonplace/sync/dir_agent_test.exs
git commit -m "feat(sync): add DirAgent for per-directory schema watching and agent lifecycle"
```

---

## Task 5: PubSub Commit Notifications

**Files:**
- Modify: `apps/commonplace/lib/commonplace/store/commit_store.ex`
- Create: `apps/commonplace/test/commonplace/store/commit_pubsub_test.exs`

- [ ] **Step 1: Write failing test — commit broadcasts on PubSub**

```elixir
test "creating a commit broadcasts on PubSub" do
  Phoenix.PubSub.subscribe(Commonplace.PubSub, "commits:#{doc_uuid}")
  CommitStore.create_chained_commit(doc_uuid, update_binary, store)
  assert_receive {:commit, ^doc_uuid, _commit_id}, 1000
end
```

- [ ] **Step 2: Add PubSub broadcast to CommitStore.create_chained_commit**

After the commit is persisted, broadcast:
```elixir
Phoenix.PubSub.broadcast(Commonplace.PubSub, "commits:#{uuid}", {:commit, uuid, commit.id})
```

- [ ] **Step 3: Run test to verify it passes**

- [ ] **Step 4: Run all tests**

- [ ] **Step 5: Commit**

```bash
git add apps/commonplace/lib/commonplace/store/commit_store.ex apps/commonplace/test/commonplace/store/commit_pubsub_test.exs
git commit -m "feat(store): broadcast PubSub notifications on commit creation"
```

---

## Task 6: CheckoutRegistry

**Files:**
- Create: `apps/commonplace/lib/commonplace/sync/checkout_registry.ex`
- Create: `apps/commonplace/test/commonplace/sync/checkout_registry_test.exs`
- Modify: `apps/commonplace/lib/commonplace/application.ex`

- [ ] **Step 1: Write failing test — register and list checkouts**

```elixir
test "register a directory checkout and list it" do
  {:ok, _} = CheckoutRegistry.register("/tmp/test-checkout", root_uuid, :dir, store)
  checkouts = CheckoutRegistry.list()
  assert length(checkouts) == 1
  assert hd(checkouts).sync_dir == "/tmp/test-checkout"
end
```

- [ ] **Step 2: Implement CheckoutRegistry GenServer**

- State: list of `%{sync_dir, uuid, type, supervisor_pid}`
- `init/1`: read `.commonplace/checkouts.json`, spawn checkout supervisors
- `register/4`: resolve docref, persist to JSON (atomic write), spawn DirAgent or EntryAgent
- `unregister/1`: stop agents, remove from JSON
- `reroot/3`: stop old agents, resolve new docref, update JSON, spawn new agents
- `list/0`: return current checkouts
- Persistence: `checkouts.json` written atomically via temp+rename

- [ ] **Step 3: Run test**

- [ ] **Step 4: Add test — unregister stops agents**

- [ ] **Step 5: Add test — reroot changes UUID and respawns agents**

- [ ] **Step 6: Add test — persistence survives restart**

Stop and restart CheckoutRegistry, verify checkouts are restored.

- [ ] **Step 7: Add test — out-of-tree checkout creates .commonplace-ref breadcrumb**

- [ ] **Step 8: Add CheckoutRegistry to application.ex supervision tree**

- [ ] **Step 9: Run all tests**

- [ ] **Step 10: Commit**

```bash
git add apps/commonplace/lib/commonplace/sync/checkout_registry.ex \
       apps/commonplace/test/commonplace/sync/checkout_registry_test.exs \
       apps/commonplace/lib/commonplace/application.ex
git commit -m "feat(sync): add CheckoutRegistry for multi-checkout management"
```

---

## Task 7: CLI Commands

**Files:**
- Create: `apps/commonplace_cli/lib/commonplace/cli/checkouts.ex`
- Modify: `apps/commonplace_cli/lib/commonplace/cli.ex` (add command routing)
- Modify: `apps/commonplace_cli/lib/commonplace/cli/checkout.ex` (update to use Docref + Registry)

- [ ] **Step 1: Add `checkouts` command — list active checkouts**

```elixir
defmodule Commonplace.CLI.Checkouts do
  alias Commonplace.Sync.CheckoutRegistry

  def run(_data_dir, _relative_path, _args) do
    checkouts = CheckoutRegistry.list()

    if checkouts == [] do
      IO.puts("No active checkouts.")
    else
      Enum.each(checkouts, fn co ->
        IO.puts("#{co.sync_dir}  →  #{co.uuid}  [#{co.type}]")
      end)
    end
  end
end
```

- [ ] **Step 2: Update `checkout` command to use Docref and CheckoutRegistry**

- Support `commonplace checkout /path/to/dir docref` for new checkouts
- Support `commonplace checkout --remove /path` for removal
- Support `commonplace checkout --file /path docref` for file checkouts

- [ ] **Step 3: Add `reroot` command**

```elixir
def run(data_dir, _relative_path, [sync_dir, new_docref]) do
  CLI.ensure_started(data_dir)
  case CheckoutRegistry.reroot(sync_dir, new_docref) do
    :ok -> IO.puts("Re-rooted: #{sync_dir} → #{new_docref}")
    {:error, reason} -> IO.puts(:stderr, "Failed: #{inspect(reason)}")
  end
end
```

- [ ] **Step 4: Add command routing in CLI.ex**

```elixir
"checkout" -> Commonplace.CLI.Checkout.run(data_dir, relative_path, rest)
"checkouts" -> Commonplace.CLI.Checkouts.run(data_dir, relative_path, rest)
"reroot" -> Commonplace.CLI.Reroot.run(data_dir, relative_path, rest)
```

- [ ] **Step 5: Build and test CLI manually**

```bash
cd apps/commonplace_cli && mix escript.build
./commonplace checkouts
```

- [ ] **Step 6: Commit**

```bash
git add apps/commonplace_cli/lib/commonplace/cli/checkouts.ex \
       apps/commonplace_cli/lib/commonplace/cli/checkout.ex \
       apps/commonplace_cli/lib/commonplace/cli.ex
git commit -m "feat(cli): add checkout/checkouts/reroot commands for sparse sync"
```

---

## Task 8: Migration — Wire Existing Sync to CheckoutRegistry

**Files:**
- Modify: `apps/commonplace_cli/lib/commonplace/cli/sync.ex`
- Modify: `apps/commonplace_cli/lib/commonplace/cli/init.ex`

- [ ] **Step 1: Update `init` to register initial checkout**

When `commonplace init` creates a workspace, register it as the first checkout in the CheckoutRegistry.

- [ ] **Step 2: Update `sync` to use CheckoutRegistry**

`commonplace sync` should find the checkout for the current directory (by climbing to find `.commonplace/` or `.commonplace-ref`) and start its sync agents if not already running.

- [ ] **Step 3: Backward compatibility — read `.commonplace/root` into checkouts.json**

If `checkouts.json` doesn't exist but `.commonplace/root` does, auto-migrate: read the root UUID, create a checkout entry for the workspace directory, write `checkouts.json`.

- [ ] **Step 4: Run all tests**

Run: `cd /home/jes/commonplace && mix test --no-color`
Expected: All pass (existing sync tests should still work)

- [ ] **Step 5: Commit**

```bash
git add apps/commonplace_cli/lib/commonplace/cli/sync.ex \
       apps/commonplace_cli/lib/commonplace/cli/init.ex
git commit -m "feat(sync): migrate existing sync to CheckoutRegistry, backward-compatible"
```

---

## Task 9: Integration Test — Full Checkout Lifecycle

**Files:**
- Create: `apps/commonplace/test/commonplace/sync/checkout_integration_test.exs`

- [ ] **Step 1: Write integration test — checkout, edit, sync, verify**

Test the full lifecycle:
1. Init a workspace with some docs
2. Register a checkout to a temp dir
3. Verify files appear on disk
4. Edit a file on disk
5. Run sync
6. Verify CRDT has the edit
7. Edit the CRDT directly
8. Run sync
9. Verify file on disk has the CRDT edit

- [ ] **Step 2: Write integration test — overlapping checkouts**

1. Register two checkouts pointing at the same subtree in different dirs
2. Edit a file in checkout A
3. Sync both
4. Verify the edit appears in checkout B

- [ ] **Step 3: Write integration test — reroot**

1. Register checkout at dir pointing to branch A
2. Reroot to branch B
3. Verify dir now has branch B's content

- [ ] **Step 4: Run all tests**

Run: `cd /home/jes/commonplace && mix test --no-color`

- [ ] **Step 5: Commit**

```bash
git add apps/commonplace/test/commonplace/sync/checkout_integration_test.exs
git commit -m "test(sync): add integration tests for checkout lifecycle, overlap, and reroot"
```

---

## Task 10: Final Cleanup and Documentation

- [ ] **Step 1: Run full test suite with warnings-as-errors**

```bash
mix compile --warnings-as-errors && mix test --no-color
```

- [ ] **Step 2: Update CLAUDE.md with new modules**

Add EntryAgent, DirAgent, CheckoutRegistry, Docref to the key modules table.

- [ ] **Step 3: Update CX-6ib issue**

```bash
bd close CX-6ib --reason="Implemented: CheckoutRegistry, DirAgent, EntryAgent, Docref, CLI commands, migration from monolithic sync agent"
```

- [ ] **Step 4: Push**

```bash
git push
```
