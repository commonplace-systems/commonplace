# Fork as DAG Branch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite fork and merge to use shared commit DAG branches instead of deep-copy + ForkManifest.

**Architecture:** UUID = branch name into shared commit DAG. Fork creates new UUIDs with branch-point commits (parent pointing into source chain), then creates schema edit commits that remap child node_ids. Merge finds common ancestors by walking parent chains. ForkManifest eliminated entirely.

**Plan review notes (from reviewer):**
- `set_latest/3` is added to CommitStore for testing/future use but fork creates branch-point commits directly via `create_commit` (which also sets latest). The spec's two-step model is conceptual.
- `is_schema?` must check `Schema.version(doc) != nil`, NOT `length(entries) > 0` (empty dirs are valid schemas).
- Delete-vs-modify detection: when source deletes a file that target still has, we need to check if the target modified it since fork. Conservative approach: always flag as conflict if we can't determine fork-point state. The fork-point commit for the child can be found by walking the source root's chain to the fork commit and looking up the remapped UUID. File CX-5gr follow-up for full implementation.
- `reconstruct_doc/2` is duplicated in Fork and Merge — extract to shared helper in a later pass.
- CLI fork must update destructure: `new_uuid = Fork.fork_directory(...)` (no manifest tuple).
- Rename detection from current merge is NOT carried over — deferred since DAG model may handle this differently via node_id ancestry.

**Tech Stack:** Elixir, Yelixer (Yjs CRDT), CubDB-backed CommitStore

**Spec:** `docs/superpowers/specs/2026-03-23-fork-as-dag-branch-design.md`

**Important context:**
- `CommitStore.commit_log/3` returns **newest-first** (default limit: 100, use `limit: 10_000` for full chains)
- `Encoding.apply_update/2` always returns `{:ok, doc}` — no error clause needed
- `Schema.entries/1` returns `%{name => %{"type" => ..., "node_id" => ...}}`
- `Schema.list_entries/1` returns `[%Entry{name, type, node_id, sync}]`
- `CommitStore.create_commit/4` returns bare commit struct (not `{:ok, commit}`)
- ForkManifest is **never persisted** — clean break, no migration needed
- Merge has **no CLI command** yet — only used in tests
- Sync agent does NOT inspect `commit.doc_uuid` — safe to make historical

---

### File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `apps/commonplace/lib/commonplace/store/commit_store.ex` | Modify | Add `set_latest/3`, add `find_common_ancestor/3` |
| `apps/commonplace/lib/commonplace/store/commit.ex` | Modify | Comment `doc_uuid` as historical |
| `apps/commonplace/lib/commonplace/tree/fork.ex` | Rewrite | DAG branch fork: set_latest + schema edit commits |
| `apps/commonplace/lib/commonplace/tree/merge.ex` | Rewrite | Common-ancestor merge, recursive schema pairing |
| `apps/commonplace/lib/commonplace/tree/fork_manifest.ex` | Delete | No longer needed |
| `apps/commonplace_cli/lib/commonplace/cli/fork.ex` | Modify | Remove manifest output |
| `apps/commonplace/test/commonplace/tree/fork_test.exs` | Rewrite | Test DAG branch behavior |
| `apps/commonplace/test/commonplace/tree/merge_test.exs` | Rewrite | Test common-ancestor merge |
| `apps/commonplace/test/commonplace/tree/fork_manifest_test.exs` | Delete | No longer needed |

---

### Task 1: CommitStore — set_latest and find_common_ancestor

Add two new functions to CommitStore: `set_latest/3` (point a UUID at an existing commit) and `find_common_ancestor/4` (walk two chains to find shared commit).

**Files:**
- Modify: `apps/commonplace/lib/commonplace/store/commit_store.ex`
- Modify: `apps/commonplace/lib/commonplace/store/commit.ex`
- Create: `apps/commonplace/test/commonplace/store/commit_store_branch_test.exs`

- [ ] **Step 1: Write tests for set_latest and find_common_ancestor**

```elixir
# apps/commonplace/test/commonplace/store/commit_store_branch_test.exs
defmodule Commonplace.Store.CommitStoreBranchTest do
  use ExUnit.Case

  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "cs_branch_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"cs_branch_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store}
  end

  describe "set_latest/3" do
    test "points a new UUID at an existing commit", %{store: store} do
      # Create a commit under UUID-A
      commit_a = CommitStore.create_commit(store, "uuid-a", "update-1", nil)

      # Point UUID-B at the same commit
      :ok = CommitStore.set_latest(store, "uuid-b", commit_a.id)

      # Both UUIDs should resolve to the same commit
      {:ok, latest_b} = CommitStore.latest_commit(store, "uuid-b")
      assert latest_b.id == commit_a.id
    end

    test "new UUID can have its own commits after set_latest", %{store: store} do
      commit_a1 = CommitStore.create_commit(store, "uuid-a", "update-1", nil)
      :ok = CommitStore.set_latest(store, "uuid-b", commit_a1.id)

      # Create a new commit on UUID-B
      commit_b1 = CommitStore.create_commit(store, "uuid-b", "update-b", commit_a1.id)

      # UUID-A still points to its original commit
      {:ok, latest_a} = CommitStore.latest_commit(store, "uuid-a")
      assert latest_a.id == commit_a1.id

      # UUID-B points to its new commit
      {:ok, latest_b} = CommitStore.latest_commit(store, "uuid-b")
      assert latest_b.id == commit_b1.id

      # UUID-B's chain walks through UUID-A's history
      log = CommitStore.commit_log(store, "uuid-b")
      assert length(log) == 2
    end
  end

  describe "find_common_ancestor/4" do
    test "finds common ancestor of branched chains", %{store: store} do
      c1 = CommitStore.create_commit(store, "uuid-a", "base", nil)
      c2 = CommitStore.create_commit(store, "uuid-a", "shared", c1.id)

      # Branch: UUID-B starts at c2
      :ok = CommitStore.set_latest(store, "uuid-b", c2.id)
      _c3a = CommitStore.create_commit(store, "uuid-a", "a-edit", c2.id)
      _c3b = CommitStore.create_commit(store, "uuid-b", "b-edit", c2.id)

      {:ok, ancestor} = CommitStore.find_common_ancestor(store, "uuid-a", "uuid-b")
      assert ancestor.id == c2.id
    end

    test "returns :none for unrelated chains", %{store: store} do
      CommitStore.create_commit(store, "uuid-a", "a-only", nil)
      CommitStore.create_commit(store, "uuid-b", "b-only", nil)

      assert :none = CommitStore.find_common_ancestor(store, "uuid-a", "uuid-b")
    end

    test "handles identical chains (same latest)", %{store: store} do
      c1 = CommitStore.create_commit(store, "uuid-a", "shared", nil)
      :ok = CommitStore.set_latest(store, "uuid-b", c1.id)

      {:ok, ancestor} = CommitStore.find_common_ancestor(store, "uuid-a", "uuid-b")
      assert ancestor.id == c1.id
    end
  end
end
```

- [ ] **Step 2: Run tests — expect failure**

Run: `cd apps/commonplace && mix test test/commonplace/store/commit_store_branch_test.exs --trace`

- [ ] **Step 3: Implement set_latest and find_common_ancestor**

Add to `commit_store.ex` public API:

```elixir
@doc "Point a UUID at an existing commit without creating a new one."
def set_latest(server \\ __MODULE__, doc_uuid, commit_id) do
  GenServer.call(server, {:set_latest, doc_uuid, commit_id})
end

@doc "Find the most recent common ancestor between two UUID chains."
def find_common_ancestor(server \\ __MODULE__, uuid_a, uuid_b) do
  GenServer.call(server, {:find_common_ancestor, uuid_a, uuid_b})
end
```

Add handle_call clauses:

```elixir
@impl true
def handle_call({:set_latest, doc_uuid, commit_id}, _from, state) do
  CubDB.put(state.db, {:latest, doc_uuid}, commit_id)
  {:reply, :ok, state}
end

@impl true
def handle_call({:find_common_ancestor, uuid_a, uuid_b}, _from, state) do
  # Load one chain into a set, walk the other to find intersection
  ids_a = collect_commit_ids(state.db, uuid_a)
  result = walk_to_ancestor(state.db, uuid_b, ids_a)
  {:reply, result, state}
end

defp collect_commit_ids(db, doc_uuid) do
  case CubDB.get(db, {:latest, doc_uuid}) do
    nil -> MapSet.new()
    commit_id -> collect_ids(db, commit_id, MapSet.new())
  end
end

defp collect_ids(_db, nil, acc), do: acc
defp collect_ids(db, commit_id, acc) do
  acc = MapSet.put(acc, commit_id)
  case CubDB.get(db, {:commit, commit_id}) do
    nil -> acc
    commit -> collect_ids(db, commit.parent_id, acc)
  end
end

defp walk_to_ancestor(db, doc_uuid, ancestor_ids) do
  case CubDB.get(db, {:latest, doc_uuid}) do
    nil -> :none
    commit_id -> find_in_chain(db, commit_id, ancestor_ids)
  end
end

defp find_in_chain(_db, nil, _ids), do: :none
defp find_in_chain(db, commit_id, ancestor_ids) do
  if MapSet.member?(ancestor_ids, commit_id) do
    {:ok, CubDB.get(db, {:commit, commit_id})}
  else
    case CubDB.get(db, {:commit, commit_id}) do
      nil -> :none
      commit -> find_in_chain(db, commit.parent_id, ancestor_ids)
    end
  end
end
```

Also update `commit.ex` — add comment to `doc_uuid`:

```elixir
defstruct [
  :id,
  :doc_uuid,    # Historical: which UUID originally created this commit (debugging only)
  :parent_id,
  :update,
  :timestamp
]
```

- [ ] **Step 4: Run tests**

Run: `cd apps/commonplace && mix test test/commonplace/store/commit_store_branch_test.exs --trace`
Expected: all pass

- [ ] **Step 5: Run full suite**

Run: `cd apps/commonplace && mix test`

- [ ] **Step 6: Commit**

```bash
git add apps/commonplace/lib/commonplace/store/commit_store.ex apps/commonplace/lib/commonplace/store/commit.ex apps/commonplace/test/commonplace/store/commit_store_branch_test.exs
git commit -m "feat(commit-store): add set_latest and find_common_ancestor for DAG branches (CX-9zu)"
```

---

### Task 2: Rewrite Fork — DAG branch model

Replace deep-copy fork with DAG branch fork: set_latest for branch points, schema edit commits for UUID remapping.

**Files:**
- Rewrite: `apps/commonplace/lib/commonplace/tree/fork.ex`
- Rewrite: `apps/commonplace/test/commonplace/tree/fork_test.exs`

- [ ] **Step 1: Write tests for new fork behavior**

```elixir
# Rewrite apps/commonplace/test/commonplace/tree/fork_test.exs
defmodule Commonplace.Tree.ForkTest do
  use ExUnit.Case

  alias Commonplace.Tree.{Fork, Schema}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType
  alias Commonplace.Process.Config

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_fork_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_fork_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name}
  end

  test "forks a simple directory with files", %{store: store} do
    file1_uuid = create_text_doc(store, "file1.txt", "content one")
    file2_uuid = create_text_doc(store, "file2.txt", "content two")

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    root_doc = Schema.add_file(root_doc, "file1.txt", file1_uuid)
    root_doc = Schema.add_file(root_doc, "file2.txt", file2_uuid)
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store, root_uuid, update, nil)

    new_root = Fork.fork_directory(root_uuid, store)

    # New root has different UUID
    assert new_root != root_uuid

    # New root has a schema with different child UUIDs
    {:ok, commit} = CommitStore.latest_commit(store, new_root)
    schema = Schema.new_schema()
    {:ok, schema} = Yelixer.Encoding.apply_update(schema, commit.update)
    {:ok, e1} = Schema.get_entry(schema, "file1.txt")
    {:ok, e2} = Schema.get_entry(schema, "file2.txt")
    assert e1.node_id != file1_uuid
    assert e2.node_id != file2_uuid

    # Forked leaf docs share commit history — common ancestor exists
    {:ok, ancestor} = CommitStore.find_common_ancestor(store, file1_uuid, e1.node_id)
    assert ancestor != nil

    # Content is preserved
    {:ok, fork_commit} = CommitStore.latest_commit(store, e1.node_id)
    doc = Yelixer.Doc.new()
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, fork_commit.update)
    assert ContentType.get_content(doc) == "content one"
  end

  test "forked documents share commit chains", %{store: store} do
    file_uuid = create_text_doc(store, "test.txt", "original")
    {:ok, orig_commit} = CommitStore.latest_commit(store, file_uuid)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    root_doc = Schema.add_file(root_doc, "test.txt", file_uuid)
    CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(root_doc), nil)

    new_root = Fork.fork_directory(root_uuid, store)

    {:ok, commit} = CommitStore.latest_commit(store, new_root)
    schema = Schema.new_schema()
    {:ok, schema} = Yelixer.Encoding.apply_update(schema, commit.update)
    {:ok, entry} = Schema.get_entry(schema, "test.txt")

    # The forked leaf's chain includes the original commit
    log = CommitStore.commit_log(store, entry.node_id)
    commit_ids = Enum.map(log, & &1.id)
    assert orig_commit.id in commit_ids
  end

  test "forks nested directories", %{store: store} do
    inner_file = create_text_doc(store, "inner.txt", "nested")

    inner_uuid = UUID.uuid4()
    inner_doc = Schema.new_schema()
    inner_doc = Schema.add_file(inner_doc, "inner.txt", inner_file)
    CommitStore.create_commit(store, inner_uuid, Yelixer.Encoding.encode_update(inner_doc), nil)

    outer_uuid = UUID.uuid4()
    outer_doc = Schema.new_schema()
    outer_doc = Schema.add_directory(outer_doc, "subdir", inner_uuid)
    CommitStore.create_commit(store, outer_uuid, Yelixer.Encoding.encode_update(outer_doc), nil)

    new_root = Fork.fork_directory(outer_uuid, store)
    assert new_root != outer_uuid

    # Verify nested structure exists
    {:ok, commit} = CommitStore.latest_commit(store, new_root)
    schema = Schema.new_schema()
    {:ok, schema} = Yelixer.Encoding.apply_update(schema, commit.update)
    {:ok, subdir_entry} = Schema.get_entry(schema, "subdir")
    assert subdir_entry.type == :dir
    assert subdir_entry.node_id != inner_uuid
  end

  test "fork_behavior defaults" do
    assert Config.fork_behavior(%Config{mode: :sandbox_exec}) == :skip
    assert Config.fork_behavior(%Config{mode: :elixir}) == :copy
    assert Config.fork_behavior(%Config{mode: :command}) == :skip
    assert Config.fork_behavior(%Config{mode: :command, fork: :copy}) == :copy
  end

  test "filters __processes.json during fork", %{store: store} do
    proc_content =
      Jason.encode!(%{
        "safe_elixir" => %{"mode" => "elixir", "source" => "worker.exs"},
        "singleton" => %{"mode" => "command", "command" => "run"}
      })

    proc_uuid = create_text_doc(store, "__processes.json", proc_content)
    file_uuid = create_text_doc(store, "data.txt", "data")

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    root_doc = Schema.add_file(root_doc, "__processes.json", proc_uuid)
    root_doc = Schema.add_file(root_doc, "data.txt", file_uuid)
    CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(root_doc), nil)

    new_root = Fork.fork_directory(root_uuid, store)

    {:ok, commit} = CommitStore.latest_commit(store, new_root)
    schema = Schema.new_schema()
    {:ok, schema} = Yelixer.Encoding.apply_update(schema, commit.update)
    {:ok, proc_entry} = Schema.get_entry(schema, "__processes.json")

    {:ok, proc_commit} = CommitStore.latest_commit(store, proc_entry.node_id)
    proc_doc = Yelixer.Doc.new()
    {:ok, proc_doc} = Yelixer.Encoding.apply_update(proc_doc, proc_commit.update)
    content = ContentType.get_content(proc_doc)
    parsed = Jason.decode!(content)

    assert Map.has_key?(parsed, "safe_elixir")
    refute Map.has_key?(parsed, "singleton")
  end

  defp create_text_doc(store, name, content) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = if content != "", do: ContentType.insert_text(doc, 0, content), else: doc
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
    uuid
  end
end
```

- [ ] **Step 2: Run tests — expect failure (fork module still has old implementation)**

- [ ] **Step 3: Rewrite fork.ex**

The new Fork returns just `new_root_uuid` (no manifest):

```elixir
defmodule Commonplace.Tree.Fork do
  @moduledoc """
  Fork a directory subtree using DAG branches.

  Creates new UUIDs that branch off existing commit chains.
  Schema edit commits remap child node_ids to the new UUIDs.
  Leaf docs get branch-point commits (same content, new UUID).
  No ForkManifest — provenance is in the shared commit DAG.
  """

  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore
  alias Commonplace.Process.Config
  alias Commonplace.Document.ContentType
  alias Yelixer.{Doc, Encoding}

  @doc """
  Fork a directory subtree using DAG branches.
  Returns the new root UUID.
  """
  def fork_directory(source_uuid, store \\ CommitStore) do
    {new_uuid, _uuid_map} = fork_node(source_uuid, store, %{})
    new_uuid
  end

  # Fork a node, returning {new_uuid, uuid_map} where uuid_map tracks
  # source_uuid => new_uuid for all forked docs (used for schema remapping).
  defp fork_node(source_uuid, store, uuid_map) do
    case CommitStore.latest_commit(store, source_uuid) do
      {:ok, commit} ->
        schema_doc = Schema.new_schema()

        case Encoding.apply_update(schema_doc, commit.update) do
          {:ok, schema_doc} ->
            entries = Schema.list_entries(schema_doc)

            if length(entries) > 0 do
              fork_directory_node(source_uuid, entries, store, uuid_map, commit)
            else
              fork_leaf_node(source_uuid, store, uuid_map, commit)
            end

          _ ->
            fork_leaf_node(source_uuid, store, uuid_map, commit)
        end

      :none ->
        new_uuid = UUID.uuid4()
        {new_uuid, Map.put(uuid_map, source_uuid, new_uuid)}
    end
  end

  defp fork_directory_node(source_uuid, entries, store, uuid_map, commit) do
    new_uuid = UUID.uuid4()
    uuid_map = Map.put(uuid_map, source_uuid, new_uuid)

    # Fork all children first to build the uuid_map
    {uuid_map, _} =
      Enum.reduce(entries, {uuid_map, []}, fn entry, {map, _} ->
        {_child_uuid, map} = fork_node(entry.node_id, store, map)
        {map, []}
      end)

    # Reconstruct source schema and remap node_ids
    {:ok, source_doc} = reconstruct_doc(store, source_uuid)

    edited_doc =
      Enum.reduce(entries, source_doc, fn entry, doc ->
        new_child_uuid = Map.fetch!(uuid_map, entry.node_id)
        doc = Schema.remove_entry(doc, entry.name)

        case entry.type do
          :dir -> Schema.add_directory(doc, entry.name, new_child_uuid)
          _ -> Schema.add_file(doc, entry.name, new_child_uuid)
        end
      end)

    # Filter __processes.json if present
    edited_doc = maybe_filter_processes(edited_doc, entries, store, uuid_map)

    # Create the schema edit commit branching off the source's chain
    update = Encoding.encode_update(edited_doc)
    CommitStore.create_commit(store, new_uuid, update, commit.id)

    {new_uuid, uuid_map}
  end

  defp fork_leaf_node(source_uuid, store, uuid_map, commit) do
    new_uuid = UUID.uuid4()
    uuid_map = Map.put(uuid_map, source_uuid, new_uuid)

    # Branch-point commit: same content under new UUID, parent = source's commit
    {:ok, doc} = reconstruct_doc(store, source_uuid)
    update = Encoding.encode_update(doc)
    CommitStore.create_commit(store, new_uuid, update, commit.id)

    {new_uuid, uuid_map}
  end

  defp reconstruct_doc(store, doc_uuid) do
    commits = CommitStore.commit_log(store, doc_uuid, limit: 10_000) |> Enum.reverse()
    doc = Doc.new()

    Enum.reduce(commits, {:ok, doc}, fn commit, {:ok, acc} ->
      Encoding.apply_update(acc, commit.update)
    end)
  end

  defp maybe_filter_processes(schema_doc, entries, store, uuid_map) do
    proc_entry = Enum.find(entries, &(&1.name == "__processes.json"))

    if proc_entry do
      new_proc_uuid = Map.get(uuid_map, proc_entry.node_id)

      case reconstruct_doc(store, proc_entry.node_id) do
        {:ok, proc_doc} ->
          content = ContentType.get_content(proc_doc) || "{}"

          case Jason.decode(content) do
            {:ok, json} when is_map(json) ->
              filtered = Config.filter_json_for_fork(json)

              if map_size(filtered) < map_size(json) and new_proc_uuid do
                new_doc = Doc.new()
                new_doc = ContentType.create(new_doc, :text, "__processes.json")
                filtered_json = Jason.encode!(filtered)
                new_doc = if filtered_json != "", do: ContentType.insert_text(new_doc, 0, filtered_json), else: new_doc
                update = Encoding.encode_update(new_doc)
                # Overwrite the branch-point commit with filtered content
                {:ok, branch_commit} = CommitStore.latest_commit(store, new_proc_uuid)
                CommitStore.create_commit(store, new_proc_uuid, update, branch_commit.parent_id)
              end

              schema_doc

            _ ->
              schema_doc
          end

        _ ->
          schema_doc
      end
    else
      schema_doc
    end
  end
end
```

- [ ] **Step 4: Run fork tests**

Run: `cd apps/commonplace && mix test test/commonplace/tree/fork_test.exs --trace`

- [ ] **Step 5: Commit**

```bash
git add apps/commonplace/lib/commonplace/tree/fork.ex apps/commonplace/test/commonplace/tree/fork_test.exs
git commit -m "feat(fork): rewrite as DAG branch model — no deep copy, no ForkManifest (CX-9zu)"
```

---

### Task 3: Rewrite Merge — common ancestor model

Replace the ForkManifest-based merge with common-ancestor merge. Recursive schema merging via name-based child pairing.

**Files:**
- Rewrite: `apps/commonplace/lib/commonplace/tree/merge.ex`
- Rewrite: `apps/commonplace/test/commonplace/tree/merge_test.exs`

- [ ] **Step 1: Write new merge tests**

```elixir
defmodule Commonplace.Tree.MergeTest do
  use ExUnit.Case

  alias Commonplace.Tree.{Merge, Schema, Fork}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_merge_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_merge_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name}
  end

  describe "merge/3" do
    test "merges content edits from source to target", %{store: store} do
      file_uuid = create_text_doc(store, "file.txt", "hello")
      root_uuid = create_schema(store, %{"file.txt" => {:doc, file_uuid}})

      fork_root = Fork.fork_directory(root_uuid, store)
      {fork_file_uuid, _} = get_child(store, fork_root, "file.txt")

      # Edit on fork
      edit_doc(store, fork_file_uuid, " world", 5)

      {:ok, report} = Merge.merge(fork_root, root_uuid, store)

      # Target now has merged content
      {:ok, doc} = reconstruct_doc(store, file_uuid)
      content = ContentType.get_content(doc)
      assert content =~ "hello"
      assert content =~ "world"
      assert report.conflicts == []
    end

    test "merges schema additions", %{store: store} do
      file_uuid = create_text_doc(store, "existing.txt", "existing")
      root_uuid = create_schema(store, %{"existing.txt" => {:doc, file_uuid}})

      fork_root = Fork.fork_directory(root_uuid, store)

      # Add new file on fork
      new_file = create_text_doc(store, "added.txt", "new content")
      add_to_schema(store, fork_root, "added.txt", :doc, new_file)

      {:ok, report} = Merge.merge(fork_root, root_uuid, store)

      # Target schema now has added.txt
      {:ok, target_schema} = reconstruct_schema(store, root_uuid)
      assert {:ok, _} = Schema.get_entry(target_schema, "added.txt")
      assert length(report.new_docs) >= 1
    end

    test "detects name collision — no common ancestor", %{store: store} do
      root_uuid = create_schema(store, %{})

      fork_root = Fork.fork_directory(root_uuid, store)

      # Both branches add "conflict.txt" independently
      source_file = create_text_doc(store, "conflict.txt", "source version")
      add_to_schema(store, fork_root, "conflict.txt", :doc, source_file)

      target_file = create_text_doc(store, "conflict.txt", "target version")
      add_to_schema(store, root_uuid, "conflict.txt", :doc, target_file)

      {:ok, report} = Merge.merge(fork_root, root_uuid, store)

      # Should detect name collision (no common ancestor)
      assert length(report.conflicts) >= 1
    end

    test "empty merge is a no-op", %{store: store} do
      file_uuid = create_text_doc(store, "file.txt", "unchanged")
      root_uuid = create_schema(store, %{"file.txt" => {:doc, file_uuid}})

      fork_root = Fork.fork_directory(root_uuid, store)

      {:ok, report} = Merge.merge(fork_root, root_uuid, store)
      assert report.merged_docs == []
      assert report.new_docs == []
      assert report.conflicts == []
    end

    test "concurrent edits merge via CRDT", %{store: store} do
      file_uuid = create_text_doc(store, "shared.txt", "base")
      root_uuid = create_schema(store, %{"shared.txt" => {:doc, file_uuid}})

      fork_root = Fork.fork_directory(root_uuid, store)
      {fork_file_uuid, _} = get_child(store, fork_root, "shared.txt")

      # Edit on both branches
      edit_doc(store, fork_file_uuid, " SOURCE", 4)
      edit_doc(store, file_uuid, " TARGET", 4)

      {:ok, report} = Merge.merge(fork_root, root_uuid, store)
      assert report.conflicts == []

      {:ok, doc} = reconstruct_doc(store, file_uuid)
      content = ContentType.get_content(doc)
      assert content =~ "SOURCE"
      assert content =~ "TARGET"
    end
  end

  # --- Helpers ---

  defp create_text_doc(store, name, content) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = if content != "", do: ContentType.insert_text(doc, 0, content), else: doc
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
    uuid
  end

  defp create_schema(store, entries) do
    uuid = UUID.uuid4()
    doc = Schema.new_schema()

    doc =
      Enum.reduce(entries, doc, fn {name, {type, node_id}}, doc ->
        case type do
          :doc -> Schema.add_file(doc, name, node_id)
          :dir -> Schema.add_directory(doc, name, node_id)
        end
      end)

    CommitStore.create_commit(store, uuid, Yelixer.Encoding.encode_update(doc), nil)
    uuid
  end

  defp edit_doc(store, uuid, text, position) do
    {:ok, doc} = reconstruct_doc(store, uuid)
    doc = ContentType.insert_text(doc, position, text)
    update = Yelixer.Encoding.encode_update(doc)
    {:ok, latest} = CommitStore.latest_commit(store, uuid)
    CommitStore.create_commit(store, uuid, update, latest.id)
  end

  defp add_to_schema(store, schema_uuid, name, type, node_id) do
    {:ok, doc} = reconstruct_schema(store, schema_uuid)

    doc =
      case type do
        :doc -> Schema.add_file(doc, name, node_id)
        :dir -> Schema.add_directory(doc, name, node_id)
      end

    update = Yelixer.Encoding.encode_update(doc)
    {:ok, latest} = CommitStore.latest_commit(store, schema_uuid)
    CommitStore.create_commit(store, schema_uuid, update, latest.id)
  end

  defp get_child(store, schema_uuid, name) do
    {:ok, schema} = reconstruct_schema(store, schema_uuid)
    {:ok, entry} = Schema.get_entry(schema, name)
    {entry.node_id, entry.type}
  end

  defp reconstruct_doc(store, uuid) do
    commits = CommitStore.commit_log(store, uuid, limit: 10_000) |> Enum.reverse()
    doc = Yelixer.Doc.new()
    Enum.reduce(commits, {:ok, doc}, fn c, {:ok, d} -> Yelixer.Encoding.apply_update(d, c.update) end)
  end

  defp reconstruct_schema(store, uuid) do
    {:ok, commit} = CommitStore.latest_commit(store, uuid)
    schema = Schema.new_schema()
    Yelixer.Encoding.apply_update(schema, commit.update)
  end
end
```

- [ ] **Step 2: Run tests — expect failure**

- [ ] **Step 3: Implement new merge.ex**

The new merge is significantly simpler — no ForkManifest, just DAG walking:

```elixir
defmodule Commonplace.Tree.Merge do
  @moduledoc """
  Merges changes from a source branch into a target branch using DAG ancestry.

  Finds common ancestors in the shared commit DAG, computes CRDT diffs for
  content docs, and structurally diffs schemas with recursive child pairing.
  No ForkManifest — provenance is in the DAG itself.
  """

  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{Schema, Fork}
  alias Commonplace.Document.ContentType
  alias Commonplace.Process.Config
  alias Yelixer.{Doc, Encoding, BlockStore}

  defmodule MergeReport do
    @moduledoc "Result of a merge operation."
    defstruct merged_docs: [], new_docs: [], deleted_docs: [], conflicts: [], errors: []
  end

  @doc """
  Merge changes from source branch into target branch.
  Returns {:ok, merge_report} or {:error, reason}.
  """
  def merge(source_uuid, target_uuid, store) do
    report = %MergeReport{}
    merge_tree(source_uuid, target_uuid, store, report)
  end

  # Recursively merge a tree node (directory or leaf)
  defp merge_tree(source_uuid, target_uuid, store, report) do
    case CommitStore.find_common_ancestor(store, source_uuid, target_uuid) do
      {:ok, ancestor} ->
        # Check if this is a directory (schema) or leaf
        if is_schema?(store, source_uuid) do
          merge_directory(source_uuid, target_uuid, ancestor, store, report)
        else
          merge_leaf(source_uuid, target_uuid, ancestor, store, report)
        end

      :none ->
        # No common ancestor — these docs are unrelated (shouldn't happen for forked docs)
        {:ok, report}
    end
  end

  defp merge_leaf(source_uuid, target_uuid, ancestor, store, report) do
    {:ok, ancestor_doc} = reconstruct_doc_at(store, source_uuid, ancestor.id)
    ancestor_sv = BlockStore.state_vector(ancestor_doc.store)

    {:ok, source_doc} = reconstruct_doc(store, source_uuid)
    diff = Encoding.encode_diff(source_doc, ancestor_sv)

    if byte_size(diff) <= 2 do
      # No changes on source since ancestor
      {:ok, report}
    else
      {:ok, target_doc} = reconstruct_doc(store, target_uuid)
      {:ok, merged_doc} = Encoding.apply_update(target_doc, diff)

      merged_update = Encoding.encode_update(merged_doc)
      {:ok, latest} = CommitStore.latest_commit(store, target_uuid)
      CommitStore.create_commit(store, target_uuid, merged_update, latest.id)

      {:ok, %{report | merged_docs: [{source_uuid, target_uuid} | report.merged_docs]}}
    end
  end

  defp merge_directory(source_uuid, target_uuid, ancestor, store, report) do
    # Load all three schema states
    {:ok, ancestor_schema} = reconstruct_doc_at(store, source_uuid, ancestor.id)
    {:ok, source_schema} = reconstruct_doc(store, source_uuid)
    {:ok, target_schema} = reconstruct_doc(store, target_uuid)

    ancestor_entries = Schema.entries(ancestor_schema)
    source_entries = Schema.entries(source_schema)
    target_entries = Schema.entries(target_schema)

    # Classify entries by name
    all_names = MapSet.union(
      MapSet.new(Map.keys(source_entries)),
      MapSet.new(Map.keys(target_entries))
    )

    {updated_target_schema, report} =
      Enum.reduce(all_names, {target_schema, report}, fn name, {schema, rep} ->
        source_entry = Map.get(source_entries, name)
        target_entry = Map.get(target_entries, name)
        ancestor_entry = Map.get(ancestor_entries, name)

        cond do
          # Present in both source and target
          source_entry != nil and target_entry != nil ->
            source_nid = source_entry["node_id"]
            target_nid = target_entry["node_id"]

            case CommitStore.find_common_ancestor(store, source_nid, target_nid) do
              {:ok, _} ->
                # Shared history — merge recursively
                {:ok, rep} = merge_tree(source_nid, target_nid, store, rep)
                {schema, rep}

              :none ->
                # No common ancestor — name collision
                conflict = {:name_collision, name, source_nid, target_nid}
                {schema, %{rep | conflicts: [conflict | rep.conflicts]}}
            end

          # Only in source — added after fork
          source_entry != nil and target_entry == nil and ancestor_entry == nil ->
            source_nid = source_entry["node_id"]
            type = source_entry["type"]

            # Copy to target: fork the source doc into target's tree
            new_uuid = fork_into_target(source_nid, type, store)

            schema =
              case type do
                "dir" -> Schema.add_directory(schema, name, new_uuid)
                _ -> Schema.add_file(schema, name, new_uuid)
              end

            {schema, %{rep | new_docs: [{source_nid, new_uuid} | rep.new_docs]}}

          # Only in target — added on target after fork, leave it
          source_entry == nil and target_entry != nil and ancestor_entry == nil ->
            {schema, rep}

          # Removed on source (was in ancestor, not in source, still in target)
          source_entry == nil and target_entry != nil and ancestor_entry != nil ->
            target_nid = target_entry["node_id"]

            # Check for delete-vs-modify conflict
            case CommitStore.find_common_ancestor(store, target_nid, target_nid) do
              {:ok, _} ->
                # Check if target modified since ancestor
                {:ok, ancestor_target_commit} = CommitStore.latest_commit(store, target_nid)
                ancestor_nid = ancestor_entry["node_id"]

                if target_nid == ancestor_nid and not modified_since_ancestor?(store, target_nid, ancestor_nid) do
                  schema = Schema.remove_entry(schema, name)
                  {schema, %{rep | deleted_docs: [target_nid | rep.deleted_docs]}}
                else
                  conflict = {:delete_vs_modify, name, target_nid}
                  {schema, %{rep | conflicts: [conflict | rep.conflicts]}}
                end

              :none ->
                {schema, rep}
            end

          # Removed on target (was in ancestor, in source, not in target)
          source_entry != nil and target_entry == nil and ancestor_entry != nil ->
            # Target deleted it — leave deleted
            {schema, rep}

          # Other cases (shouldn't normally occur)
          true ->
            {schema, rep}
        end
      end)

    # Commit updated target schema
    schema_update = Encoding.encode_update(updated_target_schema)
    {:ok, target_latest} = CommitStore.latest_commit(store, target_uuid)
    CommitStore.create_commit(store, target_uuid, schema_update, target_latest.id)

    # Filter processes if needed
    maybe_filter_processes(store, target_uuid)

    {:ok, report}
  end

  defp fork_into_target(source_uuid, _type, store) do
    # Use the new Fork to create a DAG branch
    Fork.fork_directory(source_uuid, store)
  end

  defp modified_since_ancestor?(store, target_uuid, ancestor_uuid) do
    case CommitStore.find_common_ancestor(store, target_uuid, ancestor_uuid) do
      {:ok, ancestor} ->
        {:ok, latest} = CommitStore.latest_commit(store, target_uuid)
        latest.id != ancestor.id

      :none ->
        true
    end
  end

  defp is_schema?(store, uuid) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        schema = Schema.new_schema()
        case Encoding.apply_update(schema, commit.update) do
          {:ok, doc} -> length(Schema.list_entries(doc)) > 0
          _ -> false
        end
      :none -> false
    end
  end

  defp reconstruct_doc(store, uuid) do
    commits = CommitStore.commit_log(store, uuid, limit: 10_000) |> Enum.reverse()
    doc = Doc.new()
    Enum.reduce(commits, {:ok, doc}, fn c, {:ok, d} -> Encoding.apply_update(d, c.update) end)
  end

  defp reconstruct_doc_at(store, uuid, target_commit_id) do
    commits = CommitStore.commit_log(store, uuid, limit: 10_000) |> Enum.reverse()

    result =
      Enum.reduce_while(commits, {:not_found, []}, fn commit, {_status, acc} ->
        if commit.id == target_commit_id do
          {:halt, {:found, Enum.reverse([commit | acc])}}
        else
          {:cont, {:not_found, [commit | acc]}}
        end
      end)

    case result do
      {:found, to_apply} ->
        doc = Doc.new()
        Enum.reduce(to_apply, {:ok, doc}, fn c, {:ok, d} -> Encoding.apply_update(d, c.update) end)

      {:not_found, _} ->
        :none
    end
  end

  defp maybe_filter_processes(store, schema_uuid) do
    {:ok, schema} = reconstruct_doc(store, schema_uuid)

    case Schema.get_entry(schema, "__processes.json") do
      {:ok, entry} ->
        case reconstruct_doc(store, entry.node_id) do
          {:ok, proc_doc} ->
            content = ContentType.get_content(proc_doc) || "{}"

            case Jason.decode(content) do
              {:ok, proc_json} ->
                filtered = Config.filter_json_for_fork(proc_json)

                if filtered != proc_json do
                  new_doc = Doc.new()
                  new_doc = ContentType.create(new_doc, :text, "__processes.json")
                  new_doc = ContentType.insert_text(new_doc, 0, Jason.encode!(filtered))
                  update = Encoding.encode_update(new_doc)
                  {:ok, latest} = CommitStore.latest_commit(store, entry.node_id)
                  CommitStore.create_commit(store, entry.node_id, update, latest.id)
                end

              _ -> :ok
            end

          _ -> :ok
        end

      :error -> :ok
    end
  end
end
```

- [ ] **Step 4: Run merge tests**

Run: `cd apps/commonplace && mix test test/commonplace/tree/merge_test.exs --trace`

- [ ] **Step 5: Run all tests (fork + merge + full suite)**

Run: `cd apps/commonplace && mix test --trace`

- [ ] **Step 6: Commit**

```bash
git add apps/commonplace/lib/commonplace/tree/merge.ex apps/commonplace/test/commonplace/tree/merge_test.exs
git commit -m "feat(merge): rewrite using common-ancestor DAG merge — no ForkManifest (CX-9zu)"
```

---

### Task 4: Clean up — remove ForkManifest, update CLI

Remove ForkManifest module, update CLI fork command, mark old merge design doc as superseded.

**Files:**
- Delete: `apps/commonplace/lib/commonplace/tree/fork_manifest.ex`
- Delete: `apps/commonplace/test/commonplace/tree/fork_manifest_test.exs`
- Modify: `apps/commonplace_cli/lib/commonplace/cli/fork.ex`
- Modify: `docs/plans/2026-03-23-branch-merge-design.md`

- [ ] **Step 1: Delete ForkManifest files**

```bash
rm apps/commonplace/lib/commonplace/tree/fork_manifest.ex
rm apps/commonplace/test/commonplace/tree/fork_manifest_test.exs
```

- [ ] **Step 2: Update CLI fork command**

Replace manifest output with simple UUID output:

```elixir
# In apps/commonplace_cli/lib/commonplace/cli/fork.ex, update the success output:
# Remove manifest references, just print the new UUID
IO.puts("Forking #{path} (#{source_uuid})...")
IO.puts("Created fork: #{new_uuid}")
```

Read the current file and make minimal changes to remove manifest references.

- [ ] **Step 3: Mark old design doc as superseded**

Add a note at the top of `docs/plans/2026-03-23-branch-merge-design.md`:

```markdown
> **SUPERSEDED** by `docs/superpowers/specs/2026-03-23-fork-as-dag-branch-design.md` (CX-9zu).
> This design used ForkManifest-based provenance. The new design uses shared commit DAG branches.
```

- [ ] **Step 4: Verify no remaining references to ForkManifest**

```bash
rg "ForkManifest|fork_manifest" apps/commonplace/lib apps/commonplace/test apps/commonplace_cli
```

Should return nothing.

- [ ] **Step 5: Run full test suite**

Run: `cd apps/commonplace && mix test`
Expected: all pass, no compilation errors from missing ForkManifest

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: remove ForkManifest, update CLI fork output, mark old design as superseded (CX-9zu)"
```

---

### Task 5: Integration tests + merge point storage

Add end-to-end integration tests: fork → edit → merge → edit again → merge again (incremental). Add merge point storage for incremental merges.

**Files:**
- Modify: `apps/commonplace/lib/commonplace/store/commit_store.ex`
- Modify: `apps/commonplace/lib/commonplace/tree/merge.ex`
- Modify: `apps/commonplace/test/commonplace/tree/merge_test.exs`

- [ ] **Step 1: Add merge point storage to CommitStore**

```elixir
# Add to commit_store.ex:
def set_merge_point(server \\ __MODULE__, target_uuid, source_uuid, commit_id) do
  GenServer.call(server, {:set_merge_point, target_uuid, source_uuid, commit_id})
end

def get_merge_point(server \\ __MODULE__, target_uuid, source_uuid) do
  GenServer.call(server, {:get_merge_point, target_uuid, source_uuid})
end

# handle_call clauses:
def handle_call({:set_merge_point, target_uuid, source_uuid, commit_id}, _from, state) do
  CubDB.put(state.db, {:merge_point, target_uuid, source_uuid}, commit_id)
  {:reply, :ok, state}
end

def handle_call({:get_merge_point, target_uuid, source_uuid}, _from, state) do
  result = CubDB.get(state.db, {:merge_point, target_uuid, source_uuid})
  {:reply, result, state}
end
```

- [ ] **Step 2: Update merge to use and set merge points**

In `merge/3`, after successful merge, call `CommitStore.set_merge_point`. Before merge, check for existing merge point and use it as diff baseline instead of walking to common ancestor.

- [ ] **Step 3: Write incremental merge test**

```elixir
test "repeated merge only applies new changes", %{store: store} do
  file_uuid = create_text_doc(store, "file.txt", "v1")
  root_uuid = create_schema(store, %{"file.txt" => {:doc, file_uuid}})

  fork_root = Fork.fork_directory(root_uuid, store)
  {fork_file, _} = get_child(store, fork_root, "file.txt")

  # First edit + merge
  edit_doc(store, fork_file, " edit1", 2)
  {:ok, _} = Merge.merge(fork_root, root_uuid, store)

  {:ok, doc1} = reconstruct_doc(store, file_uuid)
  assert ContentType.get_content(doc1) =~ "edit1"

  # Second edit + merge (should only apply new changes)
  edit_doc(store, fork_file, "NEW ", 0)
  {:ok, _} = Merge.merge(fork_root, root_uuid, store)

  {:ok, doc2} = reconstruct_doc(store, file_uuid)
  content = ContentType.get_content(doc2)
  assert content =~ "NEW"
  assert content =~ "edit1"
end
```

- [ ] **Step 4: Run all tests**

Run: `cd apps/commonplace && mix test --trace`

- [ ] **Step 5: Commit**

```bash
git add apps/commonplace/lib/commonplace/store/commit_store.ex apps/commonplace/lib/commonplace/tree/merge.ex apps/commonplace/test/commonplace/tree/merge_test.exs
git commit -m "feat(merge): add merge point storage for incremental merges (CX-9zu)"
```

---

### Task 6: Final verification + close issue

Run full suite, push, close CX-9zu and resolved follow-up issues.

- [ ] **Step 1: Run full test suite**

Run: `cd apps/commonplace && mix test --trace`

- [ ] **Step 2: Close resolved issues**

```bash
bd close CX-9zu --reason="Fork rewritten as DAG branches, merge uses common ancestor, ForkManifest eliminated"
bd close CX-spp --reason="Resolved by CX-9zu — recursive merge via name-based child pairing"
bd close CX-o3i --reason="Resolved by CX-9zu — common ancestor is unambiguous in shared DAG"
```

- [ ] **Step 3: Push and update design doc**

```bash
git push
```
