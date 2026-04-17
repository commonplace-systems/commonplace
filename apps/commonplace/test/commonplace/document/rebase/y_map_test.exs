defmodule Commonplace.Document.Rebase.YMapTest do
  use ExUnit.Case, async: true

  alias Commonplace.Document.ContentType
  alias Commonplace.Document.Rebase.YMap, as: RebaseYMap
  alias Yelixer.Doc

  defp map_doc(kvs) do
    doc = ContentType.create(Doc.new(), :map, "m")
    Enum.reduce(kvs, doc, fn {k, v}, d -> ContentType.set_key(d, k, v) end)
  end

  describe "rebase/4 — no concurrent remote changes" do
    test "added key is applied to new_doc" do
      pre = %{"a" => "1"}
      dirty = %{"a" => "1", "b" => "2"}
      new_doc = map_doc([{"a", "1"}])

      {:ok, result} = RebaseYMap.rebase(pre, dirty, new_doc, "content")

      assert ContentType.get_content(result) == %{"a" => "1", "b" => "2"}
    end

    test "removed key is applied to new_doc" do
      pre = %{"a" => "1", "b" => "2"}
      dirty = %{"a" => "1"}
      new_doc = map_doc([{"a", "1"}, {"b", "2"}])

      {:ok, result} = RebaseYMap.rebase(pre, dirty, new_doc, "content")

      assert ContentType.get_content(result) == %{"a" => "1"}
    end

    test "modified primitive value is applied to new_doc" do
      pre = %{"x" => "foo"}
      dirty = %{"x" => "bar"}
      new_doc = map_doc([{"x", "foo"}])

      {:ok, result} = RebaseYMap.rebase(pre, dirty, new_doc, "content")

      assert ContentType.get_content(result) == %{"x" => "bar"}
    end

    test "multiple adds, removes, and modifications together" do
      pre = %{"a" => "1", "b" => "2", "c" => "3"}
      dirty = %{"a" => "1", "b" => "two", "d" => "4"}
      new_doc = map_doc([{"a", "1"}, {"b", "2"}, {"c", "3"}])

      {:ok, result} = RebaseYMap.rebase(pre, dirty, new_doc, "content")

      assert ContentType.get_content(result) == %{"a" => "1", "b" => "two", "d" => "4"}
    end

    test "no-op when pre == dirty" do
      pre = %{"a" => "1"}
      new_doc = map_doc([{"a", "1"}])

      {:ok, result} = RebaseYMap.rebase(pre, pre, new_doc, "content")

      assert ContentType.get_content(result) == %{"a" => "1"}
    end

    test "type change on a key (string -> integer) is applied" do
      pre = %{"count" => "5"}
      dirty = %{"count" => 5}
      new_doc = map_doc([{"count", "5"}])

      {:ok, result} = RebaseYMap.rebase(pre, dirty, new_doc, "content")

      assert ContentType.get_content(result) == %{"count" => 5}
    end
  end

  describe "rebase/4 — concurrent remote changes in new_doc" do
    test "dirty-added key lands on remote-modified new_doc" do
      # Local pre: {a: 1}. Dirty adds b=2. Remote snapshot: {a: 100}.
      # After rebase: {a: 100, b: 2}.
      pre = %{"a" => "1"}
      dirty = %{"a" => "1", "b" => "2"}
      new_doc = map_doc([{"a", "100"}])

      {:ok, result} = RebaseYMap.rebase(pre, dirty, new_doc, "content")

      assert ContentType.get_content(result) == %{"a" => "100", "b" => "2"}
    end

    test "dirty-removed key leaves remote-modified keys alone" do
      pre = %{"a" => "1", "b" => "2"}
      dirty = %{"a" => "1"}
      new_doc = map_doc([{"a", "ALPHA"}, {"b", "BETA"}, {"c", "GAMMA"}])

      {:ok, result} = RebaseYMap.rebase(pre, dirty, new_doc, "content")

      # "b" is the only key locally removed; "c" (never in pre) stays.
      assert ContentType.get_content(result) == %{"a" => "ALPHA", "c" => "GAMMA"}
    end

    test "dirty-modified key overwrites remote value (last-write-wins by local intent)" do
      pre = %{"x" => "v1"}
      dirty = %{"x" => "local"}
      new_doc = map_doc([{"x", "remote"}])

      {:ok, result} = RebaseYMap.rebase(pre, dirty, new_doc, "content")

      # Local dirty edit was an explicit rewrite to "local"; replaying it
      # as a fresh set wins over the remote value.
      assert ContentType.get_content(result) == %{"x" => "local"}
    end
  end

  describe "rebase/4 — randomized invariant" do
    # Property: when new_doc has the *same* observable content as old
    # (pure-compaction case — no concurrent remote changes), rebasing a
    # dirty edit reproduces the dirty map exactly.
    test "snapshot with same content reproduces dirty content for random edits" do
      seed = :erlang.monotonic_time()
      :rand.seed(:exsss, {seed, seed + 1, seed + 2})

      for _ <- 1..200 do
        pre = random_map(0..6)
        dirty = random_edit(pre)
        new_doc = map_doc(Enum.to_list(pre))

        {:ok, result} = RebaseYMap.rebase(pre, dirty, new_doc, "content")

        assert ContentType.get_content(result) == dirty,
               "seed=#{seed}\n  pre=#{inspect(pre)}\n  dirty=#{inspect(dirty)}"
      end
    end
  end

  defp random_map(range) do
    count = Enum.random(range)

    for _ <- 1..max(count, 1), into: %{} do
      {random_key(), random_value()}
    end
    |> then(fn m -> if count == 0, do: %{}, else: m end)
  end

  defp random_key do
    <<Enum.random(?a..?z), Enum.random(?a..?z)>>
  end

  defp random_value do
    case Enum.random([:str, :int, :bool]) do
      :str -> <<Enum.random(?a..?z), Enum.random(?a..?z), Enum.random(?a..?z)>>
      :int -> Enum.random(0..100)
      :bool -> Enum.random([true, false])
    end
  end

  defp random_edit(pre) do
    op =
      case Map.keys(pre) do
        [] -> :add
        _ -> Enum.random([:add, :add, :remove, :modify])
      end

    case op do
      :add ->
        Map.put(pre, random_key(), random_value())

      :remove ->
        k = Enum.random(Map.keys(pre))
        Map.delete(pre, k)

      :modify ->
        k = Enum.random(Map.keys(pre))
        Map.put(pre, k, random_value())
    end
  end
end
