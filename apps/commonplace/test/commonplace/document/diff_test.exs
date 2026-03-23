defmodule Commonplace.Document.DiffTest do
  use ExUnit.Case

  alias Commonplace.Document.Diff
  alias Commonplace.Document.ContentType

  describe "diff/2" do
    test "no changes returns empty list" do
      assert Diff.diff("hello", "hello") == []
    end

    test "empty strings return empty list" do
      assert Diff.diff("", "") == []
    end

    test "insert at end" do
      edits = Diff.diff("hello", "hello world")
      assert length(edits) > 0
      assert Enum.any?(edits, fn {op, _, _} -> op == :insert end)
    end

    test "delete from end" do
      edits = Diff.diff("hello world", "hello")
      assert length(edits) > 0
      assert Enum.any?(edits, fn {op, _, _} -> op == :delete end)
    end

    test "replacement produces both delete and insert" do
      edits = Diff.diff("cat", "hat")
      assert Enum.any?(edits, fn {op, _, _} -> op == :delete end)
      assert Enum.any?(edits, fn {op, _, _} -> op == :insert end)
    end

    test "insert into empty string" do
      edits = Diff.diff("", "hello")
      assert edits == [{:insert, 0, "hello"}]
    end

    test "delete entire string" do
      edits = Diff.diff("hello", "")
      assert edits == [{:delete, 0, 5}]
    end

    test "single character insert in middle" do
      edits = Diff.diff("ab", "axb")
      assert edits == [{:insert, 1, "x"}]
    end

    test "single character delete in middle" do
      edits = Diff.diff("axb", "ab")
      assert edits == [{:delete, 1, 1}]
    end
  end

  describe "apply_diff/3" do
    defp make_text_doc(content) do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :text, "test.txt")

      if content != "" do
        ContentType.insert_text(doc, 0, content)
      else
        doc
      end
    end

    test "transforms document content with mixed edits" do
      doc = make_text_doc("hello world")

      doc = Diff.apply_diff(doc, "hello world", "hello there")
      assert ContentType.get_content(doc) == "hello there"
    end

    test "handles insertion in middle" do
      doc = make_text_doc("ab")

      doc = Diff.apply_diff(doc, "ab", "axb")
      assert ContentType.get_content(doc) == "axb"
    end

    test "handles deletion in middle" do
      doc = make_text_doc("abc")

      doc = Diff.apply_diff(doc, "abc", "ac")
      assert ContentType.get_content(doc) == "ac"
    end

    test "handles complete replacement" do
      doc = make_text_doc("foo")

      doc = Diff.apply_diff(doc, "foo", "bar")
      assert ContentType.get_content(doc) == "bar"
    end

    test "handles empty to content" do
      doc = make_text_doc("")

      doc = Diff.apply_diff(doc, "", "new content")
      assert ContentType.get_content(doc) == "new content"
    end

    test "handles content to empty" do
      doc = make_text_doc("old content")

      doc = Diff.apply_diff(doc, "old content", "")
      assert ContentType.get_content(doc) == ""
    end

    test "no-op when content unchanged" do
      doc = make_text_doc("same")

      doc = Diff.apply_diff(doc, "same", "same")
      assert ContentType.get_content(doc) == "same"
    end

    test "handles insertion at beginning" do
      doc = make_text_doc("world")

      doc = Diff.apply_diff(doc, "world", "hello world")
      assert ContentType.get_content(doc) == "hello world"
    end

    test "handles insertion at end" do
      doc = make_text_doc("hello")

      doc = Diff.apply_diff(doc, "hello", "hello world")
      assert ContentType.get_content(doc) == "hello world"
    end

    test "handles multiple scattered edits" do
      doc = make_text_doc("the quick brown fox")

      doc = Diff.apply_diff(doc, "the quick brown fox", "a slow red dog")
      assert ContentType.get_content(doc) == "a slow red dog"
    end

    test "handles unicode graphemes" do
      doc = make_text_doc("cafe")

      doc = Diff.apply_diff(doc, "cafe", "cafe\u0301")
      assert ContentType.get_content(doc) == "cafe\u0301"
    end

    test "handles multiline text" do
      old = "line one\nline two\nline three"
      new = "line one\nline 2\nline three\nline four"
      doc = make_text_doc(old)

      doc = Diff.apply_diff(doc, old, new)
      assert ContentType.get_content(doc) == new
    end
  end
end
