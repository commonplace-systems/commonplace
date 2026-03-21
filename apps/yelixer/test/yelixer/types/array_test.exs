defmodule Yelixer.Types.ArrayTest do
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Types.Array}

  defp new_doc(client_id) do
    doc = Doc.new(client_id: client_id)
    {doc, _} = Doc.get_or_create_type(doc, "arr", :array)
    doc
  end

  test "insert and read elements" do
    doc = new_doc(1)
    doc = Array.insert(doc, "arr", 0, [1, 2, 3])
    assert Array.to_list(doc, "arr") == [1, 2, 3]
  end

  test "insert at index" do
    doc = new_doc(1)
    doc = Array.insert(doc, "arr", 0, ["a", "b"])
    doc = Array.insert(doc, "arr", 1, ["x"])
    assert Array.to_list(doc, "arr") == ["a", "x", "b"]
  end

  test "insert at end" do
    doc = new_doc(1)
    doc = Array.insert(doc, "arr", 0, [1, 2])
    doc = Array.insert(doc, "arr", 2, [3])
    assert Array.to_list(doc, "arr") == [1, 2, 3]
  end

  test "delete elements" do
    doc = new_doc(1)
    doc = Array.insert(doc, "arr", 0, [1, 2, 3, 4])
    doc = Array.delete(doc, "arr", 1, 2)
    assert Array.to_list(doc, "arr") == [1, 4]
  end

  test "length" do
    doc = new_doc(1)
    doc = Array.insert(doc, "arr", 0, [1, 2, 3])
    assert Array.length(doc, "arr") == 3
  end

  test "empty array" do
    doc = new_doc(1)
    assert Array.to_list(doc, "arr") == []
    assert Array.length(doc, "arr") == 0
  end

  test "push appends to end" do
    doc = new_doc(1)
    doc = Array.push(doc, "arr", [1, 2])
    doc = Array.push(doc, "arr", [3])
    assert Array.to_list(doc, "arr") == [1, 2, 3]
  end
end
