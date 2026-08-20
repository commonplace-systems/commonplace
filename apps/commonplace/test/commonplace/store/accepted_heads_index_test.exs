defmodule Commonplace.Store.AcceptedHeadsIndexTest do
  @moduledoc """
  BUILD-1 increment 2: the durable per-doc accepted-head INDEX, maintained
  incrementally through the head-update seam, so the frontier is a
  point-read instead of the `all_commit_ids_for_doc` scan.

  The correctness contract is EQUIVALENCE to increment 1's scan-based
  oracle: for any DAG built through the write path,
  `CommitStore.accepted_heads_indexed/2` must equal
  `AcceptedHeads.of/2`. This suite builds fresh docs via the write path
  (create_chained_commit, import_commit, sibling merge) — increment 2
  maintains the index going forward; legacy-doc backfill is increment 3.
  """
  use ExUnit.Case, async: false

  alias Commonplace.SiblingMerger
  alias Commonplace.Store.{AcceptedHeads, Commit, CommitStore}
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "accepted_heads_index_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"accepted_heads_index_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  defp seed_shared_ancestor(store, uuid) do
    {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)

    doc_c = Doc.new(client_id: 1)
    {doc_c, _} = Doc.get_or_create_type(doc_c, "t", :text)
    doc_c = Text.insert(doc_c, "t", 0, "abc")

    _ =
      CommitStore.create_chained_commit(store, uuid, Encoding.encode_update(doc_c), %{
        kind: :regular
      })

    {:ok, c_snapshot} = CommitStore.snapshot(store, uuid)
    {:ok, c_doc} = Encoding.apply_update(Doc.new(), c_snapshot.update)
    {c_snapshot, Encoding.encode_update(c_doc)}
  end

  defp local_head(store, uuid, c_update, ch, text) do
    doc = Doc.new(client_id: ch)
    {doc, _} = Doc.get_or_create_type(doc, "t", :text)
    {:ok, doc} = Encoding.apply_update(doc, c_update)
    doc = Text.insert(doc, "t", 0, text)
    CommitStore.create_chained_commit(store, uuid, Encoding.encode_update(doc), %{kind: :regular})
  end

  defp import_sibling(store, uuid, c_snapshot, c_update, parent_id, ch, pos, text) do
    doc = Doc.new(client_id: ch)
    {doc, _} = Doc.get_or_create_type(doc, "t", :text)
    {:ok, doc} = Encoding.apply_update(doc, c_update)
    doc = Text.insert(doc, "t", pos, text)

    commit =
      Commit.new(uuid, Encoding.encode_update(doc), parent_id, %{
        kind: :regular,
        snapshot_parent: c_snapshot.id
      })

    :ok = CommitStore.import_commit(store, commit, validator: fn _ -> :ok end)
    commit
  end

  # The equivalence contract, asserted the same way in every case.
  defp assert_index_matches_scan(store, uuid) do
    assert CommitStore.accepted_heads_indexed(store, uuid) == AcceptedHeads.of(store, uuid)
  end

  describe "accepted_heads_indexed/2 equals the scan oracle" do
    test "no commits -> :none", %{store: store} do
      assert CommitStore.accepted_heads_indexed(store, "never-touched") == :none
      assert_index_matches_scan(store, "never-touched")
    end

    test "linear doc -> {:latest}", %{store: store} do
      uuid = "linear"
      {_c, c_update} = seed_shared_ancestor(store, uuid)
      l = local_head(store, uuid, c_update, 2, "X")

      assert CommitStore.accepted_heads_indexed(store, uuid) == {:ok, MapSet.new([l.id])}
      assert_index_matches_scan(store, uuid)
    end

    test "one imported sibling -> two heads", %{store: store} do
      uuid = "one-sibling"
      {c_snapshot, c_update} = seed_shared_ancestor(store, uuid)
      l = local_head(store, uuid, c_update, 2, "X")
      r = import_sibling(store, uuid, c_snapshot, c_update, c_snapshot.id, 3, 3, "Y")

      assert CommitStore.accepted_heads_indexed(store, uuid) == {:ok, MapSet.new([l.id, r.id])}
      assert_index_matches_scan(store, uuid)
    end

    test "a sibling chain contributes only its tip", %{store: store} do
      uuid = "sibling-chain"
      {c_snapshot, c_update} = seed_shared_ancestor(store, uuid)
      l = local_head(store, uuid, c_update, 2, "X")
      r1 = import_sibling(store, uuid, c_snapshot, c_update, c_snapshot.id, 3, 3, "Y")
      r2 = import_sibling(store, uuid, c_snapshot, c_update, r1.id, 3, 3, "Z")

      assert {:ok, heads} = CommitStore.accepted_heads_indexed(store, uuid)
      assert heads == MapSet.new([l.id, r2.id])
      refute MapSet.member?(heads, r1.id)
      assert_index_matches_scan(store, uuid)
    end

    test "a sibling merge collapses the index to the merge commit", %{store: store} do
      uuid = "sibling-merge"
      {c_snapshot, c_update} = seed_shared_ancestor(store, uuid)
      _l = local_head(store, uuid, c_update, 2, "X")
      _r = import_sibling(store, uuid, c_snapshot, c_update, c_snapshot.id, 3, 3, "Y")

      # Pre-merge: two heads.
      assert {:ok, pre} = CommitStore.accepted_heads_indexed(store, uuid)
      assert MapSet.size(pre) == 2

      assert {:ok, :merged, merge_commit} = SiblingMerger.maybe_merge_siblings(store, uuid)

      # Post-merge: the merge commit dominates both, so it is the sole head.
      assert CommitStore.accepted_heads_indexed(store, uuid) ==
               {:ok, MapSet.new([merge_commit.id])}

      assert_index_matches_scan(store, uuid)
    end
  end
end
