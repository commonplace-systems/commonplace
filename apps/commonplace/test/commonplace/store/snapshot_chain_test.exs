defmodule Commonplace.Store.SnapshotChainTest do
  @moduledoc """
  CX-e31: public traversal API for the snapshot-DAG.

  The snapshot-DAG is already built implicitly by CX-umz / CX-bv3:
  every snapshot commit carries `metadata.snapshot_parents = [prior_ns]`,
  and every regular commit carries `metadata.snapshot_parent = current_ns`
  (auto-stamped in CommitStore). `SnapshotAncestry.snapshot_chain/2`
  exposes this as a first-class read API so callers can:
    - traverse history at snapshot granularity (O(snapshots) not O(commits))
    - detect concurrent snapshots that share a parent
    - implement branch/merge UX over the snapshot DAG

  The chain is ordered [genesis, s1, s2, ..., current_ns].
  """
  use ExUnit.Case, async: true

  alias Commonplace.Store.SnapshotAncestry

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

  describe "snapshot_chain_with_fetcher/2" do
    test "fresh doc (only genesis) — chain is just [genesis]" do
      dag = %{
        "g" => genesis("g"),
        "r1" => regular("r1", "g", "g")
      }

      assert {:ok, ["g"]} =
               SnapshotAncestry.snapshot_chain_with_fetcher(fetcher(dag), "r1")
    end

    test "chain of regulars + one snapshot — chain is [genesis, s1]" do
      dag = %{
        "g" => genesis("g"),
        "r1" => regular("r1", "g", "g"),
        "s1" => snapshot("s1", "r1", ["g"]),
        "r2" => regular("r2", "s1", "s1")
      }

      assert {:ok, ["g", "s1"]} =
               SnapshotAncestry.snapshot_chain_with_fetcher(fetcher(dag), "r2")
    end

    test "multiple snapshots — chain lists each in order from genesis forward" do
      dag = %{
        "g" => genesis("g"),
        "s1" => snapshot("s1", "g", ["g"]),
        "s2" => snapshot("s2", "s1", ["s1"]),
        "s3" => snapshot("s3", "s2", ["s2"]),
        "tip" => regular("tip", "s3", "s3")
      }

      assert {:ok, ["g", "s1", "s2", "s3"]} =
               SnapshotAncestry.snapshot_chain_with_fetcher(fetcher(dag), "tip")
    end

    test "input is a snapshot commit — chain includes it as the tip" do
      dag = %{
        "g" => genesis("g"),
        "s1" => snapshot("s1", "g", ["g"]),
        "s2" => snapshot("s2", "s1", ["s1"])
      }

      assert {:ok, ["g", "s1", "s2"]} =
               SnapshotAncestry.snapshot_chain_with_fetcher(fetcher(dag), "s2")
    end

    test "input is genesis itself — chain is [genesis]" do
      dag = %{"g" => genesis("g")}

      assert {:ok, ["g"]} =
               SnapshotAncestry.snapshot_chain_with_fetcher(fetcher(dag), "g")
    end

    test "unknown commit id returns :error" do
      dag = %{"g" => genesis("g")}

      assert {:error, :unknown_commit} =
               SnapshotAncestry.snapshot_chain_with_fetcher(fetcher(dag), "missing")
    end

    test "multi-parent snapshot (merge-snapshot, Build 7.4) — walks first parent MVP" do
      # A merge-snapshot has snapshot_parents = [L_ns, R_ns]. The MVP
      # linear walker (matching SnapshotAncestry.common_ancestor/3's
      # CX-ntz5 assumption) takes the first parent. Full-DAG traversal
      # is a follow-up once cross-merge-snapshot history becomes
      # load-bearing.
      dag = %{
        "g" => genesis("g"),
        "sL" => snapshot("sL", "g", ["g"]),
        "sR" => snapshot("sR", "g", ["g"]),
        "sM" => snapshot("sM", "sL", ["sL", "sR"]),
        "tip" => regular("tip", "sM", "sM")
      }

      # Expected: walks first parent sL back, so chain is [g, sL, sM].
      # sR is NOT in the chain on this path — that's the MVP limitation.
      assert {:ok, ["g", "sL", "sM"]} =
               SnapshotAncestry.snapshot_chain_with_fetcher(fetcher(dag), "tip")
    end
  end
end
