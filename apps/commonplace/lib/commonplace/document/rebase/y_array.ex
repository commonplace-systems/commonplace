defmodule Commonplace.Document.Rebase.YArray do
  @moduledoc """
  Positional rebase for YArray content (Phase 4 of CX-6a7).

  Diffs two lists (`pre` = pre-dirty committed list, `dirty` =
  post-dirty local list) using `List.myers_difference/2`, then replays
  the resulting insert/delete ops against `new_doc`'s named YArray
  under `type_name`. Positions are in `new_doc`'s coordinate system
  and shift naturally as ops are applied.

  Identity: items are compared with `==` (deep equality). This is the
  "deep-equal fallback" identity path from the RFC — sufficient for
  the current ContentType envelope model where YArray values are
  primitives from `Array.to_list/2`. If nested Y-type items become
  addressable at this layer, a user-supplied identity function will
  be needed (per the RFC §Open Questions schema-annotation pattern)
  to avoid delete+reinsert churn on reorder; this is the churn
  tradeoff called out in the RFC §Explicit Tradeoffs.

  Failure mode: if an insert position exceeds `new_doc`'s length (the
  remote made a drastic shortening concurrent with our dirty edits),
  or a delete range overshoots, we return `{:error, {:out_of_range,
  …}}` — all-or-nothing, matching `YText.rebase/4` semantics.

  See `docs/positional-rebase.md` in the commonplace-plan repo for
  the full RFC and vocabulary.
  """

  alias Yelixer.Doc
  alias Yelixer.Types.Array

  @type error ::
          {:out_of_range, :insert, pos :: non_neg_integer(), new_length :: non_neg_integer()}
          | {:out_of_range, :delete, pos :: non_neg_integer(), len :: non_neg_integer(),
             new_length :: non_neg_integer()}

  @spec rebase(list(), list(), Doc.t(), String.t()) :: {:ok, Doc.t()} | {:error, error()}
  def rebase(pre, dirty, %Doc{} = new_doc, type_name)
      when is_list(pre) and is_list(dirty) and is_binary(type_name) do
    diff = List.myers_difference(pre, dirty)
    apply_diff(diff, new_doc, type_name, 0)
  end

  defp apply_diff([], doc, _type_name, _pos), do: {:ok, doc}

  defp apply_diff([{:eq, items} | rest], doc, type_name, pos) do
    apply_diff(rest, doc, type_name, pos + length(items))
  end

  defp apply_diff([{:ins, items} | rest], doc, type_name, pos) do
    len = Array.length(doc, type_name)

    if pos > len do
      {:error, {:out_of_range, :insert, pos, len}}
    else
      doc = Array.insert(doc, type_name, pos, items)
      apply_diff(rest, doc, type_name, pos + length(items))
    end
  end

  defp apply_diff([{:del, items} | rest], doc, type_name, pos) do
    n = length(items)
    len = Array.length(doc, type_name)

    if pos + n > len do
      {:error, {:out_of_range, :delete, pos, n, len}}
    else
      doc = Array.delete(doc, type_name, pos, n)
      apply_diff(rest, doc, type_name, pos)
    end
  end
end
