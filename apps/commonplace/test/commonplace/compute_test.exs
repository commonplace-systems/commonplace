defmodule Commonplace.ComputeTest do
  @moduledoc """
  CX-dhde (sub-bead ii of CX-a9cv M7): substrate-tier author-facing
  helpers for compute fns.

  Round-1 design principle: Commonplace.Compute.* is AUTHOR-FACING
  (atom-flavored, Elixir-native shapes); substrate-tier modules retain
  JSON-flavored shapes (string keys, nested maps) because data-on-wire
  is JSON. Compute stdlib bridges via thin adapters.

  Tests cover decode_json_array + the chain-rules adapter for
  materialize.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Compute

  describe "decode_json_array/1" do
    test "decodes a list of JSON-encoded entries to maps" do
      raw = [
        Jason.encode!(%{"id" => "a", "x" => 1}),
        Jason.encode!(%{"id" => "b", "x" => 2})
      ]

      assert [%{"id" => "a", "x" => 1}, %{"id" => "b", "x" => 2}] =
               Compute.decode_json_array(raw)
    end

    test "raises on invalid JSON (Jason error propagates)" do
      assert_raise Jason.DecodeError, fn ->
        Compute.decode_json_array(["not-json"])
      end
    end

    test "empty list returns empty list" do
      assert [] == Compute.decode_json_array([])
    end
  end

  describe "materialize/2 — chain-rules adapter (round-1 (α))" do
    test "accepts author-friendly tuple form, adapts to substrate map form" do
      entries = [
        %{"id" => "m1", "text" => "v1", "ts" => "T0"},
        %{"id" => "m2", "text" => "v2", "ts" => "T1", "edit_of" => "m1"}
      ]

      # Author-facing form: tuple {atom_field, semantics_atom}
      result = Compute.materialize(entries, chains: [{:edit_of, :latest_replaces}])

      # Should produce the same as substrate Materialize.materialize/2
      # called with the verbose JSON-flavored shape.
      [m1] = result
      assert m1["id"] == "m1"
      assert m1["text"] == "v2", "edit chain tip's text should win"
      assert m1["edited?"] == true
    end

    test "multiple chains in tuple form work" do
      entries = [
        %{"id" => "m1", "text" => "secret", "ts" => "T0"},
        %{"id" => "m2", "text" => "v2", "ts" => "T1", "edit_of" => "m1"},
        %{"id" => "m3", "ts" => "T2", "tombstone_of" => "m1"}
      ]

      result =
        Compute.materialize(entries,
          chains: [
            {:edit_of, :latest_replaces},
            {:tombstone_of, :marks_deleted}
          ]
        )

      [m1] = result
      assert m1["edited?"] == true
      assert m1["deleted?"] == true
      assert m1["text"] == "v2"
    end

    test "delegation produces same output as direct Materialize.materialize call" do
      entries = [
        %{"id" => "m1", "text" => "a", "ts" => "T0"},
        %{"id" => "m2", "text" => "b", "ts" => "T1", "edit_of" => "m1"}
      ]

      via_compute = Compute.materialize(entries, chains: [{:edit_of, :latest_replaces}])

      via_substrate =
        Commonplace.Materialize.materialize(entries, %{
          chains: [%{field: "edit_of", semantics: :latest_replaces}]
        })

      assert via_compute == via_substrate
    end

    test "no chains: vacuous adapter passes through cleanly" do
      entries = [
        %{"id" => "m1", "text" => "alone", "ts" => "T0"}
      ]

      result = Compute.materialize(entries, chains: [])
      [m1] = result
      assert m1["id"] == "m1"
      assert m1["text"] == "alone"
    end

    test "empty entries: returns empty list" do
      assert [] == Compute.materialize([], chains: [])
    end
  end
end
