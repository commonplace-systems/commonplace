defmodule Commonplace.Document.Rebase.YXmlTest do
  use ExUnit.Case, async: true

  alias Commonplace.Document.ContentType
  alias Commonplace.Document.Rebase.YXml, as: RebaseYXml
  alias Yelixer.Doc
  alias Yelixer.Types.{XMLElement, XMLFragment, XMLText}

  # --- Helpers ---

  defp xml_doc(), do: ContentType.create(Doc.new(), :xml, "t")

  # Build a fragment by appending children using {:element, tag, attrs, child_specs}
  # | {:text, string} | {:fragment, child_specs} tree-literals. Keeps tests readable.
  defp build(spec) do
    doc = xml_doc()
    {doc, _} = build_into(doc, "content", spec)
    doc
  end

  defp build_into(doc, parent_name, children) when is_list(children) do
    Enum.reduce(children, {doc, 0}, fn child, {d, idx} ->
      d = insert_child_at(d, parent_name, idx, child)
      {d, idx + 1}
    end)
  end

  defp insert_child_at(doc, parent_name, idx, {:element, tag, attrs, grandchildren}) do
    doc = fragment_or_element_insert(doc, parent_name, idx, {:element, tag})
    child_name = last_child_name(doc, parent_name)
    doc = Enum.reduce(attrs, doc, fn {k, v}, d -> XMLElement.set_attribute(d, child_name, k, v) end)
    {doc, _} = build_into(doc, child_name, grandchildren)
    doc
  end

  defp insert_child_at(doc, parent_name, idx, {:text, string}) do
    doc = fragment_or_element_insert(doc, parent_name, idx, :text)
    child_name = last_child_name(doc, parent_name)
    if string == "", do: doc, else: XMLText.insert(doc, child_name, 0, string)
  end

  defp fragment_or_element_insert(doc, parent_name, idx, spec) do
    case doc.types[parent_name] do
      :xml_fragment -> XMLFragment.insert_child(doc, parent_name, idx, spec)
      {:xml_element, _} -> XMLElement.insert_child(doc, parent_name, idx, spec)
    end
  end

  defp last_child_name(doc, parent_name) do
    children =
      case doc.types[parent_name] do
        :xml_fragment -> XMLFragment.to_list(doc, parent_name)
        {:xml_element, _} -> XMLElement.children(doc, parent_name)
      end

    case List.last(children) do
      {:element, _tag, name} -> name
      {:text, name} -> name
    end
  end

  # --- Tests ---

  describe "rebase/3 — no dirty edits" do
    test "pre == dirty returns new_doc unchanged content" do
      pre = []
      dirty = []
      new_doc = build([{:element, "p", %{}, []}])

      {:ok, result} = RebaseYXml.rebase(pre, dirty, new_doc, "content")
      assert ContentType.get_content(result) == [{:element, "p", %{}, []}]
    end
  end

  describe "rebase/3 — structural inserts" do
    test "dirty appends an element at root" do
      pre = []
      dirty = [{:element, "p", %{}, []}]
      new_doc = xml_doc()

      {:ok, result} = RebaseYXml.rebase(pre, dirty, new_doc, "content")
      assert ContentType.get_content(result) == [{:element, "p", %{}, []}]
    end

    test "dirty inserts element between remote elements" do
      pre = [{:element, "h1", %{}, []}, {:element, "p", %{}, []}]
      dirty = [{:element, "h1", %{}, []}, {:element, "h2", %{}, []}, {:element, "p", %{}, []}]
      new_doc = build([{:element, "h1", %{}, []}, {:element, "p", %{}, []}])

      {:ok, result} = RebaseYXml.rebase(pre, dirty, new_doc, "content")

      assert ContentType.get_content(result) == [
               {:element, "h1", %{}, []},
               {:element, "h2", %{}, []},
               {:element, "p", %{}, []}
             ]
    end

    test "dirty appends a text leaf at root" do
      pre = []
      dirty = [{:text, "hi"}]
      new_doc = xml_doc()

      {:ok, result} = RebaseYXml.rebase(pre, dirty, new_doc, "content")
      assert ContentType.get_content(result) == [{:text, "hi"}]
    end
  end

  describe "rebase/3 — structural deletes" do
    test "dirty removes a root element" do
      pre = [{:element, "h1", %{}, []}, {:element, "p", %{}, []}]
      dirty = [{:element, "p", %{}, []}]
      new_doc = build([{:element, "h1", %{}, []}, {:element, "p", %{}, []}])

      {:ok, result} = RebaseYXml.rebase(pre, dirty, new_doc, "content")
      assert ContentType.get_content(result) == [{:element, "p", %{}, []}]
    end

    test "dirty removes middle element" do
      pre = [
        {:element, "a", %{}, []},
        {:element, "b", %{}, []},
        {:element, "c", %{}, []}
      ]

      dirty = [{:element, "a", %{}, []}, {:element, "c", %{}, []}]
      new_doc = build(pre)

      {:ok, result} = RebaseYXml.rebase(pre, dirty, new_doc, "content")
      assert ContentType.get_content(result) == dirty
    end
  end

  describe "rebase/3 — attribute changes" do
    test "dirty adds an attribute on an existing element" do
      pre = [{:element, "p", %{}, []}]
      dirty = [{:element, "p", %{"class" => "note"}, []}]
      new_doc = build(pre)

      {:ok, result} = RebaseYXml.rebase(pre, dirty, new_doc, "content")
      assert ContentType.get_content(result) == dirty
    end

    test "dirty modifies an attribute" do
      pre = [{:element, "p", %{"class" => "old"}, []}]
      dirty = [{:element, "p", %{"class" => "new"}, []}]
      new_doc = build(pre)

      {:ok, result} = RebaseYXml.rebase(pre, dirty, new_doc, "content")
      assert ContentType.get_content(result) == dirty
    end

    test "dirty removes an attribute" do
      pre = [{:element, "p", %{"class" => "note", "id" => "p1"}, []}]
      dirty = [{:element, "p", %{"id" => "p1"}, []}]
      new_doc = build(pre)

      {:ok, result} = RebaseYXml.rebase(pre, dirty, new_doc, "content")
      assert ContentType.get_content(result) == dirty
    end
  end

  describe "rebase/3 — text leaf edits" do
    test "dirty edits text inside an element via YText diff" do
      pre = [{:element, "p", %{}, [{:text, "hello"}]}]
      dirty = [{:element, "p", %{}, [{:text, "hello world"}]}]
      new_doc = build(pre)

      {:ok, result} = RebaseYXml.rebase(pre, dirty, new_doc, "content")
      assert ContentType.get_content(result) == dirty
    end
  end

  describe "rebase/3 — nested recursion" do
    test "dirty adds a child element inside an existing element" do
      pre = [{:element, "div", %{}, []}]
      dirty = [{:element, "div", %{}, [{:element, "p", %{}, []}]}]
      new_doc = build(pre)

      {:ok, result} = RebaseYXml.rebase(pre, dirty, new_doc, "content")
      assert ContentType.get_content(result) == dirty
    end

    test "dirty modifies attributes deep in the tree" do
      pre = [{:element, "div", %{}, [{:element, "p", %{}, []}]}]
      dirty = [{:element, "div", %{}, [{:element, "p", %{"class" => "x"}, []}]}]
      new_doc = build(pre)

      {:ok, result} = RebaseYXml.rebase(pre, dirty, new_doc, "content")
      assert ContentType.get_content(result) == dirty
    end
  end

  describe "rebase/3 — concurrent remote changes in new_doc" do
    test "dirty insert + remote insert at different positions both preserved" do
      pre = [{:element, "a", %{}, []}]
      dirty = [{:element, "a", %{}, []}, {:element, "b", %{}, []}]
      # Remote independently appended an element at the end.
      new_doc = build([{:element, "a", %{}, []}, {:element, "z", %{}, []}])

      {:ok, result} = RebaseYXml.rebase(pre, dirty, new_doc, "content")
      # Dirty's append at position 1 lands before remote's z (positional).
      assert ContentType.get_content(result) == [
               {:element, "a", %{}, []},
               {:element, "b", %{}, []},
               {:element, "z", %{}, []}
             ]
    end

    test "dirty attribute change preserved alongside remote sibling add" do
      pre = [{:element, "p", %{}, []}]
      dirty = [{:element, "p", %{"class" => "x"}, []}]
      new_doc = build([{:element, "p", %{}, []}, {:element, "q", %{}, []}])

      {:ok, result} = RebaseYXml.rebase(pre, dirty, new_doc, "content")
      assert ContentType.get_content(result) == [
               {:element, "p", %{"class" => "x"}, []},
               {:element, "q", %{}, []}
             ]
    end
  end
end
