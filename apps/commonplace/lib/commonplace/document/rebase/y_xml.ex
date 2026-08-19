defmodule Commonplace.Document.Rebase.YXml do
  @moduledoc """
  Tree-path rebase for YXmlFragment/YXmlElement content (Phase 2 of CX-6a7).

  Diffs two native-shape XML trees (`pre` and `dirty`) and replays the
  resulting ops against `new_doc`'s named YXmlFragment under `type_name`.

  ## Native shape

    * `{:element, tag, attrs_map, children}` — an XMLElement
    * `{:text, string}` — an XMLText leaf
    * `{:fragment, children}` — a nested XMLFragment (rare; appears inside
      elements only, never inside fragments, matching Yelixer's XMLFragment
      child-type support)

  Each level of the tree is diffed independently:

    * **Children**: myers diff on *type signatures* (`{:element, tag}` |
      `:text` | `:fragment`). Matched pairs recurse; inserts are expanded
      into the full subtree; deletes call `XMLFragment.delete_child/4` or
      `XMLElement.delete_child/4`.
    * **Attributes**: symmetric-keyset diff (same pattern as `YMap.rebase`)
      applied with `set_attribute` / `delete_attribute`.
    * **Text leaves**: delegate to `YText.rebase/4` on the XMLText child.

  Failure mode is all-or-nothing: any underlying error (e.g. YText
  `:out_of_range` on a text leaf, or a malformed tree) aborts the whole
  rebase and `Document.Server` preserves local dirty state.

  See `docs/positional-rebase.md` (commonplace-plan repo) for the RFC.
  """

  alias Yelixer.Doc
  alias Yelixer.Types.{XMLFragment, XMLElement, XMLText}
  alias Commonplace.Document.Rebase.YText

  @type tree ::
          {:element, String.t(), %{String.t() => term()}, [tree()]}
          | {:text, String.t()}
          | {:fragment, [tree()]}

  @type error :: {:yxml_rebase, term()}

  @spec rebase([tree()], [tree()], Doc.t(), String.t()) ::
          {:ok, Doc.t()} | {:error, error()}
  def rebase(pre, dirty, %Doc{} = new_doc, type_name)
      when is_list(pre) and is_list(dirty) and is_binary(type_name) do
    try do
      {:ok, rebase_children(pre, dirty, new_doc, type_name, :fragment)}
    catch
      {:rebase_err, reason} -> {:error, {:yxml_rebase, reason}}
    end
  end

  # --- Children (fragment or element children list) ---

  defp rebase_children(old_children, new_children, doc, parent_name, parent_kind) do
    old_sig = Enum.map(old_children, &signature/1)
    new_sig = Enum.map(new_children, &signature/1)
    diff = List.myers_difference(old_sig, new_sig)
    walk_diff(diff, old_children, new_children, doc, parent_name, parent_kind, 0)
  end

  defp signature({:element, tag, _, _}), do: {:element, tag}
  defp signature({:text, _}), do: :text
  defp signature({:fragment, _}), do: :fragment

  defp walk_diff([], _old, _new, doc, _parent, _kind, _pos), do: doc

  defp walk_diff([{:eq, sigs} | rest], old, new, doc, parent, kind, pos) do
    n = length(sigs)
    {old_eq, old_rest} = Enum.split(old, n)
    {new_eq, new_rest} = Enum.split(new, n)

    {doc, final_pos} =
      Enum.zip(old_eq, new_eq)
      |> Enum.reduce({doc, pos}, fn {o, nw}, {d, p} ->
        d = rebase_matched(o, nw, d, parent, kind, p)
        {d, p + 1}
      end)

    walk_diff(rest, old_rest, new_rest, doc, parent, kind, final_pos)
  end

  defp walk_diff([{:del, sigs} | rest], old, new, doc, parent, kind, pos) do
    n = length(sigs)
    {_del, old_rest} = Enum.split(old, n)
    doc = delete_children(doc, parent, kind, pos, n)
    walk_diff(rest, old_rest, new, doc, parent, kind, pos)
  end

  defp walk_diff([{:ins, sigs} | rest], old, new, doc, parent, kind, pos) do
    n = length(sigs)
    {ins, new_rest} = Enum.split(new, n)

    doc =
      ins
      |> Enum.with_index()
      |> Enum.reduce(doc, fn {subtree, i}, d ->
        insert_subtree(d, parent, kind, pos + i, subtree)
      end)

    walk_diff(rest, old, new_rest, doc, parent, kind, pos + n)
  end

  # --- Matched-pair recursion ---

  defp rebase_matched(
         {:element, tag, o_attrs, o_children},
         {:element, tag, n_attrs, n_children},
         doc,
         parent,
         parent_kind,
         pos
       ) do
    child_name = nth_child_name(doc, parent, parent_kind, pos)
    doc = rebase_attributes(doc, child_name, o_attrs, n_attrs)
    rebase_children(o_children, n_children, doc, child_name, :element)
  end

  defp rebase_matched({:text, o_str}, {:text, n_str}, doc, parent, parent_kind, pos) do
    child_name = nth_child_name(doc, parent, parent_kind, pos)

    case YText.rebase(o_str, n_str, doc, child_name) do
      {:ok, doc} -> doc
      {:error, reason} -> throw({:rebase_err, reason})
    end
  end

  defp rebase_matched(
         {:fragment, o_children},
         {:fragment, n_children},
         doc,
         parent,
         parent_kind,
         pos
       ) do
    child_name = nth_child_name(doc, parent, parent_kind, pos)
    rebase_children(o_children, n_children, doc, child_name, :fragment)
  end

  # --- Attribute diff (symmetric keyset) ---

  defp rebase_attributes(doc, element_name, old_attrs, new_attrs) do
    old_keys = Map.keys(old_attrs) |> MapSet.new()
    new_keys = Map.keys(new_attrs) |> MapSet.new()
    added = MapSet.difference(new_keys, old_keys)
    removed = MapSet.difference(old_keys, new_keys)
    common = MapSet.intersection(old_keys, new_keys)

    modified =
      for k <- common,
          Map.fetch!(old_attrs, k) != Map.fetch!(new_attrs, k),
          into: MapSet.new(),
          do: k

    doc =
      MapSet.union(added, modified)
      |> Enum.reduce(doc, fn k, d ->
        XMLElement.set_attribute(d, element_name, k, Map.fetch!(new_attrs, k))
      end)

    Enum.reduce(removed, doc, fn k, d -> XMLElement.delete_attribute(d, element_name, k) end)
  end

  # --- Child lookups & structural ops ---

  defp nth_child_name(doc, parent_name, :fragment, pos) do
    case XMLFragment.to_list(doc, parent_name) |> Enum.at(pos) do
      {:element, _tag, name} -> name
      {:text, name} -> name
      {:fragment, name} -> name
      nil -> throw({:rebase_err, {:child_missing, parent_name, pos}})
    end
  end

  defp nth_child_name(doc, parent_name, :element, pos) do
    case XMLElement.children(doc, parent_name) |> Enum.at(pos) do
      {:element, _tag, name} -> name
      {:text, name} -> name
      {:fragment, name} -> name
      nil -> throw({:rebase_err, {:child_missing, parent_name, pos}})
    end
  end

  defp delete_children(doc, parent, :fragment, pos, n) do
    XMLFragment.delete_child(doc, parent, pos, n)
  end

  defp delete_children(doc, parent, :element, pos, n) do
    XMLElement.delete_child(doc, parent, pos, n)
  end

  defp insert_subtree(doc, parent, parent_kind, pos, {:element, tag, attrs, children}) do
    doc = insert_child_primitive(doc, parent, parent_kind, pos, {:element, tag})
    child_name = nth_child_name(doc, parent, parent_kind, pos)

    doc =
      Enum.reduce(attrs, doc, fn {k, v}, d ->
        XMLElement.set_attribute(d, child_name, k, v)
      end)

    # Recursively insert grandchildren into the new element.
    children
    |> Enum.with_index()
    |> Enum.reduce(doc, fn {sub, i}, d ->
      insert_subtree(d, child_name, :element, i, sub)
    end)
  end

  defp insert_subtree(doc, parent, parent_kind, pos, {:text, string}) do
    doc = insert_child_primitive(doc, parent, parent_kind, pos, :text)

    if string == "" do
      doc
    else
      child_name = nth_child_name(doc, parent, parent_kind, pos)
      XMLText.insert(doc, child_name, 0, string)
    end
  end

  defp insert_subtree(doc, parent, :element, pos, {:fragment, children}) do
    doc = XMLElement.insert_child(doc, parent, pos, {:fragment})
    child_name = nth_child_name(doc, parent, :element, pos)

    children
    |> Enum.with_index()
    |> Enum.reduce(doc, fn {sub, i}, d ->
      insert_subtree(d, child_name, :fragment, i, sub)
    end)
  end

  defp insert_subtree(_doc, _parent, :fragment, _pos, {:fragment, _}) do
    # Yelixer XMLFragment doesn't support nested fragments as children.
    # This only becomes reachable if a caller constructs such a tree via the
    # root envelope — which would require a Yelixer API change first.
    throw({:rebase_err, :fragment_in_fragment_unsupported})
  end

  defp insert_child_primitive(doc, parent, :fragment, pos, spec) do
    XMLFragment.insert_child(doc, parent, pos, spec)
  end

  defp insert_child_primitive(doc, parent, :element, pos, spec) do
    XMLElement.insert_child(doc, parent, pos, spec)
  end
end
