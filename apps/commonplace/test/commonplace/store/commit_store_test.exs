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
      # Post-CX-m3x: first commit on a fresh doc parents to deterministic genesis.
      assert fetched_1.parent_id == Commit.genesis("doc-1").id
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

    test "works on a doc with no prior commits (parents to genesis)", %{store: store} do
      snap = CommitStore.create_snapshot_commit(store, "fresh-doc", <<42>>)

      # Post-CX-m3x: a snapshot on a fresh doc parents to the deterministic
      # genesis rather than nil, so the snapshot sits in a proper namespace
      # root.
      assert snap.parent_id == Commit.genesis("fresh-doc").id
      {:ok, fetched} = CommitStore.get_commit(store, snap.id)
      assert fetched.metadata.kind == :snapshot
    end
  end

  describe "create_commit/5 — auto-wire genesis on fresh doc (CX-m3x)" do
    test "first commit on a fresh uuid parents to deterministic genesis", %{store: store} do
      commit = CommitStore.create_commit(store, "doc-fresh", <<1, 2, 3>>, nil)

      expected_genesis_id = Commit.genesis("doc-fresh").id
      assert commit.parent_id == expected_genesis_id,
             "a fresh-doc commit must descend from the deterministic genesis, not nil"
    end

    test "genesis is stored and retrievable after first create_commit", %{store: store} do
      _commit = CommitStore.create_commit(store, "doc-fresh", <<1, 2, 3>>, nil)

      genesis_id = Commit.genesis("doc-fresh").id
      assert {:ok, g} = CommitStore.get_commit(store, genesis_id)
      assert g.metadata == %{kind: :genesis, doc_uuid: "doc-fresh"}
    end

    test "genesis is stamped only once — second user commit parents to the first user commit", %{store: store} do
      c1 = CommitStore.create_commit(store, "doc-fresh", <<1>>, nil)
      c2 = CommitStore.create_chained_commit(store, "doc-fresh", <<2>>)

      assert c2.parent_id == c1.id
    end

    test "explicit parent_id skips auto-genesis", %{store: store} do
      # Simulate a pre-existing commit chain (e.g., imported from a peer).
      existing = CommitStore.create_commit(store, "doc-other", <<9>>, nil)

      # Now create a commit on a different uuid, chaining to `existing.id`.
      # Since parent_id is explicit, no genesis should be auto-inserted
      # for this uuid.
      commit = CommitStore.create_commit(store, "doc-chain", <<1>>, existing.id)

      assert commit.parent_id == existing.id

      # No genesis for "doc-chain" should exist.
      chain_genesis_id = Commit.genesis("doc-chain").id
      assert :none = CommitStore.get_commit(store, chain_genesis_id)
    end

    test "pre-umbrella doc with existing :latest retains legacy behavior (parent_id stays nil)", %{store: store} do
      # Simulate a pre-umbrella doc by importing a commit that predates
      # the wiring. It has metadata=%{} and parent_id=nil (legacy hatch).
      legacy = Commit.new("doc-legacy", <<7>>, nil, %{})
      :ok = CommitStore.import_commit(store, legacy)
      :ok = CommitStore.set_latest(store, "doc-legacy", legacy.id)

      # A subsequent create_commit with parent_id=nil on this pre-umbrella
      # doc must NOT insert a retroactive genesis — write-side only per
      # the spec's pre-umbrella rule.
      new_commit = CommitStore.create_commit(store, "doc-legacy", <<8>>, nil)
      assert new_commit.parent_id == nil

      legacy_genesis_id = Commit.genesis("doc-legacy").id
      assert :none = CommitStore.get_commit(store, legacy_genesis_id)
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
