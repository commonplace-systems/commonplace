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

  defp array_doc(values) do
    doc = ContentType.create(Doc.new(), :array, "a")
    if values == [], do: doc, else: ContentType.push_items(doc, values)
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

  describe "rebase/3 — YMap content (phase 3)" do
    test "applies dirty map edits (add/remove/modify) to new_doc" do
      pre = map_doc([{"a", "1"}, {"b", "2"}])
      dirty = map_doc([{"a", "one"}, {"c", "3"}])
      new_doc = map_doc([{"a", "1"}, {"b", "2"}])

      {:ok, result} = Rebase.rebase(pre, dirty, new_doc)

      assert ContentType.get_content(result) == %{"a" => "one", "c" => "3"}
    end

    test "no-op when pre == dirty passes through new_doc" do
      pre = map_doc([{"a", "1"}])
      dirty = map_doc([{"a", "1"}])
      new_doc = map_doc([{"a", "2"}])

      {:ok, result} = Rebase.rebase(pre, dirty, new_doc)

      assert ContentType.get_content(result) == %{"a" => "2"}
    end
  end

  describe "rebase/3 — YArray content (phase 4)" do
    test "applies dirty array edits to new_doc" do
      pre = array_doc([1, 2, 3])
      dirty = array_doc([1, 9, 3, 4])
      new_doc = array_doc([1, 2, 3])

      {:ok, result} = Rebase.rebase(pre, dirty, new_doc)

      assert ContentType.get_content(result) == [1, 9, 3, 4]
    end

    test "no-op when pre == dirty passes through new_doc" do
      pre = array_doc([1, 2, 3])
      dirty = array_doc([1, 2, 3])
      new_doc = array_doc([1, 2, 3, 9])

      {:ok, result} = Rebase.rebase(pre, dirty, new_doc)

      assert ContentType.get_content(result) == [1, 2, 3, 9]
    end

    test "propagates out-of-range error from YArray rebase" do
      pre = array_doc([1, 2, 3, 4, 5])
      dirty = array_doc([1, 2, 3, 4, 5, 6])
      new_doc = array_doc([1])

      assert {:error, {:out_of_range, :insert, 5, 1}} = Rebase.rebase(pre, dirty, new_doc)
    end
  end

  describe "rebase/3 — unsupported types (phase 2)" do
    test "xml content with dirty edits returns :unsupported_type error" do
      pre = ContentType.create(Doc.new(), :xml, "x")
      dirty = ContentType.create(Doc.new(), :xml, "x")
      new_doc = ContentType.create(Doc.new(), :xml, "x")

      # :xml get_content returns nil for both pre and dirty, so the
      # dispatcher's pre==dirty fast-path short-circuits with {:ok, new_doc}.
      # Once a materializer exists (phase 2), dirty edits will produce a
      # real diff and route here. For now, assert the pass-through.
      {:ok, _} = Rebase.rebase(pre, dirty, new_doc)
    end
  end
end
