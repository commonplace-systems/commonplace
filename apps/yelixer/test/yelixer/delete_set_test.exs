defmodule Yelixer.DeleteSetTest do
  use ExUnit.Case, async: true

  alias Yelixer.DeleteSet

  test "new delete set is empty" do
    ds = DeleteSet.new()
    refute DeleteSet.deleted?(ds, 1, 0)
  end

  test "insert a range and query it" do
    ds = DeleteSet.new() |> DeleteSet.insert(1, 5, 3)
    assert DeleteSet.deleted?(ds, 1, 5)
    assert DeleteSet.deleted?(ds, 1, 6)
    assert DeleteSet.deleted?(ds, 1, 7)
    refute DeleteSet.deleted?(ds, 1, 4)
    refute DeleteSet.deleted?(ds, 1, 8)
  end

  test "merge overlapping ranges" do
    ds =
      DeleteSet.new()
      |> DeleteSet.insert(1, 0, 3)
      |> DeleteSet.insert(1, 2, 4)

    # Should cover 0..5
    assert DeleteSet.deleted?(ds, 1, 0)
    assert DeleteSet.deleted?(ds, 1, 5)
    refute DeleteSet.deleted?(ds, 1, 6)
  end

  test "merge two delete sets" do
    ds1 = DeleteSet.new() |> DeleteSet.insert(1, 0, 3)
    ds2 = DeleteSet.new() |> DeleteSet.insert(1, 5, 2)
    merged = DeleteSet.merge(ds1, ds2)
    assert DeleteSet.deleted?(merged, 1, 0)
    assert DeleteSet.deleted?(merged, 1, 2)
    assert DeleteSet.deleted?(merged, 1, 5)
    assert DeleteSet.deleted?(merged, 1, 6)
    refute DeleteSet.deleted?(merged, 1, 3)
  end

  test "adjacent ranges merge" do
    ds =
      DeleteSet.new()
      |> DeleteSet.insert(1, 0, 3)
      |> DeleteSet.insert(1, 3, 2)

    # Should cover 0..4
    assert DeleteSet.deleted?(ds, 1, 0)
    assert DeleteSet.deleted?(ds, 1, 4)
    refute DeleteSet.deleted?(ds, 1, 5)
  end

  test "multiple clients" do
    ds =
      DeleteSet.new()
      |> DeleteSet.insert(1, 0, 3)
      |> DeleteSet.insert(2, 10, 5)

    assert DeleteSet.deleted?(ds, 1, 0)
    assert DeleteSet.deleted?(ds, 2, 12)
    refute DeleteSet.deleted?(ds, 1, 10)
    refute DeleteSet.deleted?(ds, 2, 0)
  end
end
