defmodule Commonplace.Tree.ForkManifestTest do
  use ExUnit.Case

  alias Commonplace.Tree.ForkManifest

  test "new creates manifest with source UUID" do
    m = ForkManifest.new("source-uuid")
    assert m.forked_from == "source-uuid"
    assert m.id != nil
    assert map_size(m.document_map) == 0
  end

  test "add_entry tracks document mapping" do
    m = ForkManifest.new("source")
    m = ForkManifest.add_entry(m, "new-1", "orig-1", <<1, 2, 3>>)
    m = ForkManifest.add_entry(m, "new-2", "orig-2", <<4, 5, 6>>)

    assert map_size(m.document_map) == 2
    assert m.document_map["new-1"].original_uuid == "orig-1"
    assert m.document_map["new-2"].original_uuid == "orig-2"
  end

  test "to_map serializes correctly" do
    m = ForkManifest.new("source")
    m = ForkManifest.add_entry(m, "new-1", "orig-1", <<1, 2, 3>>)

    map = ForkManifest.to_map(m)
    assert map["forked_from"] == "source"
    assert map["document_map"]["new-1"]["original_uuid"] == "orig-1"
    assert is_binary(map["forked_at"])
  end
end
