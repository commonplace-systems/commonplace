defmodule Yelixer.GCTest do
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Types.Text, Encoding, BlockStore}

  defp new_doc(client_id) do
    doc = Doc.new(client_id: client_id)
    {doc, _} = Doc.get_or_create_type(doc, "text", :text)
    doc
  end

  test "gc replaces deleted items with gc blocks" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "hello world")
    doc = Text.delete(doc, "text", 5, 6)

    assert Text.to_string(doc, "text") == "hello"

    # Run GC
    doc = Doc.gc(doc)

    # Text should still be correct
    assert Text.to_string(doc, "text") == "hello"

    # Deleted items should be replaced with {:gc, _} blocks
    blocks = BlockStore.client_blocks(doc.store, 1)
    gc_blocks = Enum.filter(blocks, fn item -> match?({:gc, _}, item.content) end)
    assert length(gc_blocks) > 0
  end

  test "gc blocks are idempotent" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "abc")
    doc = Text.delete(doc, "text", 0, 3)

    doc = Doc.gc(doc)
    text1 = Text.to_string(doc, "text")

    doc = Doc.gc(doc)
    text2 = Text.to_string(doc, "text")

    assert text1 == text2
    assert text1 == ""
  end

  test "update from gc'd doc can be applied" do
    doc1 = new_doc(1)
    doc1 = Text.insert(doc1, "text", 0, "hello world")
    doc1 = Text.delete(doc1, "text", 5, 6)
    doc1 = Doc.gc(doc1)

    update = Encoding.encode_update(doc1)

    doc2 = new_doc(2)
    {:ok, doc2} = Encoding.apply_update(doc2, update)
    assert Text.to_string(doc2, "text") == "hello"
  end

  test "decode gc blocks from Yjs gc-enabled update" do
    # Create a fixture that simulates a Yjs gc: true doc
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "abcdef")
    doc = Text.delete(doc, "text", 2, 2)
    doc = Doc.gc(doc)

    # Encode and re-decode
    update = Encoding.encode_update(doc)
    doc2 = new_doc(2)
    {:ok, doc2} = Encoding.apply_update(doc2, update)
    assert Text.to_string(doc2, "text") == "abef"
  end
end
