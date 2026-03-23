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
      commit_a = CommitStore.create_commit(store, "uuid-a", "update-1", nil)
      :ok = CommitStore.set_latest(store, "uuid-b", commit_a.id)
      {:ok, latest_b} = CommitStore.latest_commit(store, "uuid-b")
      assert latest_b.id == commit_a.id
    end

    test "new UUID can have its own commits after set_latest", %{store: store} do
      commit_a1 = CommitStore.create_commit(store, "uuid-a", "update-1", nil)
      :ok = CommitStore.set_latest(store, "uuid-b", commit_a1.id)
      commit_b1 = CommitStore.create_commit(store, "uuid-b", "update-b", commit_a1.id)
      {:ok, latest_a} = CommitStore.latest_commit(store, "uuid-a")
      assert latest_a.id == commit_a1.id
      {:ok, latest_b} = CommitStore.latest_commit(store, "uuid-b")
      assert latest_b.id == commit_b1.id
      log = CommitStore.commit_log(store, "uuid-b")
      assert length(log) == 2
    end
  end

  describe "find_common_ancestor/4" do
    test "finds common ancestor of branched chains", %{store: store} do
      c1 = CommitStore.create_commit(store, "uuid-a", "base", nil)
      c2 = CommitStore.create_commit(store, "uuid-a", "shared", c1.id)
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
