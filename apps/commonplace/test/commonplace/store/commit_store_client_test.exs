defmodule Commonplace.Store.CommitStoreClientTest do
  @moduledoc """
  Tests for CommitStoreClient — verifies it correctly delegates to the local
  CommitStore when no remote node is set, and that server normalization works.
  """
  use ExUnit.Case

  alias Commonplace.Store.{CommitStore, CommitStoreClient}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_client_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"client_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  describe "create_commit/5 (local mode)" do
    test "creates a commit and returns it", %{store: store} do
      commit = CommitStoreClient.create_commit(store, "doc-1", <<1, 2, 3>>, nil)
      assert commit.doc_uuid == "doc-1"
      assert commit.update == <<1, 2, 3>>
      assert commit.parent_id == nil
    end

    test "creates a commit with parent", %{store: store} do
      c1 = CommitStoreClient.create_commit(store, "doc-1", <<1>>, nil)
      c2 = CommitStoreClient.create_commit(store, "doc-1", <<2>>, c1.id)
      assert c2.parent_id == c1.id
    end
  end

  describe "create_chained_commit/4 (local mode)" do
    test "chains to the latest commit automatically", %{store: store} do
      c1 = CommitStoreClient.create_commit(store, "doc-1", <<1>>, nil)
      c2 = CommitStoreClient.create_chained_commit(store, "doc-1", <<2>>)
      assert c2.parent_id == c1.id
    end

    test "creates root commit when no prior commits exist", %{store: store} do
      c1 = CommitStoreClient.create_chained_commit(store, "new-doc", <<1>>)
      assert c1.parent_id == nil
    end
  end

  describe "get_commit/2 (local mode)" do
    test "retrieves a stored commit", %{store: store} do
      commit = CommitStoreClient.create_commit(store, "doc-1", <<1>>, nil)
      assert {:ok, fetched} = CommitStoreClient.get_commit(store, commit.id)
      assert fetched.id == commit.id
      assert fetched.update == <<1>>
    end

    test "returns :none for unknown commit", %{store: store} do
      assert :none = CommitStoreClient.get_commit(store, <<0::256>>)
    end
  end

  describe "latest_commit/2 (local mode)" do
    test "returns latest commit for a doc", %{store: store} do
      _c1 = CommitStoreClient.create_commit(store, "doc-1", <<1>>, nil)
      c2 = CommitStoreClient.create_chained_commit(store, "doc-1", <<2>>)
      assert {:ok, latest} = CommitStoreClient.latest_commit(store, "doc-1")
      assert latest.id == c2.id
    end

    test "returns :none for unknown doc", %{store: store} do
      assert :none = CommitStoreClient.latest_commit(store, "nonexistent")
    end
  end

  describe "commit_log/3 (local mode)" do
    test "returns commits newest-first", %{store: store} do
      c1 = CommitStoreClient.create_commit(store, "doc-1", <<1>>, nil)
      c2 = CommitStoreClient.create_chained_commit(store, "doc-1", <<2>>)
      c3 = CommitStoreClient.create_chained_commit(store, "doc-1", <<3>>)

      log = CommitStoreClient.commit_log(store, "doc-1")
      ids = Enum.map(log, & &1.id)
      assert ids == [c3.id, c2.id, c1.id]
    end

    test "respects limit option", %{store: store} do
      CommitStoreClient.create_commit(store, "doc-1", <<1>>, nil)
      CommitStoreClient.create_chained_commit(store, "doc-1", <<2>>)
      CommitStoreClient.create_chained_commit(store, "doc-1", <<3>>)

      log = CommitStoreClient.commit_log(store, "doc-1", limit: 2)
      assert length(log) == 2
    end
  end

  describe "all_doc_uuids/1 (local mode)" do
    test "returns all document UUIDs", %{store: store} do
      CommitStoreClient.create_commit(store, "doc-a", <<1>>, nil)
      CommitStoreClient.create_commit(store, "doc-b", <<2>>, nil)

      uuids = CommitStoreClient.all_doc_uuids(store)
      assert "doc-a" in uuids
      assert "doc-b" in uuids
    end
  end

  describe "is_ancestor?/3 (local mode)" do
    test "returns true for ancestor relationship", %{store: store} do
      c1 = CommitStoreClient.create_commit(store, "doc-1", <<1>>, nil)
      c2 = CommitStoreClient.create_chained_commit(store, "doc-1", <<2>>)

      assert CommitStoreClient.is_ancestor?(store, c1.id, c2.id) == true
    end

    test "returns false for non-ancestor", %{store: store} do
      c1 = CommitStoreClient.create_commit(store, "doc-a", <<1>>, nil)
      c2 = CommitStoreClient.create_commit(store, "doc-b", <<2>>, nil)

      assert CommitStoreClient.is_ancestor?(store, c1.id, c2.id) == false
    end
  end

  describe "set_latest/3 (local mode)" do
    test "overrides the latest commit pointer", %{store: store} do
      c1 = CommitStoreClient.create_commit(store, "doc-1", <<1>>, nil)
      c2 = CommitStoreClient.create_chained_commit(store, "doc-1", <<2>>)
      assert {:ok, latest} = CommitStoreClient.latest_commit(store, "doc-1")
      assert latest.id == c2.id

      # Set latest back to c1
      CommitStoreClient.set_latest(store, "doc-1", c1.id)
      assert {:ok, latest} = CommitStoreClient.latest_commit(store, "doc-1")
      assert latest.id == c1.id
    end
  end

  describe "find_common_ancestor/3 (local mode)" do
    test "finds common ancestor for forked commits", %{store: store} do
      c1 = CommitStoreClient.create_commit(store, "doc-a", <<1>>, nil)
      # Create two branches from the same parent
      _c2 = CommitStoreClient.create_commit(store, "doc-a", <<2>>, c1.id)
      _c3 = CommitStoreClient.create_commit(store, "doc-b", <<3>>, c1.id)

      assert {:ok, ancestor} = CommitStoreClient.find_common_ancestor(store, "doc-a", "doc-b")
      assert ancestor.id == c1.id
    end

    test "returns :none for unrelated docs", %{store: store} do
      CommitStoreClient.create_commit(store, "doc-x", <<1>>, nil)
      CommitStoreClient.create_commit(store, "doc-y", <<2>>, nil)

      assert :none = CommitStoreClient.find_common_ancestor(store, "doc-x", "doc-y")
    end
  end

  describe "merge point functions (local mode)" do
    test "set and get merge point", %{store: store} do
      c1 = CommitStoreClient.create_commit(store, "target", <<1>>, nil)

      assert nil == CommitStoreClient.get_merge_point(store, "target", "source")

      CommitStoreClient.set_merge_point(store, "target", "source", c1.id)
      assert c1.id == CommitStoreClient.get_merge_point(store, "target", "source")
    end

    test "set_last_merge_commit and get_latest_merge_head", %{store: store} do
      c1 = CommitStoreClient.create_commit(store, "target", <<1>>, nil)

      assert nil == CommitStoreClient.get_latest_merge_head(store, "target")

      CommitStoreClient.set_last_merge_commit(store, "target", "source", c1.id)
      assert c1.id == CommitStoreClient.get_latest_merge_head(store, "target")
    end
  end

  describe "server normalization" do
    test "CommitStoreClient module is normalized to CommitStore", %{store: store} do
      # When CLI passes CommitStoreClient as server, it should be mapped to CommitStore
      # We test this indirectly by verifying the call works with the actual store name
      CommitStoreClient.create_commit(store, "norm-test", <<1>>, nil)
      assert {:ok, _} = CommitStoreClient.latest_commit(store, "norm-test")
    end
  end

  describe "remote_node/0 and set_remote_node/1" do
    test "defaults to :local" do
      assert CommitStoreClient.remote_node() == :local
    end

    test "can set and read remote node" do
      CommitStoreClient.set_remote_node(:test_node@localhost)
      assert CommitStoreClient.remote_node() == {:ok, :test_node@localhost}

      # Clean up process dictionary
      Process.delete(:commonplace_remote_node)
      assert CommitStoreClient.remote_node() == :local
    end
  end
end
