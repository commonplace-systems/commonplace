defmodule Commonplace.Document.RebaseTest do
  use ExUnit.Case, async: true

  alias Commonplace.Document.ContentType
  alias Commonplace.Document.Rebase
  alias Yelixer.Doc

  defp text_doc(content) do
    doc = ContentType.create(Doc.new(), :text, "t")
    if content == "", do: doc, else: ContentType.insert_text(doc, 0, content)
  end

  defp map_doc(kvs) do
    doc = ContentType.create(Doc.new(), :map, "m")
    Enum.reduce(kvs, doc, fn {k, v}, d -> ContentType.set_key(d, k, v) end)
  end

  describe "rebase/3 — YText content (phase 1)" do
    test "applies dirty text edits to new_doc" do
      pre = text_doc("Hello world")
      dirty = text_doc("Hello beautiful world")
      new_doc = text_doc("Hello world")

      {:ok, result} = Rebase.rebase(pre, dirty, new_doc)

      assert ContentType.get_content(result) == "Hello beautiful world"
    end

    test "returns new_doc unchanged when there are no dirty edits" do
      pre = text_doc("Hello world")
      dirty = text_doc("Hello world")
      # new_doc has the remote snapshot's view — a different string.
      new_doc = text_doc("Hello from the other side")

      {:ok, result} = Rebase.rebase(pre, dirty, new_doc)

      assert ContentType.get_content(result) == "Hello from the other side"
    end

    test "propagates out-of-range error from YText rebase" do
      pre = text_doc("Hello world")
      dirty = text_doc("Hello world!")
      new_doc = text_doc("Hi")

      assert {:error, {:out_of_range, :insert, 11, 2}} = Rebase.rebase(pre, dirty, new_doc)
    end
  end

  describe "rebase/3 — unsupported types (phase 1)" do
    test "map content with dirty edits returns :unsupported_type error" do
      pre = map_doc([{"a", "1"}])
      dirty = map_doc([{"a", "2"}])
      new_doc = map_doc([{"a", "1"}])

      assert {:error, {:unsupported_type, :map}} = Rebase.rebase(pre, dirty, new_doc)
    end

    test "map content with no dirty edits passes through new_doc" do
      # Phase 1 hasn't implemented YMap rebase, but if there's nothing to
      # rebase, the snapshot should still apply cleanly. Otherwise every
      # map/schema snapshot would be aborted.
      pre = map_doc([{"a", "1"}])
      dirty = map_doc([{"a", "1"}])
      new_doc = map_doc([{"a", "2"}])

      {:ok, result} = Rebase.rebase(pre, dirty, new_doc)

      assert ContentType.get_content(result) == %{"a" => "2"}
    end
  end
end
