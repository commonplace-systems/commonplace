defmodule Yelixer.UpdateEncodingTest do
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Types.Text, Types.Array, Encoding, StateVector, BlockStore}

  test "encode and decode update roundtrip — text" do
    doc1 = Doc.new(client_id: 1)
    {doc1, _} = Doc.get_or_create_type(doc1, "text", :text)
    doc1 = Text.insert(doc1, "text", 0, "hello")

    update = Encoding.encode_update(doc1)
    assert is_binary(update)

    doc2 = Doc.new(client_id: 2)
    {doc2, _} = Doc.get_or_create_type(doc2, "text", :text)
    {:ok, doc2} = Encoding.apply_update(doc2, update)

    assert Text.to_string(doc2, "text") == "hello"
  end

  test "encode and decode update roundtrip — array" do
    doc1 = Doc.new(client_id: 1)
    {doc1, _} = Doc.get_or_create_type(doc1, "arr", :array)
    doc1 = Array.insert(doc1, "arr", 0, [1, 2, 3])

    update = Encoding.encode_update(doc1)

    doc2 = Doc.new(client_id: 2)
    {doc2, _} = Doc.get_or_create_type(doc2, "arr", :array)
    {:ok, doc2} = Encoding.apply_update(doc2, update)

    assert Array.to_list(doc2, "arr") == [1, 2, 3]
  end

  test "sync two text docs" do
    doc1 = Doc.new(client_id: 1)
    doc2 = Doc.new(client_id: 2)
    {doc1, _} = Doc.get_or_create_type(doc1, "text", :text)
    {doc2, _} = Doc.get_or_create_type(doc2, "text", :text)

    doc1 = Text.insert(doc1, "text", 0, "hello ")
    doc2 = Text.insert(doc2, "text", 0, "world")

    update1 = Encoding.encode_update(doc1)
    update2 = Encoding.encode_update(doc2)

    {:ok, doc1} = Encoding.apply_update(doc1, update2)
    {:ok, doc2} = Encoding.apply_update(doc2, update1)

    text1 = Text.to_string(doc1, "text")
    text2 = Text.to_string(doc2, "text")
    assert text1 == text2
  end

  test "state vector encodes correctly from doc" do
    doc = Doc.new(client_id: 1)
    {doc, _} = Doc.get_or_create_type(doc, "text", :text)
    doc = Text.insert(doc, "text", 0, "hi")

    sv = BlockStore.state_vector(doc.store)
    assert StateVector.get(sv, 1) == 2
  end

  test "encode_diff only includes items after remote state vector" do
    doc = Doc.new(client_id: 1)
    {doc, _} = Doc.get_or_create_type(doc, "text", :text)
    doc = Text.insert(doc, "text", 0, "hello")

    # Capture state vector after first insert
    sv_after_hello = BlockStore.state_vector(doc.store)

    # Add more text
    doc = Text.insert(doc, "text", 5, " world")

    # Diff should only contain " world", not "hello"
    diff = Encoding.encode_diff(doc, sv_after_hello)

    doc2 = Doc.new(client_id: 2)
    {doc2, _} = Doc.get_or_create_type(doc2, "text", :text)

    # First sync the "hello" part
    {:ok, _doc2} = Encoding.apply_update(doc2, Encoding.encode_update(doc))
    # Verify the diff is smaller than full update.
    full_update = Encoding.encode_update(doc)
    assert byte_size(diff) < byte_size(full_update)
  end

  test "encode_diff produces valid update for incremental sync" do
    doc1 = Doc.new(client_id: 1)
    {doc1, _} = Doc.get_or_create_type(doc1, "text", :text)
    doc1 = Text.insert(doc1, "text", 0, "hello")

    # doc2 syncs with doc1 (full state)
    doc2 = Doc.new(client_id: 2)
    {doc2, _} = Doc.get_or_create_type(doc2, "text", :text)
    {:ok, doc2} = Encoding.apply_update(doc2, Encoding.encode_update(doc1))
    assert Text.to_string(doc2, "text") == "hello"

    # doc1 makes more edits
    doc1 = Text.insert(doc1, "text", 5, " world")

    # doc2 requests diff from its state vector
    sv2 = BlockStore.state_vector(doc2.store)
    diff = Encoding.encode_diff(doc1, sv2)

    # Apply diff to doc2
    {:ok, doc2} = Encoding.apply_update(doc2, diff)
    assert Text.to_string(doc2, "text") == "hello world"
  end

  test "encode_diff with empty remote state vector equals full update" do
    doc = Doc.new(client_id: 1)
    {doc, _} = Doc.get_or_create_type(doc, "text", :text)
    doc = Text.insert(doc, "text", 0, "test")

    full = Encoding.encode_update(doc)
    diff = Encoding.encode_diff(doc, StateVector.new())
    assert full == diff
  end

  test "encode_diff with multiple clients" do
    doc1 = Doc.new(client_id: 1)
    {doc1, _} = Doc.get_or_create_type(doc1, "text", :text)
    doc1 = Text.insert(doc1, "text", 0, "a")

    doc2 = Doc.new(client_id: 2)
    {doc2, _} = Doc.get_or_create_type(doc2, "text", :text)
    doc2 = Text.insert(doc2, "text", 0, "b")

    # Sync both into doc1
    {:ok, doc1} = Encoding.apply_update(doc1, Encoding.encode_update(doc2))

    # Remote knows about client 1's "a" but not client 2's "b"
    remote_sv = StateVector.new() |> StateVector.set(1, 1)
    diff = Encoding.encode_diff(doc1, remote_sv)

    # Apply diff to a fresh doc
    doc3 = Doc.new(client_id: 3)
    {doc3, _} = Doc.get_or_create_type(doc3, "text", :text)
    {:ok, doc3} = Encoding.apply_update(doc3, diff)

    # Should only have "b" from client 2
    assert Text.to_string(doc3, "text") == "b"
  end

  test "applying same update twice is idempotent" do
    doc1 = Doc.new(client_id: 1)
    {doc1, _} = Doc.get_or_create_type(doc1, "text", :text)
    doc1 = Text.insert(doc1, "text", 0, "abc")

    update = Encoding.encode_update(doc1)

    doc2 = Doc.new(client_id: 2)
    {doc2, _} = Doc.get_or_create_type(doc2, "text", :text)

    {:ok, doc2} = Encoding.apply_update(doc2, update)
    text_once = Text.to_string(doc2, "text")

    {:ok, doc2} = Encoding.apply_update(doc2, update)
    text_twice = Text.to_string(doc2, "text")

    assert text_once == text_twice
  end
end
