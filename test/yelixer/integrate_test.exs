defmodule Yelixer.IntegrateTest do
  use ExUnit.Case, async: true

  alias Yelixer.{ID, Item, BlockStore, Integrate}

  defp make_item(client, clock, origin, right_origin, content \\ {:string, "x"}) do
    Item.new(ID.new(client, clock), origin, right_origin, content, {:named, "text"}, nil)
  end

  test "integrate first item into empty store" do
    item = make_item(1, 0, nil, nil)
    {:ok, store} = Integrate.integrate(BlockStore.new(), item, "text")
    assert BlockStore.get(store, ID.new(1, 0)) != nil
  end

  test "integrate item after existing item (sequential)" do
    item1 = make_item(1, 0, nil, nil)
    {:ok, store} = Integrate.integrate(BlockStore.new(), item1, "text")

    item2 = make_item(1, 1, ID.new(1, 0), nil)
    {:ok, store} = Integrate.integrate(store, item2, "text")

    seq = Integrate.sequence(store, "text")
    assert seq == ["x", "x"]
  end

  test "concurrent inserts at same position resolve by client id" do
    item_a = make_item(1, 0, nil, nil, {:string, "A"})
    item_b = make_item(2, 0, nil, nil, {:string, "B"})

    {:ok, store} = Integrate.integrate(BlockStore.new(), item_a, "text")
    {:ok, store} = Integrate.integrate(store, item_b, "text")

    seq = Integrate.sequence(store, "text")
    assert seq == ["A", "B"]
  end

  test "concurrent inserts with same origin resolve by client id" do
    origin = make_item(1, 0, nil, nil, {:string, "O"})
    {:ok, store} = Integrate.integrate(BlockStore.new(), origin, "text")

    item_a = make_item(2, 0, ID.new(1, 0), nil, {:string, "A"})
    item_b = make_item(3, 0, ID.new(1, 0), nil, {:string, "B"})

    {:ok, store} = Integrate.integrate(store, item_a, "text")
    {:ok, store} = Integrate.integrate(store, item_b, "text")

    seq = Integrate.sequence(store, "text")
    assert seq == ["O", "A", "B"]
  end

  test "interleaved concurrent edits between two items" do
    a = make_item(1, 0, nil, nil, {:string, "A"})
    b = make_item(1, 1, ID.new(1, 0), nil, {:string, "B"})

    {:ok, store} = Integrate.integrate(BlockStore.new(), a, "text")
    {:ok, store} = Integrate.integrate(store, b, "text")

    # Both X and Y have origin=A, right_origin=B
    x = make_item(2, 0, ID.new(1, 0), ID.new(1, 1), {:string, "X"})
    y = make_item(3, 0, ID.new(1, 0), ID.new(1, 1), {:string, "Y"})

    {:ok, store} = Integrate.integrate(store, x, "text")
    {:ok, store} = Integrate.integrate(store, y, "text")

    seq = Integrate.sequence(store, "text")
    assert seq == ["A", "X", "Y", "B"]
  end

  test "integration order doesn't matter — same result" do
    a = make_item(1, 0, nil, nil, {:string, "A"})
    b = make_item(1, 1, ID.new(1, 0), nil, {:string, "B"})
    x = make_item(2, 0, ID.new(1, 0), ID.new(1, 1), {:string, "X"})
    y = make_item(3, 0, ID.new(1, 0), ID.new(1, 1), {:string, "Y"})

    # Order 1: A, B, X, Y
    {:ok, s1} = Integrate.integrate(BlockStore.new(), a, "text")
    {:ok, s1} = Integrate.integrate(s1, b, "text")
    {:ok, s1} = Integrate.integrate(s1, x, "text")
    {:ok, s1} = Integrate.integrate(s1, y, "text")

    # Order 2: A, B, Y, X
    {:ok, s2} = Integrate.integrate(BlockStore.new(), a, "text")
    {:ok, s2} = Integrate.integrate(s2, b, "text")
    {:ok, s2} = Integrate.integrate(s2, y, "text")
    {:ok, s2} = Integrate.integrate(s2, x, "text")

    assert Integrate.sequence(s1, "text") == Integrate.sequence(s2, "text")
  end

  test "insert at beginning when items exist" do
    a = make_item(1, 0, nil, nil, {:string, "A"})
    {:ok, store} = Integrate.integrate(BlockStore.new(), a, "text")

    # Insert at beginning: no origin, right_origin is A
    b = make_item(2, 0, nil, ID.new(1, 0), {:string, "B"})
    {:ok, store} = Integrate.integrate(store, b, "text")

    seq = Integrate.sequence(store, "text")
    assert seq == ["B", "A"]
  end

  test "three concurrent inserts at same position" do
    a = make_item(1, 0, nil, nil, {:string, "A"})
    b = make_item(2, 0, nil, nil, {:string, "B"})
    c = make_item(3, 0, nil, nil, {:string, "C"})

    {:ok, store} = Integrate.integrate(BlockStore.new(), a, "text")
    {:ok, store} = Integrate.integrate(store, b, "text")
    {:ok, store} = Integrate.integrate(store, c, "text")

    seq = Integrate.sequence(store, "text")
    # Lower client IDs first
    assert seq == ["A", "B", "C"]
  end

  test "delete marks item as deleted and excludes from sequence" do
    a = make_item(1, 0, nil, nil, {:string, "A"})
    b = make_item(1, 1, ID.new(1, 0), nil, {:string, "B"})
    c = make_item(1, 2, ID.new(1, 1), nil, {:string, "C"})

    {:ok, store} = Integrate.integrate(BlockStore.new(), a, "text")
    {:ok, store} = Integrate.integrate(store, b, "text")
    {:ok, store} = Integrate.integrate(store, c, "text")

    store = Integrate.mark_deleted(store, ID.new(1, 1))
    seq = Integrate.sequence(store, "text")
    assert seq == ["A", "C"]
  end
end
