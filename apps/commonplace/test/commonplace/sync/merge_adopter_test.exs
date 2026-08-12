defmodule Commonplace.Sync.MergeAdopterTest do
  @moduledoc """
  CX-8k1v: on import of a merge commit that dominates the local
  :latest, auto-advance :latest so peer B converges without invoking
  merge locally. The adopter is conservative — it only advances when
  the incoming merge's ancestor set (via parent_id + merge_parents)
  reaches the local latest. Otherwise the sibling case is left to
  whatever sweeper handles it next.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.{Commit, CommitStore}
  alias Commonplace.Sync.MergeAdopter
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "madopt_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"madopt_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  # Build a two-sibling shape: C_snap → L (chained), R (sibling of L).
  # Returns `{uuid, c_snap, l_commit, r_commit}`.
  defp seed_siblings(store, uuid) do
    {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)

    doc_c = Doc.new(client_id: 1)
    {doc_c, _} = Doc.get_or_create_type(doc_c, "t", :text)
    doc_c = Text.insert(doc_c, "t", 0, "abc")

    _reg =
      CommitStore.create_chained_commit(
        store,
        uuid,
        Encoding.encode_update(doc_c),
        %{kind: :regular}
      )

    {:ok, c_snap} = CommitStore.snapshot(store, uuid)

    doc_l = Doc.new(client_id: 2)
    {doc_l, _} = Doc.get_or_create_type(doc_l, "t", :text)
    {:ok, doc_l} = Encoding.apply_update(doc_l, c_snap.update)
    doc_l = Text.insert(doc_l, "t", 0, "L")

    l_commit =
      CommitStore.create_chained_commit(
        store,
        uuid,
        Encoding.encode_update(doc_l),
        %{kind: :regular}
      )

    doc_r = Doc.new(client_id: 3)
    {doc_r, _} = Doc.get_or_create_type(doc_r, "t", :text)
    {:ok, doc_r} = Encoding.apply_update(doc_r, c_snap.update)
    doc_r = Text.insert(doc_r, "t", 3, "R")

    r_commit =
      Commit.new(uuid, Encoding.encode_update(doc_r), c_snap.id, %{
        kind: :regular,
        snapshot_parent: c_snap.id
      })

    :ok = CommitStore.import_commit(store, r_commit, validator: fn _ -> :ok end)

    {uuid, c_snap, l_commit, r_commit}
  end

  # Craft a merge commit M with parent_id=l and merge_parents=[r].
  # We don't need correct merge content for the adopter tests —
  # dominance is purely a DAG-shape check.
  defp build_merge(uuid, l_id, r_id) do
    Commit.new(uuid, <<"merge-payload">>, l_id, %{kind: :merge}, [r_id])
  end

  describe "maybe_adopt/2" do
    test "non-dominating non-merge commits are no-ops", %{store: store} do
      {uuid, _c, l, r} = seed_siblings(store, "madopt-nonmerge")

      # Build a plain regular commit — not a merge.
      plain =
        Commit.new(uuid, <<"plain">>, r.id, %{kind: :regular, snapshot_parent: r.id})

      assert :skipped = MergeAdopter.maybe_adopt(store, plain)
      {:ok, latest} = CommitStore.latest_commit(store, uuid)
      assert latest.id == l.id
    end

    test "adopts when merge's parent_id equals local :latest", %{store: store} do
      {uuid, _c, l, r} = seed_siblings(store, "madopt-parent")
      # Local :latest is l (chained); merge has parent_id=l.
      merge = build_merge(uuid, l.id, r.id)
      :ok = CommitStore.import_commit(store, merge, validator: fn _ -> :ok end)

      assert :adopted = MergeAdopter.maybe_adopt(store, merge)
      {:ok, latest} = CommitStore.latest_commit(store, uuid)
      assert latest.id == merge.id
    end

    test "adopts when local :latest is in merge_parents", %{store: store} do
      {uuid, _c, l, r} = seed_siblings(store, "madopt-mp")
      # Flip local :latest to r (simulating peer B's perspective).
      :ok = CommitStore.set_latest(store, uuid, r.id)

      merge = build_merge(uuid, l.id, r.id)
      :ok = CommitStore.import_commit(store, merge, validator: fn _ -> :ok end)

      assert :adopted = MergeAdopter.maybe_adopt(store, merge)
      {:ok, latest} = CommitStore.latest_commit(store, uuid)
      assert latest.id == merge.id
    end

    test "skips when local :latest is NOT reachable from the merge", %{store: store} do
      {uuid, _c, l, r} = seed_siblings(store, "madopt-diverged")

      # Simulate peer B having made a divergent local commit X after r.
      doc_x = Doc.new(client_id: 4)
      {doc_x, _} = Doc.get_or_create_type(doc_x, "t", :text)
      {:ok, doc_x} = Encoding.apply_update(doc_x, r.update)
      doc_x = Text.insert(doc_x, "t", 0, "X")

      x_commit =
        Commit.new(uuid, Encoding.encode_update(doc_x), r.id, %{
          kind: :regular,
          snapshot_parent: r.id
        })

      :ok = CommitStore.import_commit(store, x_commit, validator: fn _ -> :ok end)
      :ok = CommitStore.set_latest(store, uuid, x_commit.id)

      # The incoming merge dominates l and r, but NOT x_commit.
      merge = build_merge(uuid, l.id, r.id)
      :ok = CommitStore.import_commit(store, merge, validator: fn _ -> :ok end)

      assert :skipped = MergeAdopter.maybe_adopt(store, merge)
      {:ok, latest} = CommitStore.latest_commit(store, uuid)
      assert latest.id == x_commit.id
    end

    test "skips when local :latest already equals the imported merge", %{store: store} do
      {uuid, _c, l, r} = seed_siblings(store, "madopt-same")
      merge = build_merge(uuid, l.id, r.id)
      :ok = CommitStore.import_commit(store, merge, validator: fn _ -> :ok end)
      :ok = CommitStore.set_latest(store, uuid, merge.id)

      assert :skipped = MergeAdopter.maybe_adopt(store, merge)
    end

    test "skips when the doc has no :latest yet", %{store: store} do
      # Build a merge commit referring to a doc that has no local state.
      merge =
        Commit.new("unknown-doc", <<"payload">>, nil, %{kind: :merge}, [])

      assert :skipped = MergeAdopter.maybe_adopt(store, merge)
    end

    test "adopts transitively (latest is an ancestor of a merge parent)", %{store: store} do
      {uuid, _c, l, r} = seed_siblings(store, "madopt-transitive")

      # Peer B's :latest is r; incoming commit chain is r → r1 (chained
      # regular) → m (merge of r1, l). adopter must walk merge_parents +
      # parent_id chains to see that r is still an ancestor of m.
      doc_r1 = Doc.new(client_id: 5)
      {doc_r1, _} = Doc.get_or_create_type(doc_r1, "t", :text)
      {:ok, doc_r1} = Encoding.apply_update(doc_r1, r.update)
      doc_r1 = Text.insert(doc_r1, "t", 0, "Z")

      r1 =
        Commit.new(uuid, Encoding.encode_update(doc_r1), r.id, %{
          kind: :regular,
          snapshot_parent: r.id
        })

      :ok = CommitStore.import_commit(store, r1, validator: fn _ -> :ok end)
      :ok = CommitStore.set_latest(store, uuid, r.id)

      merge = Commit.new(uuid, <<"m">>, r1.id, %{kind: :merge}, [l.id])
      :ok = CommitStore.import_commit(store, merge, validator: fn _ -> :ok end)

      assert :adopted = MergeAdopter.maybe_adopt(store, merge)
      {:ok, latest} = CommitStore.latest_commit(store, uuid)
      assert latest.id == merge.id
    end
  end

  describe "dominates?/3" do
    test "direct parent_id match", %{store: store} do
      {uuid, _c, l, r} = seed_siblings(store, "dom-parent")
      merge = build_merge(uuid, l.id, r.id)
      assert MergeAdopter.dominates?(store, merge, l.id)
    end

    test "direct merge_parents match", %{store: store} do
      {uuid, _c, l, r} = seed_siblings(store, "dom-mp")
      merge = build_merge(uuid, l.id, r.id)
      assert MergeAdopter.dominates?(store, merge, r.id)
    end

    test "unrelated commit is not dominated", %{store: store} do
      {uuid, _c, l, r} = seed_siblings(store, "dom-unrel")
      merge = build_merge(uuid, l.id, r.id)
      # A made-up id not in the DAG.
      refute MergeAdopter.dominates?(store, merge, <<1, 2, 3, 4>>)
    end
  end
end
