defmodule Commonplace.Store.DerivationMapComposeTest do
  @moduledoc """
  CX-i6xt (Build 7.2): `Commonplace.Store.Namespace.compose_dms/1` folds
  a list of derivation maps `[DM1, DM2, ..., DMn]` into a single
  composed map that translates `namespace(Sn)` refs directly into
  `namespace(S0)` refs.

  A DM has shape `%{source_snapshot_hash => %{new_id => old_id}}` where
  ids are `{client_id, clock}` tuples. DMi's keys are items in Si; its
  values are items in Si-1. Composition chases the chain:

      composed[hash(S0)][new_in_Sn]
        = DM1[hash(S0)][DM2[hash(S1)][...DMn[hash(Sn-1)][new_in_Sn]]]

  Entries whose mid-chain lookups miss are dropped — the composed DM
  only claims to know ids that trace all the way back to S0.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Store.Namespace

  doctest Commonplace.Store.Namespace, only: [compose_dms: 1]

  # -------------------- Base cases --------------------

  describe "compose_dms/1 — base cases" do
    test "empty list returns identity (empty map)" do
      assert Namespace.compose_dms([]) == %{}
    end

    test "single DM returns that DM unchanged" do
      dm = %{<<1>> => %{{1, 0} => {10, 0}, {1, 1} => {10, 1}}}
      assert Namespace.compose_dms([dm]) == dm
    end

    test "list of empty DMs returns empty" do
      assert Namespace.compose_dms([%{}, %{}, %{}]) == %{}
    end
  end

  # -------------------- Two-DM composition --------------------

  describe "compose_dms/1 — two DMs (simple chain)" do
    test "composes two DMs by chained lookup through the intermediate namespace" do
      # DM1: S1 → S0  (new=2, old=1)  under hash(S0)
      # DM2: S2 → S1  (new=3, old=2)  under hash(S1)
      # Composed should map: 3 in S2 → 1 in S0, under hash(S0)
      s0_hash = <<0>>
      s1_hash = <<1>>

      dm1 = %{s0_hash => %{{2, 0} => {1, 0}, {2, 1} => {1, 1}}}
      dm2 = %{s1_hash => %{{3, 0} => {2, 0}, {3, 1} => {2, 1}}}

      expected = %{s0_hash => %{{3, 0} => {1, 0}, {3, 1} => {1, 1}}}
      assert Namespace.compose_dms([dm1, dm2]) == expected
    end

    test "drops entries whose intermediate lookup misses" do
      # DM2 has a new id whose value doesn't appear as a key in DM1 —
      # the chain is broken for that id, so composed drops it.
      s0_hash = <<0>>
      s1_hash = <<1>>

      dm1 = %{s0_hash => %{{2, 0} => {1, 0}}}
      # DM2's {3, 0} maps to {2, 0} — present in DM1. Good.
      # DM2's {3, 1} maps to {2, 99} — NOT present in DM1. Drop.
      dm2 = %{s1_hash => %{{3, 0} => {2, 0}, {3, 1} => {2, 99}}}

      expected = %{s0_hash => %{{3, 0} => {1, 0}}}
      assert Namespace.compose_dms([dm1, dm2]) == expected
    end

    test "returns empty when no entries chain through" do
      s0_hash = <<0>>
      s1_hash = <<1>>

      dm1 = %{s0_hash => %{{2, 0} => {1, 0}}}
      # Every DM2 value misses DM1.
      dm2 = %{s1_hash => %{{3, 0} => {99, 0}, {3, 1} => {99, 1}}}

      assert Namespace.compose_dms([dm1, dm2]) == %{}
    end
  end

  # -------------------- Three-DM composition --------------------

  describe "compose_dms/1 — three-DM chain" do
    test "composes three DMs end-to-end" do
      # Chain: id_in_S3 {3,0} -> DM3 -> {2,0} in S2 -> DM2 -> {1,0} in S1 -> DM1 -> {0,0} in S0
      dm1 = %{<<"s0">> => %{{1, 0} => {0, 0}}}
      dm2 = %{<<"s1">> => %{{2, 0} => {1, 0}}}
      dm3 = %{<<"s2">> => %{{3, 0} => {2, 0}}}

      expected = %{<<"s0">> => %{{3, 0} => {0, 0}}}
      assert Namespace.compose_dms([dm1, dm2, dm3]) == expected
    end
  end

  # -------------------- Property: composed == sequential --------------------

  describe "compose_dms/1 — composed-equals-sequential property" do
    test "for every id in DMn, composed lookup equals sequential chain application" do
      # Build a 4-long chain where each DMi maps {i, k} → {i-1, k}.
      # So sequential lookup on {4, k} through [DM1..DM4] should yield {0, k}.
      chain_length = 4
      max_id = 10

      dms =
        for i <- 1..chain_length do
          inner =
            for k <- 0..max_id, into: %{}, do: {{i, k}, {i - 1, k}}

          hash = <<"s", i - 1>>
          %{hash => inner}
        end

      composed = Namespace.compose_dms(dms)

      # Sequential application helper: look up through each DM in reverse order.
      sequential = fn new_id ->
        Enum.reduce_while(Enum.reverse(dms), new_id, fn dm, id ->
          found =
            Enum.find_value(dm, fn {_hash, inner} -> Map.get(inner, id) end)

          if found == nil, do: {:halt, :miss}, else: {:cont, found}
        end)
      end

      # Every new_id in DMn's inner must appear in composed, mapping to the
      # same result as sequential lookup.
      dmn = List.last(dms)
      [{_hash_of_s0_in_dmn, dmn_inner}] = Enum.take(dmn, 1)

      for {new_id, _} <- dmn_inner do
        expected = sequential.(new_id)

        # composed is keyed by the ORIGINAL source hash (hash(S0)).
        s0_hash = <<"s", 0>>
        got = get_in(composed, [s0_hash, new_id])

        assert got == expected,
               "composed[s0_hash][#{inspect(new_id)}] = #{inspect(got)} but sequential = #{inspect(expected)}"
      end
    end
  end

  # -------------------- Integration against real snapshotter --------------------

  describe "compose_dms/1 — real snapshot chain" do
    alias Commonplace.Store.Snapshotter
    alias Yelixer.{Doc, Encoding}
    alias Yelixer.Types.Text

    test "composes DMs produced by two successive real snapshots" do
      # S0: client 1 inserts "abc" — produces items (1,0), (1,1), (1,2) plus type-decl.
      d0 = Doc.new(client_id: 1)
      {d0, _} = Doc.get_or_create_type(d0, "t", :text)
      d0 = Text.insert(d0, "t", 0, "abc")

      # First snapshot: produces new-item-ids under the snapshot's own client id.
      {snap1_bytes, dm1_inner} = Snapshotter.build(d0)
      s0_hash = <<0xA0, 0xA0>>
      dm1 = %{s0_hash => dm1_inner}

      # Rebuild S1 from snap1 and add "de".
      {:ok, d1} = Encoding.apply_update(Doc.new(), snap1_bytes)
      {d1, _} = Doc.get_or_create_type(d1, "t", :text)
      d1 = Text.insert(d1, "t", 3, "de")

      # Second snapshot — DM2 maps S2's new ids back to S1's ids.
      {_snap2_bytes, dm2_inner} = Snapshotter.build(d1)
      s1_hash = <<0xB1, 0xB1>>
      dm2 = %{s1_hash => dm2_inner}

      composed = Namespace.compose_dms([dm1, dm2])

      # Property: for each new_id in dm2_inner, composed[s0_hash][new_id]
      # must equal the sequentially-chained lookup through dm2 → dm1.
      for {new_id_s2, mid_id_s1} <- dm2_inner do
        case Map.get(dm1_inner, mid_id_s1) do
          nil ->
            # Entry should have been dropped from composed.
            refute Map.has_key?(Map.get(composed, s0_hash, %{}), new_id_s2)

          old_id_s0 ->
            assert get_in(composed, [s0_hash, new_id_s2]) == old_id_s0
        end
      end
    end
  end
end
