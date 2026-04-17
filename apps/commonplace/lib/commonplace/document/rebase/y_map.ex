defmodule Commonplace.Document.Rebase.YMap do
  @moduledoc """
  Positional-rebase primitive for YMap content (Phase 3 of CX-6a7).

  Given pre-edit and dirty maps (as plain Elixir maps produced by
  `YMap.to_map/2`), compute the symmetric keyset diff and apply
  set/delete ops against `new_doc`'s YMap under `type_name`.

  Semantics:
    * Keys in `dirty` but not `pre` → set on new_doc.
    * Keys in `pre` but not `dirty` → delete on new_doc.
    * Keys in both with unequal values → set on new_doc (dirty wins;
      the local edit's intent is an explicit overwrite).

  Values are treated as primitives. `YMap.to_map/2` already filters
  out nested Y-types (only items with `{:any, [value]}` content are
  surfaced), so the dispatcher does not need to recurse for the
  current ContentType envelope model. If nested Y-types appear in a
  future model, recursion belongs in the dispatcher (`Rebase.rebase`),
  not here.
  """

  alias Yelixer.Doc
  alias Yelixer.Types.YMap

  @type error :: term()

  @spec rebase(map(), map(), Doc.t(), String.t()) :: {:ok, Doc.t()} | {:error, error()}
  def rebase(pre, dirty, %Doc{} = new_doc, type_name)
      when is_map(pre) and is_map(dirty) and is_binary(type_name) do
    pre_keys = Map.keys(pre) |> MapSet.new()
    dirty_keys = Map.keys(dirty) |> MapSet.new()

    added = MapSet.difference(dirty_keys, pre_keys)
    removed = MapSet.difference(pre_keys, dirty_keys)
    common = MapSet.intersection(pre_keys, dirty_keys)

    modified =
      for key <- common,
          Map.fetch!(pre, key) != Map.fetch!(dirty, key),
          into: MapSet.new(),
          do: key

    doc =
      added
      |> MapSet.union(modified)
      |> Enum.reduce(new_doc, fn key, acc ->
        YMap.set(acc, type_name, key, Map.fetch!(dirty, key))
      end)

    doc =
      Enum.reduce(removed, doc, fn key, acc ->
        YMap.delete(acc, type_name, key)
      end)

    {:ok, doc}
  end
end
