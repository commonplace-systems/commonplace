defmodule Commonplace.Store.SnapshotAncestryTest do
  @moduledoc """
  CX-ntz5 (Build 7.1): snapshot-DAG walker that finds the lowest common
  ancestor snapshot between two commits, plus the ordered chain of
  snapshots from C up to each side's current namespace.

  MVP assumption: snapshot chains are linear (no merge-snapshots in play
  yet — 7.4 introduces multi-parent snapshots and a future follow-up
  will extend this walker if needed).
  """
  use ExUnit.Case, async: true

  alias Commonplace.Store.{CommitStore, SnapshotAncestry}

  # -------------------- Pure-fetcher tests --------------------
  #
  # These tests construct a synthetic snapshot DAG as a map of
  # commit_id => commit struct, then pass a fetcher closure into
  # SnapshotAncestry.common_ancestor_with_fetcher/3. This keeps the
  # walker covered without any CubDB/GenServer machinery.

  defp genesis(id), do: %{id: id, metadata: %{kind: :genesis, doc_uuid: "u"}}

  defp regular(id, parent_id, sp),
    do: %{id: id, parent_id: parent_id, metadata: %{kind: :regular, snapshot_parent: sp}}

  defp snapshot(id, parent_id, snapshot_parents) do
    %{
      id: id,
      parent_id: parent_id,
      metadata: %{kind: :snapshot, snapshot_parents: snapshot_parents}
    }
  end

  defp fetcher(dag), do: fn id -> Map.get(dag, id) end

  describe "common_ancestor/3 — shared immediate snapshot (case a)" do
    test "L and R with same snapshot_parent returns C = that namespace, chains empty" do
      # g ← r1 ← s1 ← r_l, r_r   (r_l and r_r both snapshot_parent = s1)
      dag = %{
        "g" => genesis("g"),
        "r1" => regular("r1", "g", "g"),
        "s1" => snapshot("s1", "r1", ["g"]),
        "r_l" => regular("r_l", "s1", "s1"),
        "r_r" => regular("r_r", "s1", "s1")
      }

      assert {:ok, {"s1", [], []}} =
               SnapshotAncestry.common_ancestor_with_fetcher(fetcher(dag), "r_l", "r_r")
    end

    test "same commit on both sides trivially returns its namespace" do
      dag = %{
        "g" => genesis("g"),
        "r1" => regular("r1", "g", "g")
      }

      assert {:ok, {"g", [], []}} =
               SnapshotAncestry.common_ancestor_with_fetcher(fetcher(dag), "r1", "r1")
    end
  end

  describe "common_ancestor/3 — divergence through snapshots (case b)" do
    test "both sides diverge by one snapshot; C is the pre-divergence snapshot" do
      # g ← r1 ← s1 ← r2a ← s_l ← r_l
      #              ← r2b ← s_r ← r_r
      dag = %{
        "g" => genesis("g"),
        "r1" => regular("r1", "g", "g"),
        "s1" => snapshot("s1", "r1", ["g"]),
        "r2a" => regular("r2a", "s1", "s1"),
        "s_l" => snapshot("s_l", "r2a", ["s1"]),
        "r_l" => regular("r_l", "s_l", "s_l"),
        "r2b" => regular("r2b", "s1", "s1"),
        "s_r" => snapshot("s_r", "r2b", ["s1"]),
        "r_r" => regular("r_r", "s_r", "s_r")
      }

      assert {:ok, {"s1", ["s_l"], ["s_r"]}} =
               SnapshotAncestry.common_ancestor_with_fetcher(fetcher(dag), "r_l", "r_r")
    end

    test "both sides diverge by multiple snapshots" do
      # g ← s1 ← s2 ← s_l1 ← s_l2 ← r_l
      #         ← s_r1 ← r_r
      dag = %{
        "g" => genesis("g"),
        "s1" => snapshot("s1", "g", ["g"]),
        "s2" => snapshot("s2", "s1", ["s1"]),
        "s_l1" => snapshot("s_l1", "s2", ["s2"]),
        "s_l2" => snapshot("s_l2", "s_l1", ["s_l1"]),
        "r_l" => regular("r_l", "s_l2", "s_l2"),
        "s_r1" => snapshot("s_r1", "s2", ["s2"]),
        "r_r" => regular("r_r", "s_r1", "s_r1")
      }

      assert {:ok, {"s2", ["s_l1", "s_l2"], ["s_r1"]}} =
               SnapshotAncestry.common_ancestor_with_fetcher(fetcher(dag), "r_l", "r_r")
    end
  end

  describe "common_ancestor/3 — asymmetric chain lengths (case c)" do
    test "one side has more snapshots than the other" do
      # g ← s1 ← s2 ← s3 ← r_l
      #         ← r_r   (r_r's namespace is s1)
      dag = %{
        "g" => genesis("g"),
        "s1" => snapshot("s1", "g", ["g"]),
        "s2" => snapshot("s2", "s1", ["s1"]),
        "s3" => snapshot("s3", "s2", ["s2"]),
        "r_l" => regular("r_l", "s3", "s3"),
        "r_r" => regular("r_r", "s1", "s1")
      }

      assert {:ok, {"s1", ["s2", "s3"], []}} =
               SnapshotAncestry.common_ancestor_with_fetcher(fetcher(dag), "r_l", "r_r")
    end
  end

  describe "common_ancestor/3 — no common ancestor (case d)" do
    test "two separate docs with different genesis return :no_common_ancestor" do
      # Two separate root chains — no overlap.
      dag = %{
        "g_a" => genesis("g_a"),
        "s_a" => snapshot("s_a", "g_a", ["g_a"]),
        "r_a" => regular("r_a", "s_a", "s_a"),
        "g_b" => genesis("g_b"),
        "s_b" => snapshot("s_b", "g_b", ["g_b"]),
        "r_b" => regular("r_b", "s_b", "s_b")
      }

      assert {:error, :no_common_ancestor} =
               SnapshotAncestry.common_ancestor_with_fetcher(fetcher(dag), "r_a", "r_b")
    end
  end

  describe "common_ancestor/3 — input variants" do
    test "accepts snapshot commits directly as inputs (L and R are snapshots)" do
      dag = %{
        "g" => genesis("g"),
        "s1" => snapshot("s1", "g", ["g"]),
        "s_l" => snapshot("s_l", "s1", ["s1"]),
        "s_r" => snapshot("s_r", "s1", ["s1"])
      }

      # When a snapshot is passed directly, its namespace is its own id.
      assert {:ok, {"s1", ["s_l"], ["s_r"]}} =
               SnapshotAncestry.common_ancestor_with_fetcher(fetcher(dag), "s_l", "s_r")
    end

    test "returns error when either commit id is missing" do
      dag = %{"g" => genesis("g")}

      assert {:error, :unknown_commit} =
               SnapshotAncestry.common_ancestor_with_fetcher(fetcher(dag), "missing", "g")

      assert {:error, :unknown_commit} =
               SnapshotAncestry.common_ancestor_with_fetcher(fetcher(dag), "g", "missing")
    end
  end

  # -------------------- Integration test --------------------

  describe "common_ancestor/3 against a real CommitStore" do
    setup do
      dir = Path.join(System.tmp_dir!(), "cp_snap_anc_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      name = :"snap_anc_store_#{:rand.uniform(1_000_000)}"
      start_supervised!({CommitStore, data_dir: dir, name: name})
      on_exit(fn -> File.rm_rf!(dir) end)
      %{store: name}
    end

    defp update_from(client_id, content) do
      doc = Yelixer.Doc.new(client_id: client_id)
      {doc, _} = Yelixer.Doc.get_or_create_type(doc, "t", :text)
      doc = Yelixer.Types.Text.insert(doc, "t", 0, content)
      Yelixer.Encoding.encode_update(doc)
    end

    test "finds common genesis ancestor for two regulars in the same uuid", %{store: store} do
      uuid = "same-uuid"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)
      c1 =
        CommitStore.create_chained_commit(store, uuid, update_from(1, "a"), %{kind: :regular})

      c2 =
        CommitStore.create_chained_commit(store, uuid, update_from(1, "b"), %{kind: :regular})

      # c1 and c2 both have snapshot_parent = genesis.id (auto-stamped
      # by CX-a04 against the fresh-doc bootstrap), so their LCA is the
      # genesis namespace and both chains are empty.
      assert {:ok, {c, [], []}} = SnapshotAncestry.common_ancestor(store, c1.id, c2.id)
      assert c == genesis.id
    end

    test "finds cross-snapshot LCA for a commit before and after a snapshot", %{store: store} do
      uuid = "with-snap"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)

      pre_snap =
        CommitStore.create_chained_commit(store, uuid, update_from(1, "pre"), %{kind: :regular})

      {:ok, snap} = CommitStore.snapshot(store, uuid)

      post_snap =
        CommitStore.create_chained_commit(store, uuid, update_from(1, "post"), %{kind: :regular})

      # pre_snap's namespace = genesis.id; post_snap's namespace = snap.id.
      # snap.snapshot_parents = [genesis.id], so walking snap's chain
      # yields [snap.id, genesis.id], and pre_snap's chain is [genesis.id].
      # LCA = genesis.id; L_chain (post_snap) = [snap.id]; R_chain (pre_snap) = [].
      assert {:ok, {c, l_chain, r_chain}} =
               SnapshotAncestry.common_ancestor(store, post_snap.id, pre_snap.id)

      assert c == genesis.id
      assert l_chain == [snap.id]
      assert r_chain == []
    end
  end
end
