# BEAM Distribution for Multi-Node Sync — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable commonplace instances running on separate BEAM nodes to sync CRDT documents automatically via Erlang distribution.

**Architecture:** libcluster with epmd strategy discovers peer nodes. Phoenix PubSub (already multi-node capable via `pg`) broadcasts new commits in real-time. Per-doc catch-up sync in Document.Server exchanges CID sets on subscribe/reconnect to fill gaps. No Merkle trees for v1 — simple set difference on content-addressed commit IDs.

**Tech Stack:** libcluster, Phoenix.PubSub (pg adapter), Erlang distribution (:shortnames), existing CommitStore/CommitStoreClient

**Issue:** CX-108

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `mix.exs` (commonplace app) | Modify | Add libcluster dependency |
| `apps/commonplace/lib/commonplace/application.ex` | Modify | Add libcluster supervisor child |
| `apps/commonplace/lib/commonplace/cluster.ex` | Create | Cluster configuration and node event handling |
| `apps/commonplace/lib/commonplace/sync/node_sync.ex` | Create | Per-doc CID set diff and commit exchange between nodes |
| `apps/commonplace/lib/commonplace/store/commit_store.ex` | Modify | Add `commit_ids_for_doc/2` (returns just IDs, not full commits) |
| `apps/commonplace/lib/commonplace/store/commit_store_client.ex` | Modify | Add `commit_ids_for_doc/2` client wrapper |
| `apps/commonplace/lib/commonplace/dataflow/pubsub.ex` | Modify | Add sync-channel topic helpers (separate from blue channel) |
| `apps/commonplace/lib/commonplace/store/commit_store.ex` | Modify | Add `import_commit/2` (stores without updating `:latest` head) |
| `apps/commonplace/lib/commonplace/document/server.ex` | Modify | Subscribe to distributed commit broadcasts, trigger catch-up on init |
| `apps/commonplace_cli/lib/commonplace/cli/serve.ex` | Modify | Configure cluster topology at startup |
| `test/commonplace/cluster_test.exs` | Create | Cluster formation tests |
| `test/commonplace/sync/node_sync_test.exs` | Create | CID diff and commit exchange tests |
| `test/commonplace/document/server_distributed_test.exs` | Create | End-to-end distributed sync tests |

---

### Task 1: Add libcluster Dependency

**Files:**
- Modify: `apps/commonplace/mix.exs` — add libcluster to deps

- [ ] **Step 1: Add dependency**

In `apps/commonplace/mix.exs`, add to the `deps` function:

```elixir
{:libcluster, "~> 3.3"}
```

- [ ] **Step 2: Fetch and compile**

Run: `mix deps.get && mix compile`
Expected: Clean compile, no warnings

- [ ] **Step 3: Commit**

```bash
git add apps/commonplace/mix.exs mix.lock
git commit -m "deps: add libcluster for BEAM node clustering (CX-108)"
```

---

### Task 2: Add `commit_ids_for_doc` to CommitStore

We need an efficient way to get just the commit IDs for a doc (not full commits with updates) for the CID set diff.

**Files:**
- Modify: `apps/commonplace/lib/commonplace/store/commit_store.ex`
- Modify: `apps/commonplace/lib/commonplace/store/commit_store_client.ex`
- Test: `apps/commonplace/test/commonplace/store/commit_store_test.exs`

- [ ] **Step 1: Write failing test**

Add to `commit_store_test.exs`:

```elixir
test "commit_ids_for_doc returns all commit IDs for a document", %{store: store} do
  uuid = UUID.uuid4()
  c1 = CommitStore.create_commit(store, uuid, "update1", nil)
  c2 = CommitStore.create_commit(store, uuid, "update2", c1.id)
  c3 = CommitStore.create_commit(store, uuid, "update3", c2.id)

  ids = CommitStore.commit_ids_for_doc(store, uuid)
  assert MapSet.new([c1.id, c2.id, c3.id]) == ids
end

test "commit_ids_for_doc returns empty MapSet for unknown doc", %{store: store} do
  ids = CommitStore.commit_ids_for_doc(store, UUID.uuid4())
  assert ids == MapSet.new()
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/commonplace/test/commonplace/store/commit_store_test.exs --only commit_ids -v`
Expected: FAIL — function not defined

- [ ] **Step 3: Implement in CommitStore**

Add to `commit_store.ex` public API:

```elixir
@doc "Return a MapSet of all commit IDs for a document (walks the chain)."
def commit_ids_for_doc(server \\ __MODULE__, doc_uuid) do
  GenServer.call(server, {:commit_ids_for_doc, doc_uuid})
end
```

Add handle_call clause:

```elixir
def handle_call({:commit_ids_for_doc, doc_uuid}, _from, state) do
  case CubDB.get(state.db, {:latest, doc_uuid}) do
    nil ->
      {:reply, MapSet.new(), state}

    commit_id ->
      ids = collect_ids(state.db, commit_id, MapSet.new())
      {:reply, ids, state}
  end
end

defp collect_ids(_db, nil, acc), do: acc

defp collect_ids(db, commit_id, acc) do
  if MapSet.member?(acc, commit_id) do
    acc
  else
    acc = MapSet.put(acc, commit_id)
    case CubDB.get(db, {:commit, commit_id}) do
      nil -> acc
      commit -> collect_ids(db, commit.parent_id, acc)
    end
  end
end
```

- [ ] **Step 4: Add `import_commit` to CommitStore**

`import_commit` stores a commit from a remote node without updating the `:latest` pointer (avoids clobbering a more recent local head during catch-up):

```elixir
@doc "Store a commit without updating :latest. Used for catch-up sync."
def import_commit(server \\ __MODULE__, commit) do
  GenServer.call(server, {:import_commit, commit})
end
```

Add handle_call clause:

```elixir
def handle_call({:import_commit, commit}, _from, state) do
  # Only store if we don't already have it
  case CubDB.get(state.db, {:commit, commit.id}) do
    nil ->
      CubDB.put(state.db, {:commit, commit.id}, commit)
      {:reply, :ok, state}

    _existing ->
      {:reply, :already_exists, state}
  end
end
```

- [ ] **Step 5: Add CommitStoreClient wrappers**

Add to `commit_store_client.ex`:

```elixir
def commit_ids_for_doc(server \\ CommitStore, doc_uuid) do
  case remote_node() do
    {:ok, node} ->
      GenServer.call({CommitStore, node}, {:commit_ids_for_doc, doc_uuid})

    :local ->
      CommitStore.commit_ids_for_doc(normalize_server(server), doc_uuid)
  end
end

def import_commit(server \\ CommitStore, commit) do
  case remote_node() do
    {:ok, node} ->
      GenServer.call({CommitStore, node}, {:import_commit, commit})

    :local ->
      CommitStore.import_commit(normalize_server(server), commit)
  end
end
```

- [ ] **Step 5: Run tests**

Run: `mix test apps/commonplace/test/commonplace/store/commit_store_test.exs -v`
Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add apps/commonplace/lib/commonplace/store/commit_store.ex \
       apps/commonplace/lib/commonplace/store/commit_store_client.ex \
       apps/commonplace/test/commonplace/store/commit_store_test.exs
git commit -m "feat: add commit_ids_for_doc for CID set diff (CX-108)"
```

---

### Task 3: Create NodeSync Module

The core sync logic: given two nodes, diff their CID sets for a doc and exchange missing commits.

**Files:**
- Create: `apps/commonplace/lib/commonplace/sync/node_sync.ex`
- Test: `apps/commonplace/test/commonplace/sync/node_sync_test.exs`

- [ ] **Step 1: Write failing test for CID diff**

Create `test/commonplace/sync/node_sync_test.exs`:

```elixir
defmodule Commonplace.Sync.NodeSyncTest do
  use ExUnit.Case, async: true

  alias Commonplace.Sync.NodeSync

  test "diff_commit_ids returns missing IDs in each direction" do
    local = MapSet.new(["a", "b", "c"])
    remote = MapSet.new(["b", "c", "d"])

    assert {missing_local, missing_remote} = NodeSync.diff_commit_ids(local, remote)
    assert missing_local == MapSet.new(["d"])   # remote has, local doesn't
    assert missing_remote == MapSet.new(["a"])   # local has, remote doesn't
  end

  test "diff_commit_ids with identical sets returns empty" do
    ids = MapSet.new(["a", "b"])
    {missing_local, missing_remote} = NodeSync.diff_commit_ids(ids, ids)
    assert missing_local == MapSet.new()
    assert missing_remote == MapSet.new()
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/commonplace/test/commonplace/sync/node_sync_test.exs -v`
Expected: FAIL — module not defined

- [ ] **Step 3: Implement NodeSync**

Create `apps/commonplace/lib/commonplace/sync/node_sync.ex`:

```elixir
defmodule Commonplace.Sync.NodeSync do
  @moduledoc """
  Per-document sync between BEAM nodes.

  Handles CID set diffing and commit exchange for catch-up sync.
  Steady-state sync is handled by Phoenix PubSub broadcasts.
  """

  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Store.CommitStore

  require Logger

  @doc """
  Diff two CID sets, returning {missing_local, missing_remote}.

  missing_local: IDs the remote has that we don't (we need to fetch these).
  missing_remote: IDs we have that the remote doesn't (we should send these).
  """
  def diff_commit_ids(local_ids, remote_ids) do
    missing_local = MapSet.difference(remote_ids, local_ids)
    missing_remote = MapSet.difference(local_ids, remote_ids)
    {missing_local, missing_remote}
  end

  @doc """
  Perform catch-up sync for a document with a remote node.

  1. Get local CID set
  2. Get remote CID set (via GenServer.call to remote CommitStore)
  3. Diff
  4. Fetch missing commits from remote, store locally
  5. Send missing commits to remote
  """
  def catch_up(doc_uuid, remote_node, local_store \\ CommitStore) do
    local_ids = CommitStoreClient.commit_ids_for_doc(local_store, doc_uuid)

    remote_ids =
      GenServer.call({CommitStore, remote_node}, {:commit_ids_for_doc, doc_uuid})

    {missing_local, missing_remote} = diff_commit_ids(local_ids, remote_ids)

    # Fetch commits we're missing from remote
    fetched =
      Enum.map(missing_local, fn id ->
        GenServer.call({CommitStore, remote_node}, {:get_commit, id})
      end)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, commit} -> commit end)

    # Store fetched commits locally (import_commit avoids clobbering :latest)
    Enum.each(fetched, fn commit ->
      CommitStoreClient.import_commit(local_store, commit)
    end)

    # Send commits the remote is missing
    missing_commits =
      Enum.map(missing_remote, fn id ->
        CommitStoreClient.get_commit(local_store, id)
      end)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, commit} -> commit end)

    Enum.each(missing_commits, fn commit ->
      GenServer.call({CommitStore, remote_node}, {:import_commit, commit})
    end)

    Logger.debug(
      "NodeSync catch_up #{doc_uuid}: fetched #{length(fetched)}, sent #{length(missing_commits)}"
    )

    {:ok, %{fetched: length(fetched), sent: length(missing_commits)}}
  end
end
```

- [ ] **Step 4: Run tests**

Run: `mix test apps/commonplace/test/commonplace/sync/node_sync_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add apps/commonplace/lib/commonplace/sync/node_sync.ex \
       apps/commonplace/test/commonplace/sync/node_sync_test.exs
git commit -m "feat: NodeSync module with CID diff and catch-up (CX-108)"
```

---

### Task 4: Cluster Configuration Module

**Files:**
- Create: `apps/commonplace/lib/commonplace/cluster.ex`
- Modify: `apps/commonplace/lib/commonplace/application.ex`

- [ ] **Step 1: Create Cluster module**

Create `apps/commonplace/lib/commonplace/cluster.ex`:

```elixir
defmodule Commonplace.Cluster do
  @moduledoc """
  Cluster configuration for BEAM distribution.

  Uses libcluster with configurable topology. Default: epmd strategy
  with node list from COMMONPLACE_NODES env var (comma-separated).
  """

  @doc "Return libcluster topology config from environment."
  def topology do
    case System.get_env("COMMONPLACE_NODES") do
      nil ->
        []

      nodes_str ->
        nodes =
          nodes_str
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&String.to_atom/1)

        [
          commonplace: [
            strategy: Cluster.Strategy.Epmd,
            config: [hosts: nodes]
          ]
        ]
    end
  end
end
```

- [ ] **Step 2: Add cluster supervisor to application.ex**

In `apps/commonplace/lib/commonplace/application.ex`, add to the children list (after PubSub, before CommitStoreSupervisor):

```elixir
{Cluster.Supervisor, [Commonplace.Cluster.topology(), [name: Commonplace.ClusterSupervisor]]}
```

- [ ] **Step 3: Verify compile**

Run: `mix compile --warnings-as-errors`
Expected: Clean compile

- [ ] **Step 4: Commit**

```bash
git add apps/commonplace/lib/commonplace/cluster.ex \
       apps/commonplace/lib/commonplace/application.ex
git commit -m "feat: libcluster integration with epmd strategy (CX-108)"
```

---

### Task 5: Distributed PubSub Commit Broadcasts

Phoenix PubSub already distributes via `pg` when nodes are connected. We need to:
1. Broadcast full commit data (not just notifications) on blue channel
2. Have Document.Server listen for remote commits and store them locally

**Files:**
- Modify: `apps/commonplace/lib/commonplace/dataflow/pubsub.ex` — add `broadcast_commit/3`
- Modify: `apps/commonplace/lib/commonplace/document/server.ex` — handle distributed commits
- Test: `apps/commonplace/test/commonplace/sync/distributed_pubsub_test.exs`

- [ ] **Step 1: Add sync channel helpers to PubSub**

Add to `apps/commonplace/lib/commonplace/dataflow/pubsub.ex` — use a dedicated `sync:` topic to avoid conflicting with existing blue channel message formats:

```elixir
@doc "Subscribe to sync channel for distributed commit replication."
def subscribe_sync(doc_uuid) do
  Phoenix.PubSub.subscribe(Commonplace.PubSub, "sync:#{doc_uuid}")
end

@doc "Unsubscribe from sync channel."
def unsubscribe_sync(doc_uuid) do
  Phoenix.PubSub.unsubscribe(Commonplace.PubSub, "sync:#{doc_uuid}")
end

@doc """
Broadcast a full commit on the sync channel for distributed replication.
Message format: {:remote_commit, commit, source_node}
"""
def broadcast_commit(doc_uuid, commit) do
  Phoenix.PubSub.broadcast(
    Commonplace.PubSub,
    "sync:#{doc_uuid}",
    {:remote_commit, commit, Node.self()}
  )
end
```

- [ ] **Step 2: Handle remote commits in Document.Server**

Add a `handle_info` clause to `apps/commonplace/lib/commonplace/document/server.ex`:

```elixir
@impl true
def handle_info({:remote_commit, commit, source_node}, state) do
  # Ignore our own broadcasts
  if source_node != Node.self() do
    # Store the remote commit locally (import avoids clobbering :latest)
    CommitStoreClient.import_commit(state.commit_store, commit)

    # Apply the update to our in-memory doc
    case Yelixer.Encoding.apply_update(state.doc, commit.update) do
      {:ok, doc} ->
        {:noreply, %{state | doc: doc}}

      {:error, _} ->
        {:noreply, state}
    end
  else
    {:noreply, state}
  end
end
```

- [ ] **Step 3: Subscribe to sync channel on Document.Server init**

In Document.Server `init/1`, after existing setup:

```elixir
Commonplace.Dataflow.PubSub.subscribe_sync(uuid)
```

- [ ] **Step 4: Broadcast commits after creation**

In any code path that creates a commit and currently calls `broadcast_blue/2`, also call `broadcast_commit/2` with the full commit struct. The key places are:
- `Document.Server.handle_call({:commit, ...})` 
- WikiLive `handle_event("yjs_edit", ...)`

- [ ] **Step 5: Write test**

Create `test/commonplace/sync/distributed_pubsub_test.exs`:

```elixir
defmodule Commonplace.Sync.DistributedPubSubTest do
  use ExUnit.Case, async: false

  alias Commonplace.Dataflow.PubSub, as: CPPubSub

  test "broadcast_commit sends commit on sync channel" do
    uuid = UUID.uuid4()
    CPPubSub.subscribe_sync(uuid)

    commit = %Commonplace.Store.Commit{
      id: :crypto.strong_rand_bytes(32),
      doc_uuid: uuid,
      parent_id: nil,
      update: "test_update",
      timestamp: DateTime.utc_now()
    }

    CPPubSub.broadcast_commit(uuid, commit)

    assert_receive {:remote_commit, ^commit, _node}, 1000
  end
end
```

- [ ] **Step 6: Run tests**

Run: `mix test apps/commonplace/test/commonplace/sync/distributed_pubsub_test.exs -v`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add apps/commonplace/lib/commonplace/dataflow/pubsub.ex \
       apps/commonplace/lib/commonplace/document/server.ex \
       apps/commonplace/test/commonplace/sync/distributed_pubsub_test.exs
git commit -m "feat: distributed commit broadcasts via PubSub (CX-108)"
```

---

### Task 6: Catch-Up Sync on Node Join

When a new node joins the cluster, trigger catch-up sync for active documents.

**Files:**
- Create: `apps/commonplace/lib/commonplace/cluster/event_handler.ex`
- Modify: `apps/commonplace/lib/commonplace/application.ex`

- [ ] **Step 1: Create cluster event handler**

Create `apps/commonplace/lib/commonplace/cluster/event_handler.ex`:

```elixir
defmodule Commonplace.Cluster.EventHandler do
  @moduledoc """
  Handles cluster membership changes.

  When a new node joins, triggers catch-up sync for all locally-active
  documents with the new peer.
  """

  use GenServer

  alias Commonplace.Sync.NodeSync

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :net_kernel.monitor_nodes(true)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.info("Cluster: node joined — #{node}")

    # Get all locally-active document UUIDs and trigger catch-up
    Task.start(fn ->
      uuids = active_doc_uuids()

      Enum.each(uuids, fn uuid ->
        case NodeSync.catch_up(uuid, node) do
          {:ok, stats} ->
            Logger.debug("Catch-up #{uuid} with #{node}: #{inspect(stats)}")

          {:error, reason} ->
            Logger.warning("Catch-up #{uuid} with #{node} failed: #{inspect(reason)}")
        end
      end)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    Logger.info("Cluster: node left — #{node}")
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp active_doc_uuids do
    Registry.select(Commonplace.Document.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
```

- [ ] **Step 2: Add to supervision tree**

In `application.ex`, add after the Cluster.Supervisor child:

```elixir
Commonplace.Cluster.EventHandler
```

- [ ] **Step 3: Verify compile**

Run: `mix compile --warnings-as-errors`
Expected: Clean compile

- [ ] **Step 4: Commit**

```bash
git add apps/commonplace/lib/commonplace/cluster/event_handler.ex \
       apps/commonplace/lib/commonplace/application.ex
git commit -m "feat: cluster event handler triggers catch-up on node join (CX-108)"
```

---

### Task 7: Wire Up serve.ex for Clustering

**Files:**
- Modify: `apps/commonplace_cli/lib/commonplace/cli/serve.ex`

- [ ] **Step 1: Log cluster topology on startup**

In serve.ex `run/3`, after `start_named_node(data_dir)`, add:

```elixir
topology = Commonplace.Cluster.topology()

if topology != [] do
  IO.puts("  Cluster peers: #{inspect(topology)}")
else
  IO.puts("  Cluster: standalone (set COMMONPLACE_NODES to enable clustering)")
end
```

- [ ] **Step 2: Verify compile**

Run: `mix compile --warnings-as-errors`
Expected: Clean compile

- [ ] **Step 3: Commit**

```bash
git add apps/commonplace_cli/lib/commonplace/cli/serve.ex
git commit -m "feat: serve.ex logs cluster topology (CX-108)"
```

---

### Task 8: Integration Test — Two-Node Sync

**Files:**
- Create: `apps/commonplace/test/commonplace/sync/two_node_sync_test.exs`

- [ ] **Step 1: Write integration test**

This test runs in a single BEAM but simulates the sync protocol by calling NodeSync directly with two separate CommitStore instances.

Create `test/commonplace/sync/two_node_sync_test.exs`:

```elixir
defmodule Commonplace.Sync.TwoNodeSyncTest do
  use ExUnit.Case, async: false

  alias Commonplace.Store.CommitStore
  alias Commonplace.Sync.NodeSync

  setup do
    dir_a = Path.join(System.tmp_dir!(), "cp_node_a_#{:rand.uniform(999999)}")
    dir_b = Path.join(System.tmp_dir!(), "cp_node_b_#{:rand.uniform(999999)}")
    File.mkdir_p!(dir_a)
    File.mkdir_p!(dir_b)

    {:ok, store_a} = CommitStore.start_link(data_dir: dir_a, name: :node_a_store)
    {:ok, store_b} = CommitStore.start_link(data_dir: dir_b, name: :node_b_store)

    on_exit(fn ->
      GenServer.stop(store_a)
      GenServer.stop(store_b)
      File.rm_rf!(dir_a)
      File.rm_rf!(dir_b)
    end)

    %{store_a: store_a, store_b: store_b}
  end

  test "catch-up syncs missing commits between two stores", %{store_a: store_a, store_b: store_b} do
    uuid = UUID.uuid4()

    # Create commits only in store A
    c1 = CommitStore.create_commit(store_a, uuid, "update_1", nil)
    c2 = CommitStore.create_commit(store_a, uuid, "update_2", c1.id)

    # Verify store B has nothing
    assert CommitStore.commit_ids_for_doc(store_b, uuid) == MapSet.new()

    # Perform diff
    ids_a = CommitStore.commit_ids_for_doc(store_a, uuid)
    ids_b = CommitStore.commit_ids_for_doc(store_b, uuid)
    {missing_b, missing_a} = NodeSync.diff_commit_ids(ids_b, ids_a)

    assert MapSet.size(missing_b) == 2
    assert MapSet.size(missing_a) == 0

    # Manually transfer missing commits (simulating catch_up without remote nodes)
    Enum.each(missing_b, fn id ->
      {:ok, commit} = CommitStore.get_commit(store_a, id)
      CommitStore.import_commit(store_b, commit)
    end)

    # Verify store B now has both commits
    ids_b_after = CommitStore.commit_ids_for_doc(store_b, uuid)
    assert MapSet.size(ids_b_after) == 2
    assert ids_b_after == ids_a
  end

  test "bidirectional sync merges divergent histories", %{store_a: store_a, store_b: store_b} do
    uuid = UUID.uuid4()

    # Create shared base in both
    c1 = CommitStore.create_commit(store_a, uuid, "base", nil)
    CommitStore.create_commit(store_b, uuid, "base", nil)

    # Diverge: A gets commit 2a, B gets commit 2b
    _c2a = CommitStore.create_commit(store_a, uuid, "from_a", c1.id)
    _c2b = CommitStore.create_commit(store_b, uuid, "from_b", c1.id)

    ids_a = CommitStore.commit_ids_for_doc(store_a, uuid)
    ids_b = CommitStore.commit_ids_for_doc(store_b, uuid)

    {missing_a, missing_b} = NodeSync.diff_commit_ids(ids_a, ids_b)

    # Each should be missing one commit from the other
    assert MapSet.size(missing_a) == 1
    assert MapSet.size(missing_b) == 1
  end
end
```

- [ ] **Step 2: Run integration test**

Run: `mix test apps/commonplace/test/commonplace/sync/two_node_sync_test.exs -v`
Expected: PASS

- [ ] **Step 3: Run full test suite**

Run: `mix test`
Expected: All existing tests still pass

- [ ] **Step 4: Commit**

```bash
git add apps/commonplace/test/commonplace/sync/two_node_sync_test.exs
git commit -m "test: two-node sync integration tests (CX-108)"
```

---

### Task 9: Documentation and Issue Closure

- [ ] **Step 1: Update CLAUDE.md**

Add to the "Key patterns" section:

```markdown
- **BEAM distribution**: Set `COMMONPLACE_NODES=node1@host,node2@host` for clustering. Phoenix PubSub distributes automatically. Catch-up sync uses CID set diff on node join.
```

- [ ] **Step 2: Close issue**

```bash
bd close CX-108 --reason="libcluster + distributed PubSub + per-doc CID catch-up sync implemented"
```

- [ ] **Step 3: Final commit and push**

```bash
git add CLAUDE.md
git commit -m "docs: BEAM distribution usage in CLAUDE.md (CX-108)"
git push
```
