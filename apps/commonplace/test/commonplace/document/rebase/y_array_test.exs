defmodule Commonplace.Document.Rebase.YArrayTest do
  use ExUnit.Case, async: true

  alias Commonplace.Document.ContentType
  alias Commonplace.Document.Rebase.YArray, as: RebaseYArray
  alias Yelixer.Doc

  defp array_doc(values) do
    doc = ContentType.create(Doc.new(), :array, "a")
    if values == [], do: doc, else: ContentType.push_items(doc, values)
  end

  describe "rebase/4 — no concurrent remote changes" do
    test "append item is applied to new_doc" do
      pre = [1, 2, 3]
      dirty = [1, 2, 3, 4]
      new_doc = array_doc(pre)

      {:ok, result} = RebaseYArray.rebase(pre, dirty, new_doc, "content")

      assert ContentType.get_content(result) == [1, 2, 3, 4]
    end

    test "prepend item is applied to new_doc" do
      pre = [2, 3]
      dirty = [1, 2, 3]
      new_doc = array_doc(pre)

      {:ok, result} = RebaseYArray.rebase(pre, dirty, new_doc, "content")

      assert ContentType.get_content(result) == [1, 2, 3]
    end

    test "insert in middle is applied to new_doc" do
      pre = [1, 2, 4]
      dirty = [1, 2, 3, 4]
      new_doc = array_doc(pre)

      {:ok, result} = RebaseYArray.rebase(pre, dirty, new_doc, "content")

      assert ContentType.get_content(result) == [1, 2, 3, 4]
    end

    test "delete at end is applied to new_doc" do
      pre = [1, 2, 3]
      dirty = [1, 2]
      new_doc = array_doc(pre)

      {:ok, result} = RebaseYArray.rebase(pre, dirty, new_doc, "content")

      assert ContentType.get_content(result) == [1, 2]
    end

    test "delete in middle is applied to new_doc" do
      pre = [1, 2, 3, 4]
      dirty = [1, 4]
      new_doc = array_doc(pre)

      {:ok, result} = RebaseYArray.rebase(pre, dirty, new_doc, "content")

      assert ContentType.get_content(result) == [1, 4]
    end

    test "mixed insert + delete" do
      pre = [1, 2, 3]
      dirty = [1, 9, 3, 4]
      new_doc = array_doc(pre)

      {:ok, result} = RebaseYArray.rebase(pre, dirty, new_doc, "content")

      assert ContentType.get_content(result) == [1, 9, 3, 4]
    end

    test "no-op when pre == dirty" do
      pre = [1, 2, 3]
      new_doc = array_doc(pre)

      {:ok, result} = RebaseYArray.rebase(pre, pre, new_doc, "content")

      assert ContentType.get_content(result) == [1, 2, 3]
    end

    test "string items diff via deep equality" do
      pre = ["a", "b", "c"]
      dirty = ["a", "x", "c"]
      new_doc = array_doc(pre)

      {:ok, result} = RebaseYArray.rebase(pre, dirty, new_doc, "content")

      assert ContentType.get_content(result) == ["a", "x", "c"]
    end

    test "empty pre with dirty insert" do
      pre = []
      dirty = [1, 2, 3]
      new_doc = array_doc([])

      {:ok, result} = RebaseYArray.rebase(pre, dirty, new_doc, "content")

      assert ContentType.get_content(result) == [1, 2, 3]
    end
  end

  describe "rebase/4 — concurrent remote changes in new_doc" do
    test "dirty append lands at end of remote-modified new_doc" do
      # Local: [1,2] → dirty appended 3 → [1,2,3]
      # Remote: [1,2,9] (concurrent append at same position)
      # Rebased: insert 3 at position 2 of [1,2,9] → [1,2,3,9]
      pre = [1, 2]
      dirty = [1, 2, 3]
      new_doc = array_doc([1, 2, 9])

      {:ok, result} = RebaseYArray.rebase(pre, dirty, new_doc, "content")

      assert ContentType.get_content(result) == [1, 2, 3, 9]
    end

    test "dirty delete of a shared item still deletes on remote-modified new_doc" do
      pre = [1, 2, 3]
      dirty = [1, 3]
      new_doc = array_doc([1, 2, 3, 9])

      {:ok, result} = RebaseYArray.rebase(pre, dirty, new_doc, "content")

      # Deletes index 1 ("2") of [1, 2, 3, 9] → [1, 3, 9]
      assert ContentType.get_content(result) == [1, 3, 9]
    end
  end

  describe "rebase/4 — all-or-nothing failure" do
    test "insert past new_doc length returns :out_of_range" do
      pre = [1, 2, 3, 4, 5]
      dirty = [1, 2, 3, 4, 5, 6]
      new_doc = array_doc([1])

      assert {:error, {:out_of_range, :insert, 5, 1}} =
               RebaseYArray.rebase(pre, dirty, new_doc, "content")
    end

    test "delete past new_doc length returns :out_of_range" do
      pre = [1, 2, 3, 4, 5]
      dirty = [1, 2, 3, 4]
      new_doc = array_doc([1, 2])

      assert {:error, {:out_of_range, :delete, 4, 1, 2}} =
               RebaseYArray.rebase(pre, dirty, new_doc, "content")
    end
  end

  describe "rebase/4 — randomized invariant" do
    test "snapshot with same content reproduces dirty list for random edits" do
      seed = :erlang.monotonic_time()
      :rand.seed(:exsss, {seed, seed + 1, seed + 2})

      for _ <- 1..200 do
        pre = random_list(0..8)
        dirty = random_edit(pre)
        new_doc = array_doc(pre)

        {:ok, result} = RebaseYArray.rebase(pre, dirty, new_doc, "content")

        assert ContentType.get_content(result) == dirty,
               "seed=#{seed}\n  pre=#{inspect(pre)}\n  dirty=#{inspect(dirty)}"
      end
    end
  end

  defp random_list(range) do
    len = Enum.random(range)
    for _ <- 1..max(len, 1), do: Enum.random(0..20)
  end

  defp random_edit(pre) do
    op =
      case length(pre) do
        0 -> :insert
        _ -> Enum.random([:insert, :insert, :delete])
      end

    case op do
      :insert ->
        pos = Enum.random(0..length(pre))
        item = Enum.random(100..200)
        List.insert_at(pre, pos, item)

      :delete ->
        pos = Enum.random(0..(length(pre) - 1))
        List.delete_at(pre, pos)
    end
  end
end
