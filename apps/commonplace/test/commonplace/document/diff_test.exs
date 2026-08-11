defmodule Commonplace.Document.DiffTest do
  use ExUnit.Case

  alias Commonplace.Document.Diff
  alias Commonplace.Document.ContentType

  describe "diff/2" do
    test "large append completes within the sized budget" do
      old = String.duplicate("a", 100_000)
      tail = String.duplicate("b", 9_000)

      task = Task.async(fn -> Diff.diff(old, old <> tail) end)

      assert {:ok, [{:insert, 100_000, ^tail}]} =
               Task.yield(task, 5_000) || Task.shutdown(task)
    end

    test "no changes returns empty list" do
      assert Diff.diff("hello", "hello") == []
    end

    test "empty strings return empty list" do
      assert Diff.diff("", "") == []
    end

    test "insert at end" do
      assert Diff.diff("hello", "hello world") == [{:insert, 5, " world"}]
    end

    test "insert at beginning" do
      assert Diff.diff("world", "hello world") == [{:insert, 0, "hello "}]
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

    test "middle replacement edits stay inside the changed span" do
      edits = Diff.diff("prefix-OLD-suffix", "prefix-NEW-suffix")

      assert Enum.all?(edits, fn
               {:delete, index, length} -> index >= 7 and index + length <= 10
               {:insert, index, _text} -> index >= 7 and index <= 10
             end)
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

    test "round-trips representative edit and grapheme-boundary shapes" do
      cases = [
        {"base", "base tail"},
        {"base", "head base"},
        {"prefix OLD suffix", "prefix NEW suffix"},
        {"everything", "nothing in common"},
        {"same", "same"},
        {"", "content"},
        {"content", ""},
        {"aeXz", "ae\u0301Yz"},
        {"aXe\u0301", "aYe\u0301"},
        {"a\rX", "a\r\nX"},
        {"x👩‍👧a", "x👩‍👦a"},
        {"x🇺🇸a", "x🇯🇵a"}
      ]

      for {old, new} <- cases do
        doc = old |> make_text_doc() |> Diff.apply_diff(old, new)
        assert ContentType.get_content(doc) == new
      end
    end
  end

  describe "grapheme-accurate cursor advance (CX-r1f)" do
    defp make_text_doc_for_grapheme_test(content) do
      doc = Yelixer.Doc.new(client_id: 1)
      doc = ContentType.create(doc, :text, "test.txt")

      if content != "" do
        ContentType.insert_text(doc, 0, content)
      else
        doc
      end
    end

    @tag :grapheme_bug
    test "combining mark: e + U+0301 inserted from empty" do
      doc = make_text_doc_for_grapheme_test("")

      target = "caf" <> <<"e"::utf8, 0x0301::utf8>>
      doc = Diff.apply_diff(doc, "", target)

      assert ContentType.get_content(doc) == target
    end

    @tag :grapheme_bug
    test "ZWJ family emoji: insert then append exclamation" do
      initial = "before "
      doc = make_text_doc_for_grapheme_test(initial)

      step1 = "before \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} after"
      doc = Diff.apply_diff(doc, initial, step1)
      assert ContentType.get_content(doc) == step1

      step2 = step1 <> "!"
      doc = Diff.apply_diff(doc, step1, step2)
      assert ContentType.get_content(doc) == step2
    end

    @tag :grapheme_bug
    test "regional indicators: two flag emoji in sequence" do
      initial = "visited "
      doc = make_text_doc_for_grapheme_test(initial)

      step1 = "visited \u{1F1FA}\u{1F1F8}"
      doc = Diff.apply_diff(doc, initial, step1)
      assert ContentType.get_content(doc) == step1

      step2 = "visited \u{1F1FA}\u{1F1F8} and \u{1F1EF}\u{1F1F5}"
      doc = Diff.apply_diff(doc, step1, step2)
      assert ContentType.get_content(doc) == step2
    end

    @tag :grapheme_bug
    test "no-op fast path still returns [] for combining-mark string" do
      s = "caf" <> <<"e"::utf8, 0x0301::utf8>>
      assert Diff.diff(s, s) == []
    end
  end
end
