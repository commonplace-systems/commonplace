defmodule Commonplace.Store.AncestryTest do
  @moduledoc """
  Tests for commit DAG ancestry checks.
  """
  use ExUnit.Case

  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_ancestry_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name}
  end

  describe "is_ancestor?" do
    test "a commit is an ancestor of its child", %{store: store} do
      c1 = CommitStore.create_commit(store, "doc1", "update1", nil)
      c2 = CommitStore.create_commit(store, "doc1", "update2", c1.id)

      assert CommitStore.is_ancestor?(store, c1.id, c2.id) == true
    end

    test "a commit is an ancestor of its grandchild", %{store: store} do
      c1 = CommitStore.create_commit(store, "doc1", "update1", nil)
      c2 = CommitStore.create_commit(store, "doc1", "update2", c1.id)
      c3 = CommitStore.create_commit(store, "doc1", "update3", c2.id)

      assert CommitStore.is_ancestor?(store, c1.id, c3.id) == true
    end

    test "a commit is not an ancestor of an unrelated commit", %{store: store} do
      c1 = CommitStore.create_commit(store, "doc1", "update1", nil)
      c2 = CommitStore.create_commit(store, "doc2", "update2", nil)

      assert CommitStore.is_ancestor?(store, c1.id, c2.id) == false
    end

    test "a commit is not its own ancestor", %{store: store} do
      c1 = CommitStore.create_commit(store, "doc1", "update1", nil)

      assert CommitStore.is_ancestor?(store, c1.id, c1.id) == false
    end

    test "nil is not an ancestor of anything", %{store: store} do
      c1 = CommitStore.create_commit(store, "doc1", "update1", nil)

      assert CommitStore.is_ancestor?(store, nil, c1.id) == false
    end

    test "handles deep chains", %{store: store} do
      commits =
        Enum.reduce(1..20, [], fn i, acc ->
          parent = if acc == [], do: nil, else: hd(acc).id
          c = CommitStore.create_commit(store, "doc1", "update#{i}", parent)
          [c | acc]
        end)

      first = List.last(commits)
      last = hd(commits)

      assert CommitStore.is_ancestor?(store, first.id, last.id) == true
      assert CommitStore.is_ancestor?(store, last.id, first.id) == false
    end
  end
end
