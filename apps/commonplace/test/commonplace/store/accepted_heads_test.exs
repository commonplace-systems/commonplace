defmodule Commonplace.Store.AcceptedHeadsTest do
  @moduledoc """
  The accepted-head SET as a first-class primitive (Stage-B ruling,
  2026-08-08 multiplayer-proposal-reaction §1; cellular roadmap Phase 1 /
  QUEUE BUILD-1). A document's accepted heads are its non-dominated
  frontier: `:latest` plus the tips of any sibling branches not reachable
  from `:latest`. It is exactly the set `SiblingMerger` reconstructs by
  scanning (`all_commit_ids_for_doc` − reachable), named and tested here
  so a later durable index (increment 2) has a checkable oracle to match.

  Increment 1 is ADDITIVE: a read-only computation over the existing
  store primitives. No write path is touched, no corpus backfill is run,
  and `SiblingMerger` is not yet refactored to consume it.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.{AcceptedHeads, Commit, CommitStore}
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "accepted_heads_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"accepted_heads_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  # Genesis → C (snapshot). Returns the snapshot commit + its update bytes,
  # the shared parent that both :latest and any siblings chain off of.
  defp seed_shared_ancestor(store, uuid) do
    {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)

    doc_c = Doc.new(client_id: 1)
    {doc_c, _} = Doc.get_or_create_type(doc_c, "t", :text)
    doc_c = Text.insert(doc_c, "t", 0, "abc")

    _ =
      CommitStore.create_chained_commit(
        store,
        uuid,
        Encoding.encode_update(doc_c),
        %{kind: :regular}
      )

    {:ok, c_snapshot} = CommitStore.snapshot(store, uuid)
    {:ok, c_doc} = Encoding.apply_update(Doc.new(), c_snapshot.update)
    {c_snapshot, Encoding.encode_update(c_doc)}
  end

  # Advance :latest one local chained commit past the shared ancestor.
  defp local_head(store, uuid, c_update, ch, text) do
    doc = Doc.new(client_id: ch)
    {doc, _} = Doc.get_or_create_type(doc, "t", :text)
    {:ok, doc} = Encoding.apply_update(doc, c_update)
    doc = Text.insert(doc, "t", 0, text)
    CommitStore.create_chained_commit(store, uuid, Encoding.encode_update(doc), %{kind: :regular})
  end

  # Import a sibling commit off `parent_id` (defaults to the shared
  # ancestor), landing it off :latest via the remote path.
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

  describe "of/2" do
    test "a doc with no commits has no accepted heads", %{store: store} do
      assert AcceptedHeads.of(store, "never-touched") == :none
    end

    test "a linear doc's only accepted head is :latest", %{store: store} do
      uuid = "linear"
      {_c, c_update} = seed_shared_ancestor(store, uuid)
      l = local_head(store, uuid, c_update, 2, "X")

      {:ok, latest} = CommitStore.latest_commit(store, uuid)
      assert latest.id == l.id
      assert {:ok, heads} = AcceptedHeads.of(store, uuid)
      assert heads == MapSet.new([l.id])
    end

    test "one imported sibling adds a second accepted head", %{store: store} do
      uuid = "one-sibling"
      {c_snapshot, c_update} = seed_shared_ancestor(store, uuid)
      l = local_head(store, uuid, c_update, 2, "X")
      r = import_sibling(store, uuid, c_snapshot, c_update, c_snapshot.id, 3, 3, "Y")

      assert {:ok, heads} = AcceptedHeads.of(store, uuid)
      assert heads == MapSet.new([l.id, r.id])
    end

    # The tip-filter test: a sibling CHAIN R1 -> R2 contributes only its
    # TIP (R2) to the head set. If the computation returned every commit
    # not reachable from :latest, R1 (the dominated interior) would leak
    # in and this assertion goes red. This is the case that proves the
    # frontier is non-dominated tips, not "all off-:latest commits".
    test "a sibling chain contributes only its tip, not interior commits", %{store: store} do
      uuid = "sibling-chain"
      {c_snapshot, c_update} = seed_shared_ancestor(store, uuid)
      l = local_head(store, uuid, c_update, 2, "X")
      r1 = import_sibling(store, uuid, c_snapshot, c_update, c_snapshot.id, 3, 3, "Y")
      r2 = import_sibling(store, uuid, c_snapshot, c_update, r1.id, 3, 3, "Z")

      all = CommitStore.all_commit_ids_for_doc(store, uuid)
      assert MapSet.member?(all, r1.id), "positive control: R1 is present in the full doc scan"

      assert {:ok, heads} = AcceptedHeads.of(store, uuid)
      assert heads == MapSet.new([l.id, r2.id])
      refute MapSet.member?(heads, r1.id), "R1 is dominated by R2 and must not be a head"
    end
  end
end
