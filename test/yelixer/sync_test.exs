defmodule Yelixer.SyncTest do
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Types.Text, Types.Array, Types.YMap, Encoding}

  defp new_text_doc(client_id) do
    doc = Doc.new(client_id: client_id)
    {doc, _} = Doc.get_or_create_type(doc, "text", :text)
    doc
  end

  describe "text sync" do
    test "two peers sync and converge" do
      doc1 = new_text_doc(1)
      doc2 = new_text_doc(2)

      doc1 = Text.insert(doc1, "text", 0, "hello ")
      doc2 = Text.insert(doc2, "text", 0, "world")

      update1 = Encoding.encode_update(doc1)
      update2 = Encoding.encode_update(doc2)

      {:ok, doc1} = Encoding.apply_update(doc1, update2)
      {:ok, doc2} = Encoding.apply_update(doc2, update1)

      text1 = Text.to_string(doc1, "text")
      text2 = Text.to_string(doc2, "text")
      assert text1 == text2
      # Lower client ID first
      assert text1 == "hello world"
    end

    test "three-way sync converges" do
      doc1 = new_text_doc(1)
      doc2 = new_text_doc(2)
      doc3 = new_text_doc(3)

      doc1 = Text.insert(doc1, "text", 0, "A")
      doc2 = Text.insert(doc2, "text", 0, "B")
      doc3 = Text.insert(doc3, "text", 0, "C")

      u1 = Encoding.encode_update(doc1)
      u2 = Encoding.encode_update(doc2)
      u3 = Encoding.encode_update(doc3)

      {:ok, doc1} = Encoding.apply_update(doc1, u2)
      {:ok, doc1} = Encoding.apply_update(doc1, u3)
      {:ok, doc2} = Encoding.apply_update(doc2, u1)
      {:ok, doc2} = Encoding.apply_update(doc2, u3)
      {:ok, doc3} = Encoding.apply_update(doc3, u1)
      {:ok, doc3} = Encoding.apply_update(doc3, u2)

      t1 = Text.to_string(doc1, "text")
      t2 = Text.to_string(doc2, "text")
      t3 = Text.to_string(doc3, "text")

      assert t1 == t2
      assert t2 == t3
    end

    test "sequential edits from same peer sync correctly" do
      doc1 = new_text_doc(1)
      doc1 = Text.insert(doc1, "text", 0, "hello")
      doc1 = Text.insert(doc1, "text", 5, " world")

      update = Encoding.encode_update(doc1)

      doc2 = new_text_doc(2)
      {:ok, doc2} = Encoding.apply_update(doc2, update)
      assert Text.to_string(doc2, "text") == "hello world"
    end

    test "applying same update twice is idempotent" do
      doc1 = new_text_doc(1)
      doc1 = Text.insert(doc1, "text", 0, "abc")
      update = Encoding.encode_update(doc1)

      doc2 = new_text_doc(2)
      {:ok, doc2} = Encoding.apply_update(doc2, update)
      text1 = Text.to_string(doc2, "text")
      {:ok, doc2} = Encoding.apply_update(doc2, update)
      text2 = Text.to_string(doc2, "text")
      assert text1 == text2
    end
  end

  describe "array sync" do
    test "two peers sync arrays and converge" do
      doc1 = Doc.new(client_id: 1)
      doc2 = Doc.new(client_id: 2)
      {doc1, _} = Doc.get_or_create_type(doc1, "arr", :array)
      {doc2, _} = Doc.get_or_create_type(doc2, "arr", :array)

      doc1 = Array.insert(doc1, "arr", 0, [1, 2])
      doc2 = Array.insert(doc2, "arr", 0, [3, 4])

      u1 = Encoding.encode_update(doc1)
      u2 = Encoding.encode_update(doc2)

      {:ok, doc1} = Encoding.apply_update(doc1, u2)
      {:ok, doc2} = Encoding.apply_update(doc2, u1)

      assert Array.to_list(doc1, "arr") == Array.to_list(doc2, "arr")
    end
  end

  describe "map sync" do
    test "concurrent map edits use last-write-wins" do
      doc1 = Doc.new(client_id: 1)
      doc2 = Doc.new(client_id: 2)
      {doc1, _} = Doc.get_or_create_type(doc1, "m", :map)
      {doc2, _} = Doc.get_or_create_type(doc2, "m", :map)

      doc1 = YMap.set(doc1, "m", "key", "from_1")
      doc2 = YMap.set(doc2, "m", "key", "from_2")

      u1 = Encoding.encode_update(doc1)
      u2 = Encoding.encode_update(doc2)

      {:ok, doc1} = Encoding.apply_update(doc1, u2)
      {:ok, doc2} = Encoding.apply_update(doc2, u1)

      # Both should converge to same value
      assert YMap.get(doc1, "m", "key") == YMap.get(doc2, "m", "key")
    end
  end
end
