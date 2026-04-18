defmodule Commonplace.Store.CommitStoreTest do
  use ExUnit.Case

  alias Commonplace.Store.{Commit, CommitStore}

  setup do
    dir = Path.join(System.tmp_dir!(), "commonplace_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  describe "create_commit/3" do
    test "stores and returns a commit", %{store: store} do
      commit = CommitStore.create_commit(store, "doc-1", <<1, 2, 3>>, nil)

      assert %Commit{} = commit
      assert commit.doc_uuid == "doc-1"
      assert commit.update == <<1, 2, 3>>
    end
  end

  describe "get_commit/1" do
    test "retrieves a stored commit by ID", %{store: store} do
      commit = CommitStore.create_commit(store, "doc-1", <<1, 2, 3>>, nil)

      assert {:ok, fetched} = CommitStore.get_commit(store, commit.id)
      assert fetched.id == commit.id
      assert fetched.update == <<1, 2, 3>>
    end

    test "returns :none for unknown commit ID", %{store: store} do
      assert :none = CommitStore.get_commit(store, <<0::256>>)
    end
  end

  describe "latest_commit/1" do
    test "returns :none when no commits exist for a document", %{store: store} do
      assert :none = CommitStore.latest_commit(store, "nonexistent")
    end

    test "returns the most recent commit for a document", %{store: store} do
      c1 = CommitStore.create_commit(store, "doc-1", <<1>>, nil)
      _c2 = CommitStore.create_commit(store, "doc-1", <<2>>, c1.id)
      c3 = CommitStore.create_commit(store, "doc-1", <<3>>, c1.id)

      {:ok, latest} = CommitStore.latest_commit(store, "doc-1")
      assert latest.id == c3.id
    end

    test "tracks latest per document independently", %{store: store} do
      CommitStore.create_commit(store, "doc-1", <<1>>, nil)
      commit_b = CommitStore.create_commit(store, "doc-2", <<2>>, nil)

      {:ok, latest} = CommitStore.latest_commit(store, "doc-2")
      assert latest.id == commit_b.id
    end
  end

  describe "DAG chain" do
    test "can walk the full commit history via parent IDs", %{store: store} do
      c1 = CommitStore.create_commit(store, "doc-1", <<1>>, nil)
      c2 = CommitStore.create_commit(store, "doc-1", <<2>>, c1.id)
      c3 = CommitStore.create_commit(store, "doc-1", <<3>>, c2.id)

      {:ok, fetched_3} = CommitStore.get_commit(store, c3.id)
      assert fetched_3.parent_id == c2.id

      {:ok, fetched_2} = CommitStore.get_commit(store, fetched_3.parent_id)
      assert fetched_2.parent_id == c1.id

      {:ok, fetched_1} = CommitStore.get_commit(store, fetched_2.parent_id)
      assert fetched_1.parent_id == nil
    end
  end

  describe "create_snapshot_commit/4 (CX-u7p)" do
    test "tags the commit metadata with kind: :snapshot", %{store: store} do
      _c1 = CommitStore.create_commit(store, "doc-1", <<1>>, nil)
      snap = CommitStore.create_snapshot_commit(store, "doc-1", <<99>>)

      {:ok, fetched} = CommitStore.get_commit(store, snap.id)
      assert fetched.metadata.kind == :snapshot
    end

    test "chains to the latest commit (normal parent_id)", %{store: store} do
      c1 = CommitStore.create_commit(store, "doc-1", <<1>>, nil)
      snap = CommitStore.create_snapshot_commit(store, "doc-1", <<99>>)

      assert snap.parent_id == c1.id
      {:ok, latest} = CommitStore.latest_commit(store, "doc-1")
      assert latest.id == snap.id
    end

    test "snapshot becomes :latest, replication-walkable to root", %{store: store} do
      c1 = CommitStore.create_commit(store, "doc-1", <<1>>, nil)
      c2 = CommitStore.create_commit(store, "doc-1", <<2>>, c1.id)
      snap = CommitStore.create_snapshot_commit(store, "doc-1", <<99>>)

      # Walking back from snap reaches the original root
      {:ok, fetched_snap} = CommitStore.get_commit(store, snap.id)
      assert fetched_snap.parent_id == c2.id
      {:ok, fetched_c2} = CommitStore.get_commit(store, fetched_snap.parent_id)
      assert fetched_c2.parent_id == c1.id
    end

    test "merges caller-supplied metadata with kind: :snapshot", %{store: store} do
      _c1 = CommitStore.create_commit(store, "doc-1", <<1>>, nil)

      snap = CommitStore.create_snapshot_commit(store, "doc-1", <<99>>, %{note: "test"})

      {:ok, fetched} = CommitStore.get_commit(store, snap.id)
      assert fetched.metadata.kind == :snapshot
      assert fetched.metadata.note == "test"
    end

    test "works on a doc with no prior commits (parent_id nil)", %{store: store} do
      snap = CommitStore.create_snapshot_commit(store, "fresh-doc", <<42>>)

      assert snap.parent_id == nil
      {:ok, fetched} = CommitStore.get_commit(store, snap.id)
      assert fetched.metadata.kind == :snapshot
    end
  end

  describe "ensure_genesis/2 — deterministic genesis stamping (CX-fzi)" do
    test "returns the deterministic genesis commit for a doc_uuid", %{store: store} do
      assert {:ok, genesis} = CommitStore.ensure_genesis(store, "doc-new")
      assert genesis.metadata == %{kind: :genesis, doc_uuid: "doc-new"}
      assert genesis.parent_id == nil
      assert genesis.update == <<>>
      assert genesis.merge_parents == []
    end

    test "stores genesis so get_commit/2 can retrieve it", %{store: store} do
      {:ok, genesis} = CommitStore.ensure_genesis(store, "doc-new")
      assert {:ok, fetched} = CommitStore.get_commit(store, genesis.id)
      assert fetched.id == genesis.id
      assert fetched.metadata.kind == :genesis
    end

    test "is idempotent — second call returns the same genesis", %{store: store} do
      {:ok, g1} = CommitStore.ensure_genesis(store, "doc-new")
      {:ok, g2} = CommitStore.ensure_genesis(store, "doc-new")
      assert g1.id == g2.id
    end

    test "does NOT update :latest (Option A scope — no auto-wiring)", %{store: store} do
      # If ensure_genesis flipped :latest, every caller of latest_commit
      # would observe a phantom head that the user never wrote. Callers
      # opt in to wiring genesis as the parent of the first real commit.
      {:ok, _genesis} = CommitStore.ensure_genesis(store, "doc-new")
      assert :none = CommitStore.latest_commit(store, "doc-new")
    end

    test "distinct doc_uuids produce distinct geneses", %{store: store} do
      {:ok, g_a} = CommitStore.ensure_genesis(store, "doc-a")
      {:ok, g_b} = CommitStore.ensure_genesis(store, "doc-b")
      assert g_a.id != g_b.id
    end
  end

  describe "import_commit/3 — namespace validation hook (CX-bv3)" do
    test "accepts commits by default (no validator configured)", %{store: store} do
      commit = Commit.new("doc-incoming", <<1, 2, 3>>, nil)

      assert :ok = CommitStore.import_commit(store, commit)
      assert {:ok, fetched} = CommitStore.get_commit(store, commit.id)
      assert fetched.id == commit.id
    end

    test "injected validator is invoked on every import", %{store: store} do
      parent = self()
      validator = fn commit ->
        send(parent, {:validator_called, commit.id})
        :ok
      end

      commit = Commit.new("doc-incoming", <<1, 2, 3>>, nil)

      assert :ok = CommitStore.import_commit(store, commit, validator: validator)

      assert_receive {:validator_called, id} when id == commit.id
    end

    test "import rejects when validator returns {:error, reason}", %{store: store} do
      validator = fn _commit -> {:error, :namespace_mismatch} end
      commit = Commit.new("doc-incoming", <<1, 2, 3>>, nil)

      assert {:error, {:namespace_rejected, :namespace_mismatch}} =
               CommitStore.import_commit(store, commit, validator: validator)

      # Rejected commit must NOT be persisted.
      assert :none = CommitStore.get_commit(store, commit.id)
    end

    test "rejected import does not update :latest", %{store: store} do
      validator = fn _commit -> {:error, :namespace_mismatch} end
      commit = Commit.new("doc-incoming", <<1, 2, 3>>, nil)

      assert {:error, _} = CommitStore.import_commit(store, commit, validator: validator)
      assert :none = CommitStore.latest_commit(store, "doc-incoming")
    end
  end
end
