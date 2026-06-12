defmodule Commonplace.Outline.OrderTest do
  @moduledoc """
  CX-saix(i): fractional-index order keys (outliner.md §4). A key can
  always be minted strictly between any two neighbors with NO replica
  coordination; ties on equal keys resolve via the `(order, id)`
  comparator so every replica derives the identical sibling order.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Outline.Order

  test "between(nil, nil) mints a key" do
    key = Order.between(nil, nil)
    assert is_binary(key) and key != ""
  end

  test "between(nil, right) is strictly before right" do
    right = Order.between(nil, nil)
    key = Order.between(nil, right)
    assert key < right
  end

  test "between(left, nil) is strictly after left" do
    left = Order.between(nil, nil)
    key = Order.between(left, nil)
    assert key > left
  end

  test "between(left, right) is strictly between, for randomized pairs" do
    for _ <- 1..200 do
      a = Order.between(nil, nil)
      b = Order.between(a, nil)
      {l, r} = if a < b, do: {a, b}, else: {b, a}
      mid = Order.between(l, r)
      assert l < mid and mid < r, "expected #{l} < #{mid} < #{r}"
    end
  end

  test "repeated bisection stays sorted and key growth is bounded" do
    # Bisect the same gap 300 times — the pathological case.
    {keys, _} =
      Enum.reduce(1..300, {[], {nil, nil}}, fn _, {acc, {l, r}} ->
        k = Order.between(l, r)
        {[k | acc], {l, k}}
      end)

    # Bisecting toward zero: each new key is strictly SMALLER, so the
    # newest-first list is ascending and all keys are distinct.
    assert Enum.sort(keys) == keys
    assert length(Enum.uniq(keys)) == length(keys)

    # Bounded growth: linear-ish in insert count, not explosive.
    assert String.length(hd(keys)) <= 320
  end

  test "repeated append (tail inserts) stays sorted with short keys" do
    keys =
      Enum.reduce(1..300, [], fn _, acc ->
        prev = List.first(acc)
        [Order.between(prev, nil) | acc]
      end)

    assert Enum.sort(keys) == Enum.reverse(keys)
    assert String.length(hd(keys)) <= 16
  end

  test "compare/2 orders by key then id (the deterministic tiebreak)" do
    assert Order.compare({"a0", "id2"}, {"a1", "id1"}) == :lt
    assert Order.compare({"a1", "id1"}, {"a0", "id2"}) == :gt
    assert Order.compare({"a0", "id1"}, {"a0", "id2"}) == :lt
    assert Order.compare({"a0", "id2"}, {"a0", "id1"}) == :gt
    assert Order.compare({"a0", "id1"}, {"a0", "id1"}) == :eq
  end

  test "sort with the comparator is total and stable across permutations" do
    items = [{"a1", "x"}, {"a0", "z"}, {"a0", "a"}, {"a2", "m"}, {"a0", "z"}]

    sorted = Enum.sort(items, &(Order.compare(&1, &2) != :gt))

    for perm <- [Enum.reverse(items), Enum.shuffle(items)] do
      assert Enum.sort(perm, &(Order.compare(&1, &2) != :gt)) == sorted
    end
  end
end
