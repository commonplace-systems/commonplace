defmodule Commonplace.Store.DerivationMapInverseTest do
  @moduledoc """
  CX-2rd (Build 6.2): `Commonplace.Store.Namespace.inverse_derivation_map/1`
  flips every inner `{new_id => old_id}` to `{old_id => new_id}`, leaving
  the outer keyed-by-source_snapshot_hash structure unchanged.

  The inverse map is the core primitive used by Build 6.3 (op-reference
  rewriting) and Build 7.3 (cross-epoch merge) to translate item IDs
  from a snapshot's namespace back to its source namespaces.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Store.Namespace

  doctest Commonplace.Store.Namespace, only: [inverse_derivation_map: 1]

  describe "inverse_derivation_map/1" do
    test "empty outer map returns empty outer map" do
      assert Namespace.inverse_derivation_map(%{}) == %{}
    end

    test "single source with empty inner map returns same shape" do
      hash = <<1, 2, 3>>
      assert Namespace.inverse_derivation_map(%{hash => %{}}) == %{hash => %{}}
    end

    test "single source with single entry flips new_id → old_id" do
      hash = <<1, 2, 3>>
      new_id = {42, 0}
      old_id = {99, 7}

      input = %{hash => %{new_id => old_id}}
      expected = %{hash => %{old_id => new_id}}

      assert Namespace.inverse_derivation_map(input) == expected
    end

    test "single source with multiple entries flips every pair" do
      hash = <<9, 9, 9>>

      input = %{
        hash => %{
          {1, 0} => {100, 0},
          {1, 1} => {100, 1},
          {1, 2} => {100, 2}
        }
      }

      expected = %{
        hash => %{
          {100, 0} => {1, 0},
          {100, 1} => {1, 1},
          {100, 2} => {1, 2}
        }
      }

      assert Namespace.inverse_derivation_map(input) == expected
    end

    test "multi-source outer map inverts each inner independently" do
      hash_a = <<0xAA>>
      hash_b = <<0xBB>>

      input = %{
        hash_a => %{{1, 0} => {10, 0}, {1, 1} => {10, 1}},
        hash_b => %{{2, 0} => {20, 0}, {2, 1} => {20, 1}}
      }

      expected = %{
        hash_a => %{{10, 0} => {1, 0}, {10, 1} => {1, 1}},
        hash_b => %{{20, 0} => {2, 0}, {20, 1} => {2, 1}}
      }

      assert Namespace.inverse_derivation_map(input) == expected
    end

    test "inversion is involutive — invert(invert(x)) == x" do
      hash = <<0xC0, 0xFF, 0xEE>>

      original = %{
        hash => %{
          {1, 5} => {99, 2},
          {1, 6} => {99, 3},
          {2, 0} => {50, 0}
        }
      }

      assert Namespace.inverse_derivation_map(
               Namespace.inverse_derivation_map(original)
             ) == original
    end

    test "does not mutate outer keys" do
      keys = [<<1>>, <<2>>, <<3>>]
      input = Map.new(keys, fn k -> {k, %{{1, 0} => {2, 0}}} end)
      result = Namespace.inverse_derivation_map(input)
      assert Map.keys(result) |> Enum.sort() == keys
    end
  end
end
