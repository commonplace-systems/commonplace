defmodule Yelixer.DocTest do
  use ExUnit.Case, async: true

  alias Yelixer.Doc

  test "creates a new doc with a client id" do
    doc = Doc.new(client_id: 1)
    assert doc.client_id == 1
  end

  test "auto-generates client id if not provided" do
    doc = Doc.new()
    assert is_integer(doc.client_id)
    assert doc.client_id > 0
  end

  test "get_or_create_type registers a root type" do
    {doc, _ref} = Doc.new(client_id: 1) |> Doc.get_or_create_type("text", :text)
    assert Doc.has_type?(doc, "text")
  end

  test "get_or_create_type returns existing type on second call" do
    {doc, ref1} = Doc.new(client_id: 1) |> Doc.get_or_create_type("text", :text)
    {_doc, ref2} = Doc.get_or_create_type(doc, "text", :text)
    assert ref1 == ref2
  end

  test "multiple types can coexist" do
    doc = Doc.new(client_id: 1)
    {doc, _} = Doc.get_or_create_type(doc, "text", :text)
    {doc, _} = Doc.get_or_create_type(doc, "arr", :array)
    {doc, _} = Doc.get_or_create_type(doc, "map", :map)
    assert Doc.has_type?(doc, "text")
    assert Doc.has_type?(doc, "arr")
    assert Doc.has_type?(doc, "map")
  end
end
