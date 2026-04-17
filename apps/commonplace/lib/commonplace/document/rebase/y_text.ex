defmodule Commonplace.Document.Rebase.YText do
  @moduledoc """
  Positional rebase for YText content (Phase 1 of CX-6a7).

  Diffs two grapheme strings (`pre` = pre-dirty committed text,
  `dirty` = post-dirty local text) using `Commonplace.Document.Diff`,
  then replays the resulting insert/delete ops against a fresh
  `new_doc`'s named YText type.

  See `docs/positional-rebase.md` (in the commonplace-plan repo) for
  the named-mechanism vocabulary: "positional rebase", "native shape",
  "coordinate system".
  """

  alias Commonplace.Document.Diff
  alias Yelixer.Doc
  alias Yelixer.Types.Text

  @type error ::
          {:out_of_range, :insert, pos :: non_neg_integer(), new_length :: non_neg_integer()}
          | {:out_of_range, :delete, pos :: non_neg_integer(), len :: non_neg_integer(),
             new_length :: non_neg_integer()}

  @spec rebase(String.t(), String.t(), Doc.t(), String.t()) :: {:ok, Doc.t()} | {:error, error()}
  def rebase(pre, dirty, %Doc{} = new_doc, type_name)
      when is_binary(pre) and is_binary(dirty) and is_binary(type_name) do
    ops = Diff.diff(pre, dirty)
    apply_ops(ops, new_doc, type_name)
  end

  defp apply_ops(ops, doc, type_name) do
    Enum.reduce_while(ops, {:ok, doc}, fn op, {:ok, d} ->
      case apply_op(op, d, type_name) do
        {:ok, d2} -> {:cont, {:ok, d2}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp apply_op({:insert, pos, text}, doc, type_name) do
    len = Text.length(doc, type_name)

    if pos > len do
      {:error, {:out_of_range, :insert, pos, len}}
    else
      {:ok, Text.insert(doc, type_name, pos, text)}
    end
  end

  defp apply_op({:delete, pos, n}, doc, type_name) do
    len = Text.length(doc, type_name)

    if pos + n > len do
      {:error, {:out_of_range, :delete, pos, n, len}}
    else
      {:ok, Text.delete(doc, type_name, pos, n)}
    end
  end
end
