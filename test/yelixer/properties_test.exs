defmodule Yelixer.PropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Yelixer.{Doc, Types.Text, Encoding}

  @moduletag :properties

  property "two peers always converge regardless of insert content" do
    check all text1 <- string(:alphanumeric, min_length: 1, max_length: 10),
              text2 <- string(:alphanumeric, min_length: 1, max_length: 10) do
      doc1 = Doc.new(client_id: 1)
      doc2 = Doc.new(client_id: 2)
      {doc1, _} = Doc.get_or_create_type(doc1, "text", :text)
      {doc2, _} = Doc.get_or_create_type(doc2, "text", :text)

      doc1 = Text.insert(doc1, "text", 0, text1)
      doc2 = Text.insert(doc2, "text", 0, text2)

      u1 = Encoding.encode_update(doc1)
      u2 = Encoding.encode_update(doc2)

      {:ok, doc1} = Encoding.apply_update(doc1, u2)
      {:ok, doc2} = Encoding.apply_update(doc2, u1)

      assert Text.to_string(doc1, "text") == Text.to_string(doc2, "text")
    end
  end

  property "applying same update twice is idempotent" do
    check all text <- string(:alphanumeric, min_length: 1, max_length: 10) do
      doc1 = Doc.new(client_id: 1)
      {doc1, _} = Doc.get_or_create_type(doc1, "text", :text)
      doc1 = Text.insert(doc1, "text", 0, text)
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

  property "encode/decode roundtrip preserves text content" do
    check all text <- string(:alphanumeric, min_length: 1, max_length: 20) do
      doc1 = Doc.new(client_id: 1)
      {doc1, _} = Doc.get_or_create_type(doc1, "text", :text)
      doc1 = Text.insert(doc1, "text", 0, text)

      update = Encoding.encode_update(doc1)

      doc2 = Doc.new(client_id: 2)
      {doc2, _} = Doc.get_or_create_type(doc2, "text", :text)
      {:ok, doc2} = Encoding.apply_update(doc2, update)

      assert Text.to_string(doc2, "text") == text
    end
  end

  property "three peers always converge" do
    check all t1 <- string(:alphanumeric, min_length: 1, max_length: 5),
              t2 <- string(:alphanumeric, min_length: 1, max_length: 5),
              t3 <- string(:alphanumeric, min_length: 1, max_length: 5) do
      docs =
        [{1, t1}, {2, t2}, {3, t3}]
        |> Enum.map(fn {id, text} ->
          doc = Doc.new(client_id: id)
          {doc, _} = Doc.get_or_create_type(doc, "text", :text)
          Text.insert(doc, "text", 0, text)
        end)

      updates = Enum.map(docs, &Encoding.encode_update/1)

      # Apply all updates to all docs
      synced_docs =
        Enum.map(docs, fn doc ->
          Enum.reduce(updates, doc, fn update, d ->
            {:ok, d} = Encoding.apply_update(d, update)
            d
          end)
        end)

      texts = Enum.map(synced_docs, &Text.to_string(&1, "text"))

      # All must converge
      assert Enum.uniq(texts) |> length() == 1
    end
  end
end
