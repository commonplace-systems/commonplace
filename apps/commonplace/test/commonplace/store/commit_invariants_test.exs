defmodule Commonplace.Store.CommitInvariantsTest do
  @moduledoc """
  BUILD-1 increment 2b: Hazard 3 — a document's accepted heads must be an
  antichain (no accepted head a DAG-ancestor of another). The seam
  enforces this by construction; this is the backstop that alarms if a
  future seam edit regresses.

  The core judgment `antichain_of/3` is tested on explicit head sets so
  the violation path is exercised directly (a corrupt index row cannot be
  produced through the public API). The discriminating case is a merge:
  ancestry must follow `merge_parents`, not just the linear chain.
  """
  use ExUnit.Case, async: false

  alias Commonplace.SiblingMerger
  alias Commonplace.Store.{CommitInvariants, Commit, CommitStore}
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "commit_invariants_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"commit_invariants_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  defp chained(store, uuid, ch, text) do
    doc = Doc.new(client_id: ch)
    {doc, _} = Doc.get_or_create_type(doc, "t", :text)
    doc = Text.insert(doc, "t", 0, text)
    CommitStore.create_chained_commit(store, uuid, Encoding.encode_update(doc), %{kind: :regular})
  end

  defp seed_merge(store, uuid) do
    {:ok, _g} = CommitStore.ensure_genesis(store, uuid)
    _ = chained(store, uuid, 1, "abc")
    {:ok, c} = CommitStore.snapshot(store, uuid)
    {:ok, c_doc} = Encoding.apply_update(Doc.new(), c.update)
    c_update = Encoding.encode_update(c_doc)

    lo = Doc.new(client_id: 2)
    {lo, _} = Doc.get_or_create_type(lo, "t", :text)
    {:ok, lo} = Encoding.apply_update(lo, c_update)
    lo = Text.insert(lo, "t", 0, "X")

    l =
      CommitStore.create_chained_commit(store, uuid, Encoding.encode_update(lo), %{kind: :regular})

    ro = Doc.new(client_id: 3)
    {ro, _} = Doc.get_or_create_type(ro, "t", :text)
    {:ok, ro} = Encoding.apply_update(ro, c_update)
    ro = Text.insert(ro, "t", 3, "Y")

    r =
      Commit.new(uuid, Encoding.encode_update(ro), c.id, %{kind: :regular, snapshot_parent: c.id})

    :ok = CommitStore.import_commit(store, r, validator: fn _ -> :ok end)

    {:ok, :merged, m} = SiblingMerger.maybe_merge_siblings(store, uuid)
    {l, r, m}
  end

  describe "antichain_of/3 (core judgment on an explicit head set)" do
    test "fewer than two heads is trivially an antichain", %{store: store} do
      assert CommitInvariants.antichain_of(MapSet.new(), store, "d") == :ok
      assert CommitInvariants.antichain_of(MapSet.new(["x"]), store, "d") == :ok
    end

    test "two true siblings dominate neither the other -> :ok", %{store: store} do
      uuid = "siblings"
      {l, r, _m} = seed_merge(store, uuid)
      # L and R share the ancestor C; neither is reachable from the other.
      assert CommitInvariants.antichain_of(MapSet.new([l.id, r.id]), store, uuid) == :ok
    end

    test "a parent and its child are NOT an antichain -> :violation", %{store: store} do
      uuid = "linear"
      {:ok, _g} = CommitStore.ensure_genesis(store, uuid)
      p = chained(store, uuid, 1, "P")
      c = chained(store, uuid, 1, "C")

      assert {:violation, details} =
               CommitInvariants.antichain_of(MapSet.new([p.id, c.id]), store, uuid)

      assert details.ancestor == p.id
      assert details.descendant == c.id
    end

    # The discriminator: a merge commit M reaches its folded sibling R only
    # through merge_parents. Linear ancestry (is_ancestor?) would call
    # {M, R} an antichain; the DAG walk correctly flags R as dominated.
    test "a merge commit dominates its merge_parent sibling -> :violation", %{store: store} do
      uuid = "merge"
      {_l, r, m} = seed_merge(store, uuid)

      assert {:violation, details} =
               CommitInvariants.antichain_of(MapSet.new([m.id, r.id]), store, uuid)

      assert details.ancestor == r.id
      assert details.descendant == m.id
    end
  end

  describe "antichain/2 (reads the durable index)" do
    test "a real doc's maintained head set passes", %{store: store} do
      uuid = "merge"
      {_l, _r, _m} = seed_merge(store, uuid)
      # After the merge the seam leaves a single-head antichain.
      assert CommitInvariants.antichain(store, uuid) == :ok
    end

    test "an untouched doc is :ok", %{store: store} do
      assert CommitInvariants.antichain(store, "never") == :ok
    end
  end
end
