defmodule Commonplace.Document.Rebase.YTextTest do
  use ExUnit.Case, async: true

  alias Commonplace.Document.ContentType
  alias Commonplace.Document.Rebase.YText, as: RebaseYText
  alias Yelixer.Doc

  defp text_doc(content) do
    doc = ContentType.create(Doc.new(), :text, "t")
    if content == "", do: doc, else: ContentType.insert_text(doc, 0, content)
  end

  describe "rebase/4 — no concurrent remote changes" do
    test "insert in middle is applied to new_doc" do
      # old committed: "Hello world"
      # dirty: inserted " beautiful" after "Hello" → "Hello beautiful world"
      # new_doc from snapshot: same observable content as old ("Hello world")
      pre = "Hello world"
      dirty = "Hello beautiful world"
      new_doc = text_doc(pre)

      {:ok, result} = RebaseYText.rebase(pre, dirty, new_doc, "content")

      assert ContentType.get_content(result) == "Hello beautiful world"
    end

    test "delete in middle is applied to new_doc" do
      pre = "Hello cruel world"
      dirty = "Hello world"
      new_doc = text_doc(pre)

      {:ok, result} = RebaseYText.rebase(pre, dirty, new_doc, "content")

      assert ContentType.get_content(result) == "Hello world"
    end

    test "insert at end" do
      pre = "Hello"
      dirty = "Hello!"
      new_doc = text_doc(pre)

      {:ok, result} = RebaseYText.rebase(pre, dirty, new_doc, "content")

      assert ContentType.get_content(result) == "Hello!"
    end

    test "no-op when no dirty edits (pre == dirty)" do
      pre = "Hello world"
      new_doc = text_doc(pre)

      {:ok, result} = RebaseYText.rebase(pre, pre, new_doc, "content")

      assert ContentType.get_content(result) == "Hello world"
    end

    test "multibyte characters rebase by grapheme position" do
      # Emoji sits at grapheme index 5, preceded by 5 ASCII chars
      pre = "Hello 🌍 world"
      dirty = "Hello 🌍 beautiful world"
      new_doc = text_doc(pre)

      {:ok, result} = RebaseYText.rebase(pre, dirty, new_doc, "content")

      assert ContentType.get_content(result) == "Hello 🌍 beautiful world"
    end
  end

  describe "rebase/4 — concurrent remote changes in new_doc" do
    test "insert lands at position that still exists in new_doc" do
      # Local: "Hello world" → dirty insert "beautiful " at 6 → "Hello beautiful world"
      # Remote snapshot: "Hello there world" (replaced content but position 6 still valid)
      pre = "Hello world"
      dirty = "Hello beautiful world"
      new_doc = text_doc("Hello there world")

      {:ok, result} = RebaseYText.rebase(pre, dirty, new_doc, "content")

      # Insert at position 6 of "Hello there world" (which is 'r' of "there")
      # → "Hello beautiful there world"
      assert ContentType.get_content(result) == "Hello beautiful there world"
    end
  end

  describe "rebase/4 — randomized invariant" do
    # Property: when new_doc has the *same* observable content as old
    # (the pure-compaction case — remote made no concurrent changes),
    # rebasing a dirty edit reproduces the dirty content exactly.
    # Covers the primary Phase 1 correctness invariant across many
    # (pre, dirty) shapes without needing a property-testing lib.
    test "snapshot with same content reproduces dirty content for random edits" do
      seed = :erlang.monotonic_time()
      :rand.seed(:exsss, {seed, seed + 1, seed + 2})

      for _ <- 1..200 do
        pre = random_text(0..40)
        dirty = random_edit(pre)
        new_doc = text_doc(pre)

        {:ok, result} = RebaseYText.rebase(pre, dirty, new_doc, "content")

        assert ContentType.get_content(result) == dirty,
               "seed=#{seed}\n  pre=#{inspect(pre)}\n  dirty=#{inspect(dirty)}"
      end
    end
  end

  defp random_text(range) do
    len = Enum.random(range)

    Enum.map_join(1..max(len, 1), "", fn _ -> <<Enum.random(?a..?z)>> end)
    |> String.slice(0, len)
  end

  defp random_edit(pre) do
    case {Enum.random([:insert, :delete, :insert, :insert]), String.length(pre)} do
      {_, 0} ->
        # Can only insert into empty
        pos = 0
        pre |> String.graphemes() |> insert_at(pos, random_text(1..10))

      {:insert, n} ->
        pos = Enum.random(0..n)
        pre |> String.graphemes() |> insert_at(pos, random_text(1..10))

      {:delete, n} ->
        pos = Enum.random(0..(n - 1))
        len = Enum.random(1..(n - pos))
        pre |> String.graphemes() |> delete_at(pos, len)
    end
  end

  defp insert_at(graphemes, pos, text) do
    {before, rest} = Enum.split(graphemes, pos)
    Enum.join(before) <> text <> Enum.join(rest)
  end

  defp delete_at(graphemes, pos, len) do
    {before, rest} = Enum.split(graphemes, pos)
    {_, tail} = Enum.split(rest, len)
    Enum.join(before) <> Enum.join(tail)
  end

  describe "rebase/4 — all-or-nothing failure" do
    test "returns {:error, :out_of_range} when insert position exceeds new_doc length" do
      # Local pre-snapshot: "Hello world" (11 chars). Dirty inserts at end: "Hello world!"
      # Remote snapshot drastically shortened: "Hi" (2 chars).
      # Insert at position 11 is beyond new_doc length (2).
      pre = "Hello world"
      dirty = "Hello world!"
      new_doc = text_doc("Hi")

      assert {:error, {:out_of_range, :insert, 11, 2}} =
               RebaseYText.rebase(pre, dirty, new_doc, "content")
    end

    test "returns {:error, :out_of_range} when delete range exceeds new_doc length" do
      # Dirty deletes " world" (pos 5, len 6) from "Hello world" → "Hello"
      # Remote snapshot trimmed to "Hell" (4 chars).
      # Delete at pos 5 exceeds new_doc length.
      pre = "Hello world"
      dirty = "Hello"
      new_doc = text_doc("Hell")

      assert {:error, {:out_of_range, :delete, 5, 6, 4}} =
               RebaseYText.rebase(pre, dirty, new_doc, "content")
    end
  end
end
