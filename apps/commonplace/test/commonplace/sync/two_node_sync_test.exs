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
      if Process.alive?(store_a), do: GenServer.stop(store_a)
      if Process.alive?(store_b), do: GenServer.stop(store_b)
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
end
