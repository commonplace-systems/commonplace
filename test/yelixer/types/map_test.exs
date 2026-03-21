defmodule Yelixer.Types.MapTest do
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Types.YMap}

  defp new_doc(client_id) do
    doc = Doc.new(client_id: client_id)
    {doc, _} = Doc.get_or_create_type(doc, "m", :map)
    doc
  end

  test "set and get values" do
    doc = new_doc(1)
    doc = YMap.set(doc, "m", "key", "value")
    assert YMap.get(doc, "m", "key") == "value"
  end

  test "overwrite a key" do
    doc = new_doc(1)
    doc = YMap.set(doc, "m", "key", "v1")
    doc = YMap.set(doc, "m", "key", "v2")
    assert YMap.get(doc, "m", "key") == "v2"
  end

  test "delete a key" do
    doc = new_doc(1)
    doc = YMap.set(doc, "m", "key", "value")
    doc = YMap.delete(doc, "m", "key")
    assert YMap.get(doc, "m", "key") == nil
  end

  test "to_map returns all entries" do
    doc = new_doc(1)
    doc = YMap.set(doc, "m", "a", 1)
    doc = YMap.set(doc, "m", "b", 2)
    assert YMap.to_map(doc, "m") == %{"a" => 1, "b" => 2}
  end

  test "missing key returns nil" do
    doc = new_doc(1)
    assert YMap.get(doc, "m", "missing") == nil
  end

  test "has_key?" do
    doc = new_doc(1)
    doc = YMap.set(doc, "m", "key", "value")
    assert YMap.has_key?(doc, "m", "key")
    refute YMap.has_key?(doc, "m", "other")
  end
end
