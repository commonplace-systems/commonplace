defmodule Commonplace.Outline.Tree do
  @moduledoc """
  Pure tree reconstruction from the flat bag of items (CX-sugc,
  outliner.md §4-§5).

  The TREE is never stored — it is a rendering of the primary
  parent-pointer facts. `reconstruct/1` groups items by `parent`, sorts
  each sibling group by `(order, id)` (the deterministic tiebreak), and
  attaches children recursively from the top-level roots.

  Defensive handling is DISPLAY-ONLY and never mutating: any item not
  reachable from a root — a `parent` pointing at a deleted/missing id,
  or a move-cycle (`X→Y→X`, the one pathology LWW-parent admits) — is
  re-rooted to top level FOR THIS RENDER. The stored `parent` stays
  as-is; a pure function re-run on every render means replicas converge
  as commits arrive, with no write-storm of competing auto-fixes. The
  academically-correct Kleppmann cycle-safe move is a follow-up
  (CX-liim) that refines how `parent` WRITES are applied — this module
  is unaffected by it.
  """

  alias Commonplace.Outline.Order

  @type node_t :: %{item: map(), children: [node_t()]}

  @doc """
  Build the display forest from materialized items
  (`Outline.items/2` shape). Returns ordered root nodes, each
  `%{item: item, children: [...]}`.
  """
  @spec reconstruct([map()]) :: [node_t()]
  def reconstruct(items) do
    by_parent = Enum.group_by(items, & &1.parent)
    ids = MapSet.new(items, & &1.id)

    reachable = reach(by_parent, "", MapSet.new())

    # Re-root only the TOPMOST unreachable items: one whose parent is
    # missing from the bag entirely, or a cycle member (every cycle
    # member re-roots; their non-cycle descendants hang beneath them).
    orphans =
      items
      |> Enum.reject(&MapSet.member?(reachable, &1.id))
      |> Enum.filter(fn it ->
        not MapSet.member?(ids, it.parent) or in_cycle?(it, items)
      end)

    orphan_ids = MapSet.new(orphans, & &1.id)
    roots = Map.get(by_parent, "", []) ++ orphans

    roots
    |> sort_siblings()
    |> Enum.map(&build_node(&1, by_parent, orphan_ids, MapSet.new()))
  end

  # --- internals ---

  defp reach(by_parent, parent_id, acc) do
    Map.get(by_parent, parent_id, [])
    |> Enum.reduce(acc, fn item, acc ->
      if MapSet.member?(acc, item.id) do
        acc
      else
        reach(by_parent, item.id, MapSet.put(acc, item.id))
      end
    end)
  end

  # An unreachable item participates in a cycle iff walking its parent
  # chain (within the bag) returns to it.
  defp in_cycle?(item, items) do
    by_id = Map.new(items, &{&1.id, &1})
    walk_cycle(by_id, item.id, item.parent, MapSet.new())
  end

  defp walk_cycle(_by_id, _start, "", _seen), do: false

  defp walk_cycle(by_id, start, current, seen) do
    cond do
      current == start -> true
      MapSet.member?(seen, current) -> false
      true ->
        case Map.get(by_id, current) do
          nil -> false
          parent_item -> walk_cycle(by_id, start, parent_item.parent, MapSet.put(seen, current))
        end
    end
  end

  # `path` (ancestor ids) guards against descending back into a cycle;
  # `orphan_ids` keeps a re-rooted node from ALSO rendering as a child
  # of its (cyclic) parent.
  defp build_node(item, by_parent, orphan_ids, path) do
    path = MapSet.put(path, item.id)

    children =
      Map.get(by_parent, item.id, [])
      |> Enum.reject(&(MapSet.member?(path, &1.id) or MapSet.member?(orphan_ids, &1.id)))
      |> sort_siblings()

    %{item: item, children: Enum.map(children, &build_node(&1, by_parent, orphan_ids, path))}
  end

  defp sort_siblings(items) do
    Enum.sort(items, &(Order.compare({&1.order, &1.id}, {&2.order, &2.id}) != :gt))
  end
end
