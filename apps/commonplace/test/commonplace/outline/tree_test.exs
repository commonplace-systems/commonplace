defmodule Commonplace.Outline.TreeTest do
  @moduledoc """
  CX-sugc: pure tree reconstruction from the flat bag (outliner.md §4-5).
  Orphan/cycle handling is DISPLAY-ONLY — the input is never mutated and
  nothing is written back (a mutating auto-fix would have every viewing
  replica racing to rewrite the same parent).
  """
  use ExUnit.Case, async: true

  alias Commonplace.Outline.Tree

  defp item(id, parent, order, opts \\ []) do
    %{
      id: id,
      parent: parent,
      order: order,
      collapsed: Keyword.get(opts, :collapsed, false),
      text: Keyword.get(opts, :text, id)
    }
  end

  test "reconstructs nesting from parent attributes, ordered by (order, id)" do
    items = [
      item("c", "a", "a1"),
      item("a", "", "V"),
      item("b", "a", "a0"),
      item("d", "b", "V")
    ]

    assert [%{item: %{id: "a"}, children: [b_node, c_node]}] = Tree.reconstruct(items)
    assert %{item: %{id: "b"}, children: [%{item: %{id: "d"}, children: []}]} = b_node
    assert %{item: %{id: "c"}, children: []} = c_node
  end

  test "equal order keys tiebreak by id deterministically" do
    items = [item("z", "", "V"), item("a", "", "V")]
    assert [%{item: %{id: "a"}}, %{item: %{id: "z"}}] = Tree.reconstruct(items)
  end

  test "an orphan (parent points at a missing id) re-roots for display, input untouched" do
    items = [item("a", "", "V"), item("lost", "deadbeef", "V")]

    roots = Tree.reconstruct(items)
    assert Enum.map(roots, & &1.item.id) |> Enum.sort() == ["a", "lost"]

    # Input untouched — the stored parent stays as-is.
    assert Enum.find(items, &(&1.id == "lost")).parent == "deadbeef"
  end

  test "a 2-cycle re-roots both nodes (with their subtrees intact)" do
    items = [
      item("x", "y", "V"),
      item("y", "x", "V"),
      item("under_x", "x", "V"),
      item("a", "", "V")
    ]

    roots = Tree.reconstruct(items)
    root_ids = Enum.map(roots, & &1.item.id) |> Enum.sort()
    # x and y both unreachable → both re-rooted; a is a normal root.
    assert root_ids == ["a", "x", "y"]

    x_node = Enum.find(roots, &(&1.item.id == "x"))
    assert [%{item: %{id: "under_x"}}] = x_node.children
  end

  test "stable across permuted input order" do
    items = [
      item("a", "", "V"),
      item("b", "a", "a0"),
      item("c", "a", "a1"),
      item("d", "c", "V")
    ]

    reference = Tree.reconstruct(items)

    for _ <- 1..10 do
      assert Tree.reconstruct(Enum.shuffle(items)) == reference
    end
  end

  test "empty bag → empty forest" do
    assert Tree.reconstruct([]) == []
  end
end
