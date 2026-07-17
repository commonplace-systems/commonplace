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
      if Process.alive?(store_a), do: (try do GenServer.stop(store_a) catch (:exit, _ -> :ok) end)
      if Process.alive?(store_b), do: (try do GenServer.stop(store_b) catch (:exit, _ -> :ok) end)
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

    # Post-CX-m3x: store_a also has the deterministic genesis stamped
    # on the fresh-doc chain, so 2 user commits + 1 genesis = 3.
    assert MapSet.size(missing_b) == 3
    assert MapSet.size(missing_a) == 0

    # Manually transfer missing commits (simulating catch_up without remote nodes)
    Enum.each(missing_b, fn id ->
      {:ok, commit} = CommitStore.get_commit(store_a, id)
      CommitStore.import_commit(store_b, commit)
    end)

    # Verify store B now has both commits stored (accessible individually)
    {:ok, _} = CommitStore.get_commit(store_b, c1.id)
    {:ok, _} = CommitStore.get_commit(store_b, c2.id)
  end

  test "bidirectional sync merges divergent histories", %{store_a: store_a, store_b: store_b} do
    uuid = UUID.uuid4()

    # Create shared base in both (same update + same parent_id = same commit ID)
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

  test "import_commit does not clobber latest pointer", %{store_a: store_a, store_b: store_b} do
    uuid = UUID.uuid4()

    # Store A has a commit chain
    c1 = CommitStore.create_commit(store_a, uuid, "first", nil)
    c2 = CommitStore.create_commit(store_a, uuid, "second", c1.id)

    # Store B has its own chain for same UUID
    b1 = CommitStore.create_commit(store_b, uuid, "b_first", nil)
    b2 = CommitStore.create_commit(store_b, uuid, "b_second", b1.id)

    # Import A's commits into B — should NOT change B's latest
    {:ok, a_commit1} = CommitStore.get_commit(store_a, c1.id)
    {:ok, a_commit2} = CommitStore.get_commit(store_a, c2.id)
    CommitStore.import_commit(store_b, a_commit1)
    CommitStore.import_commit(store_b, a_commit2)

    # B's latest should still be b2
    {:ok, latest} = CommitStore.latest_commit(store_b, uuid)
    assert latest.id == b2.id

    # But B should now have all 4 commits accessible by ID
    {:ok, _} = CommitStore.get_commit(store_b, c1.id)
    {:ok, _} = CommitStore.get_commit(store_b, c2.id)
    {:ok, _} = CommitStore.get_commit(store_b, b1.id)
    {:ok, _} = CommitStore.get_commit(store_b, b2.id)

    # commit_ids_for_doc walks from latest, so it only finds b1, b2
    # The imported commits are stored but not reachable from latest
    # This is expected — they'll be reachable after merge
    ids = CommitStore.commit_ids_for_doc(store_b, uuid)
    assert MapSet.member?(ids, b1.id)
    assert MapSet.member?(ids, b2.id)
  end

  test "bidirectional sync: each node has a different doc", %{store_a: store_a, store_b: store_b} do
    uuid_x = UUID.uuid4()
    uuid_y = UUID.uuid4()

    # Node A has doc X
    cx1 = CommitStore.create_commit(store_a, uuid_x, "x_update_1", nil)
    cx2 = CommitStore.create_commit(store_a, uuid_x, "x_update_2", cx1.id)

    # Node B has doc Y
    cy1 = CommitStore.create_commit(store_b, uuid_y, "y_update_1", nil)
    cy2 = CommitStore.create_commit(store_b, uuid_y, "y_update_2", cy1.id)

    # Verify initial isolation
    assert CommitStore.commit_ids_for_doc(store_a, uuid_y) == MapSet.new()
    assert CommitStore.commit_ids_for_doc(store_b, uuid_x) == MapSet.new()

    # Sync doc X: A -> B
    ids_a_x = CommitStore.commit_ids_for_doc(store_a, uuid_x)
    ids_b_x = CommitStore.commit_ids_for_doc(store_b, uuid_x)
    {missing_b_x, _missing_a_x} = NodeSync.diff_commit_ids(ids_b_x, ids_a_x)

    Enum.each(missing_b_x, fn id ->
      {:ok, commit} = CommitStore.get_commit(store_a, id)
      CommitStore.import_commit(store_b, commit)
    end)

    # Sync doc Y: B -> A
    ids_a_y = CommitStore.commit_ids_for_doc(store_a, uuid_y)
    ids_b_y = CommitStore.commit_ids_for_doc(store_b, uuid_y)
    {missing_a_y, _missing_b_y} = NodeSync.diff_commit_ids(ids_a_y, ids_b_y)

    Enum.each(missing_a_y, fn id ->
      {:ok, commit} = CommitStore.get_commit(store_b, id)
      CommitStore.import_commit(store_a, commit)
    end)

    # Both stores should now have both docs accessible by ID
    {:ok, _} = CommitStore.get_commit(store_a, cy1.id)
    {:ok, _} = CommitStore.get_commit(store_a, cy2.id)
    {:ok, _} = CommitStore.get_commit(store_b, cx1.id)
    {:ok, _} = CommitStore.get_commit(store_b, cx2.id)

    # Since these docs didn't exist on the receiving side before import,
    # import_commit should have set :latest for them
    {:ok, latest_x_on_b} = CommitStore.latest_commit(store_b, uuid_x)
    {:ok, latest_y_on_a} = CommitStore.latest_commit(store_a, uuid_y)

    # The latest should be whichever commit was imported first (when no prior
    # :latest exists, import_commit sets it). Since import order isn't guaranteed
    # from MapSet iteration, just verify a latest exists and is one of the commits
    # imported from the source chain (including the deterministic genesis
    # that CX-m3x auto-stamps for every fresh doc).
    genesis_x_id = Commonplace.Store.Commit.genesis(uuid_x).id
    genesis_y_id = Commonplace.Store.Commit.genesis(uuid_y).id
    assert latest_x_on_b.id in [cx1.id, cx2.id, genesis_x_id]
    assert latest_y_on_a.id in [cy1.id, cy2.id, genesis_y_id]
  end

  test "concurrent edits to same doc: bidirectional import gets all commits", %{
    store_a: store_a,
    store_b: store_b
  } do
    uuid = UUID.uuid4()

    # Shared base commit (same update + same parent = same content-addressed ID)
    base_a = CommitStore.create_commit(store_a, uuid, "base", nil)
    base_b = CommitStore.create_commit(store_b, uuid, "base", nil)
    assert base_a.id == base_b.id

    # Diverge: A extends with 2 commits, B extends with 2 commits
    a1 = CommitStore.create_commit(store_a, uuid, "a_edit_1", base_a.id)
    a2 = CommitStore.create_commit(store_a, uuid, "a_edit_2", a1.id)

    b1 = CommitStore.create_commit(store_b, uuid, "b_edit_1", base_b.id)
    b2 = CommitStore.create_commit(store_b, uuid, "b_edit_2", b1.id)

    # Diff
    ids_a = CommitStore.commit_ids_for_doc(store_a, uuid)
    ids_b = CommitStore.commit_ids_for_doc(store_b, uuid)

    # Post-CX-m3x: the chains also include the deterministic genesis
    # stamped on the fresh doc — 3 user commits + 1 genesis = 4.
    assert MapSet.size(ids_a) == 4  # genesis, base, a1, a2
    assert MapSet.size(ids_b) == 4  # genesis, base, b1, b2

    {missing_a, missing_b} = NodeSync.diff_commit_ids(ids_a, ids_b)

    # Each side is missing the other's 2 divergent commits
    assert MapSet.size(missing_a) == 2
    assert MapSet.size(missing_b) == 2

    # Bidirectional import
    Enum.each(missing_a, fn id ->
      {:ok, commit} = CommitStore.get_commit(store_b, id)
      CommitStore.import_commit(store_a, commit)
    end)

    Enum.each(missing_b, fn id ->
      {:ok, commit} = CommitStore.get_commit(store_a, id)
      CommitStore.import_commit(store_b, commit)
    end)

    # Both stores should now have all 5 distinct commits accessible by ID
    for id <- [base_a.id, a1.id, a2.id, b1.id, b2.id] do
      {:ok, _} = CommitStore.get_commit(store_a, id)
      {:ok, _} = CommitStore.get_commit(store_b, id)
    end

    # Latest pointers should be unchanged (each store keeps its own head)
    {:ok, latest_a} = CommitStore.latest_commit(store_a, uuid)
    {:ok, latest_b} = CommitStore.latest_commit(store_b, uuid)
    assert latest_a.id == a2.id
    assert latest_b.id == b2.id
  end

  test "multiple commits chain: 5 commits sync correctly", %{store_a: store_a, store_b: store_b} do
    uuid = UUID.uuid4()

    # Create a chain of 5 commits on store A
    commits =
      Enum.reduce(1..5, [], fn i, acc ->
        parent_id = if acc == [], do: nil, else: hd(acc).id
        commit = CommitStore.create_commit(store_a, uuid, "update_#{i}", parent_id)
        [commit | acc]
      end)

    # commits is in reverse order: [c5, c4, c3, c2, c1]
    commits = Enum.reverse(commits)
    [c1, c2, c3, c4, c5] = commits

    # Verify chain structure
    # Post-CX-m3x: the root commit parents to the deterministic genesis.
    assert c1.parent_id == Commonplace.Store.Commit.genesis(uuid).id
    assert c2.parent_id == c1.id
    assert c3.parent_id == c2.id
    assert c4.parent_id == c3.id
    assert c5.parent_id == c4.id

    # Verify store A has all 5 + the deterministic genesis auto-stamped
    # on the fresh-doc chain (CX-m3x).
    ids_a = CommitStore.commit_ids_for_doc(store_a, uuid)
    assert MapSet.size(ids_a) == 6

    # Sync all to store B
    Enum.each(ids_a, fn id ->
      {:ok, commit} = CommitStore.get_commit(store_a, id)
      CommitStore.import_commit(store_b, commit)
    end)

    # All 5 should be retrievable from store B
    for c <- commits do
      {:ok, fetched} = CommitStore.get_commit(store_b, c.id)
      assert fetched.doc_uuid == uuid
      assert fetched.parent_id == c.parent_id
      assert fetched.update == c.update
    end

    # Since store B had no prior :latest for this UUID, import_commit should
    # have set :latest to whichever commit was imported first.
    {:ok, latest_b} = CommitStore.latest_commit(store_b, uuid)
    # The latest might not be c5 (depends on import order from MapSet).
    # But it should be one of our commits OR the auto-stamped genesis
    # that's now part of the chain (CX-m3x).
    genesis_id = Commonplace.Store.Commit.genesis(uuid).id
    assert latest_b.id in [genesis_id | Enum.map(commits, & &1.id)]
  end

  test "import_commit idempotency: second import returns :already_exists", %{
    store_a: store_a,
    store_b: store_b
  } do
    uuid = UUID.uuid4()

    c1 = CommitStore.create_commit(store_a, uuid, "data", nil)

    {:ok, commit} = CommitStore.get_commit(store_a, c1.id)

    # First import should succeed
    result1 = CommitStore.import_commit(store_b, commit)
    assert result1 == :ok

    # Second import of the same commit should return :already_exists
    result2 = CommitStore.import_commit(store_b, commit)
    assert result2 == :already_exists

    # Store should still have exactly the one commit, unchanged
    {:ok, stored} = CommitStore.get_commit(store_b, c1.id)
    assert stored.id == commit.id
    assert stored.doc_uuid == commit.doc_uuid
    assert stored.update == commit.update
    assert stored.parent_id == commit.parent_id

    # Latest should still point to this commit (was set on first import since
    # no prior :latest existed)
    {:ok, latest} = CommitStore.latest_commit(store_b, uuid)
    assert latest.id == c1.id
  end

  test "import_commit preserves existing latest pointer", %{store_a: store_a, store_b: store_b} do
    uuid = UUID.uuid4()

    # Store A: chain c1 -> c2 -> c3
    c1 = CommitStore.create_commit(store_a, uuid, "a_first", nil)
    c2 = CommitStore.create_commit(store_a, uuid, "a_second", c1.id)
    c3 = CommitStore.create_commit(store_a, uuid, "a_third", c2.id)

    # Store B: independent chain b1 -> b2 for the SAME doc UUID
    b1 = CommitStore.create_commit(store_b, uuid, "b_first", nil)
    b2 = CommitStore.create_commit(store_b, uuid, "b_second", b1.id)

    # Verify B's latest is b2
    {:ok, latest_before} = CommitStore.latest_commit(store_b, uuid)
    assert latest_before.id == b2.id

    # Import all of A's commits into B
    for commit_id <- [c1.id, c2.id, c3.id] do
      {:ok, commit} = CommitStore.get_commit(store_a, commit_id)
      CommitStore.import_commit(store_b, commit)
    end

    # B's latest should STILL be b2, not c3
    {:ok, latest_after} = CommitStore.latest_commit(store_b, uuid)
    assert latest_after.id == b2.id

    # But all of A's commits should be stored and retrievable by ID
    {:ok, fetched_c1} = CommitStore.get_commit(store_b, c1.id)
    {:ok, fetched_c2} = CommitStore.get_commit(store_b, c2.id)
    {:ok, fetched_c3} = CommitStore.get_commit(store_b, c3.id)

    assert fetched_c1.update == "a_first"
    assert fetched_c2.update == "a_second"
    assert fetched_c3.update == "a_third"

    # commit_ids_for_doc walks from :latest (b2) through parents to root.
    # Post-CX-m3x: that walk now includes the deterministic genesis stamped
    # on b1's creation, so b1, b2, and genesis are all in the set.
    ids = CommitStore.commit_ids_for_doc(store_b, uuid)
    assert MapSet.size(ids) == 3
    assert MapSet.member?(ids, b1.id)
    assert MapSet.member?(ids, b2.id)
    assert MapSet.member?(ids, Commonplace.Store.Commit.genesis(uuid).id)
    refute MapSet.member?(ids, c1.id)
    refute MapSet.member?(ids, c2.id)
    refute MapSet.member?(ids, c3.id)
  end

  test "empty doc sync: UUID exists on neither node", %{store_a: store_a, store_b: store_b} do
    uuid = UUID.uuid4()

    # Neither store has this UUID
    assert CommitStore.commit_ids_for_doc(store_a, uuid) == MapSet.new()
    assert CommitStore.commit_ids_for_doc(store_b, uuid) == MapSet.new()

    # Diff should show nothing missing on either side
    ids_a = CommitStore.commit_ids_for_doc(store_a, uuid)
    ids_b = CommitStore.commit_ids_for_doc(store_b, uuid)
    {missing_a, missing_b} = NodeSync.diff_commit_ids(ids_a, ids_b)

    assert MapSet.size(missing_a) == 0
    assert MapSet.size(missing_b) == 0

    # Simulating catch-up manually: no commits to transfer
    fetched =
      missing_a
      |> Enum.map(fn id -> CommitStore.get_commit(store_b, id) end)
      |> Enum.filter(&match?({:ok, _}, &1))

    sent =
      missing_b
      |> Enum.map(fn id -> CommitStore.get_commit(store_a, id) end)
      |> Enum.filter(&match?({:ok, _}, &1))

    assert length(fetched) == 0
    assert length(sent) == 0

    # Both stores should still have no data for this UUID
    assert CommitStore.latest_commit(store_a, uuid) == :none
    assert CommitStore.latest_commit(store_b, uuid) == :none
  end
end
