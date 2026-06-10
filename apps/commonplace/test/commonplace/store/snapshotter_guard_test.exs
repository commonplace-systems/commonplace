defmodule Commonplace.Store.SnapshotterGuardTest do
  @moduledoc """
  CX-tdkq.5 (architecture-review R5): the snapshot guard. A doc carrying
  CRDT sub-types nested inside maps/arrays cannot be snapshotted without
  silently losing their state (`Yelixer.Doc.snapshot_update/1` drops them).
  `Snapshotter.build_payload/2` refuses such a snapshot — converting a
  delayed data-loss trap into a visible no-op — while still building the
  payload normally for the JSON-blob convention every current data model
  follows.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Store.{Commit, Snapshotter}
  alias Yelixer.Doc

  defp parent_commit, do: Commit.genesis("doc-guard-test")

  test "builds a payload for a normal (JSON-blob convention) doc" do
    doc = Doc.new(client_id: 3)
    {doc, _} = Doc.get_or_create_type(doc, "_messages", :array)
    doc = Yelixer.Types.Array.push(doc, "_messages", [Jason.encode!(%{"id" => "m1"})])

    assert {:ok, update_bytes, metadata} = Snapshotter.build_payload(doc, parent_commit())
    assert is_binary(update_bytes)
    assert metadata.snapshotter_version == Snapshotter.snapshotter_version()
    assert Map.has_key?(metadata, :derivation_map)
  end

  test "refuses to snapshot a doc with nested map/array sub-types" do
    base = Doc.new(client_id: 3)
    # A `__sub:` type is what snapshot_update/1 would drop. (No commonplace
    # facade mints these today — that's the point of the guard: catch the
    # future feature that naively nests a YMap before its first snapshot
    # loses data.)
    doc = %Doc{base | types: Map.put(base.types, "__sub:5:3", :map)}

    assert {:error, {:nested_subtypes, ["__sub:5:3"]}} =
             Snapshotter.build_payload(doc, parent_commit())
  end

  test "an empty doc snapshots fine" do
    assert {:ok, _bytes, _meta} = Snapshotter.build_payload(Doc.new(), parent_commit())
  end
end
