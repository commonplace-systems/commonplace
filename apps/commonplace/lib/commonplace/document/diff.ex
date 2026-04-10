defmodule Commonplace.Document.Diff do
  @moduledoc """
  Grapheme-level diffing for text documents.

  Computes minimal edit operations to transform one string into another,
  suitable for applying to Yjs text documents via insert/delete operations.
  Uses Elixir's built-in Myers diff algorithm on grapheme clusters.

  All indices and lengths emitted by `diff/2` are measured in graphemes,
  matching Yelixer's text indexing semantics. Combining marks, ZWJ
  sequences, and regional-indicator flag emoji are each treated as a
  single unit for cursor-advance purposes.
  """

  alias Commonplace.Document.ContentType

  @type edit :: {:insert, non_neg_integer(), String.t()} | {:delete, non_neg_integer(), non_neg_integer()}

  @doc """
  Compute edit operations to transform `old` into `new`.

  Returns a list of `{:insert, index, text}` and `{:delete, index, length}`
  operations, ordered for front-to-back sequential application. Indices
  account for the effect of preceding operations on the document.
  """
  @spec diff(String.t(), String.t()) :: [edit()]
  def diff(old, new) when is_binary(old) and is_binary(new) do
    if old == new do
      []
    else
      old_graphemes = String.graphemes(old)
      new_graphemes = String.graphemes(new)

      old_graphemes
      |> List.myers_difference(new_graphemes)
      |> patches_to_edits()
    end
  end

  @doc """
  Apply diff operations to a Yjs doc's text content.

  Computes the diff from `old_content` to `new_content` and applies
  the resulting insert/delete operations to the document.

  Returns the updated doc.
  """
  @spec apply_diff(Yelixer.Doc.t(), String.t(), String.t()) :: Yelixer.Doc.t()
  def apply_diff(%Yelixer.Doc{} = doc, old_content, new_content) do
    edits = diff(old_content, new_content)

    Enum.reduce(edits, doc, fn
      {:delete, idx, len}, acc ->
        ContentType.delete_text(acc, idx, len)

      {:insert, idx, text}, acc ->
        ContentType.insert_text(acc, idx, text)
    end)
  end

  # Convert Myers diff patches to positioned edit operations.
  #
  # Tracks a cursor position in the document-as-modified:
  # - :eq  -> advance cursor by length (no edit)
  # - :del -> delete at cursor, don't advance (chars removed)
  # - :ins -> insert at cursor, advance by inserted length
  defp patches_to_edits(patches) do
    {edits, _cursor} =
      Enum.reduce(patches, {[], 0}, fn
        {:eq, chars}, {acc, cursor} ->
          {acc, cursor + length(chars)}

        {:del, chars}, {acc, cursor} ->
          {acc ++ [{:delete, cursor, length(chars)}], cursor}

        {:ins, chars}, {acc, cursor} ->
          text = Enum.join(chars)
          {acc ++ [{:insert, cursor, text}], cursor + length(chars)}
      end)

    edits
  end
end
