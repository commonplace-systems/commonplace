defmodule Commonplace.Document.Diff do
  @moduledoc """
  Grapheme-level diffing for text documents.

  Computes edit operations to transform one string into another, suitable for
  applying to Yjs text documents via insert/delete operations. Common grapheme
  prefixes and suffixes are removed before Elixir's built-in Myers diff runs.
  Large changed middles use a single replacement so diff cost stays bounded;
  small changes retain Myers' fine-grained edits.

  All indices and lengths emitted by `diff/2` are measured in graphemes,
  matching Yelixer's text indexing semantics. Combining marks, ZWJ
  sequences, and regional-indicator flag emoji are each treated as a
  single unit for cursor-advance purposes.
  """

  alias Commonplace.Document.ContentType

  @max_myers_graphemes 4_096

  @type edit ::
          {:insert, non_neg_integer(), String.t()}
          | {:delete, non_neg_integer(), non_neg_integer()}

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
      {prefix_length, old_rest, new_rest} = trim_common_prefix(old, new)
      suffix_size = common_grapheme_suffix_size(old_rest, new_rest)

      old_middle = binary_part(old_rest, 0, byte_size(old_rest) - suffix_size)
      new_middle = binary_part(new_rest, 0, byte_size(new_rest) - suffix_size)

      old_graphemes = String.graphemes(old_middle)
      new_graphemes = String.graphemes(new_middle)

      if length(old_graphemes) + length(new_graphemes) <= @max_myers_graphemes do
        old_graphemes
        |> List.myers_difference(new_graphemes)
        |> patches_to_edits(prefix_length)
      else
        replacement_edits(old_graphemes, new_middle, prefix_length)
      end
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

  defp trim_common_prefix(old, new), do: trim_common_prefix(old, new, 0)

  defp trim_common_prefix(old, new, length) do
    case {String.next_grapheme(old), String.next_grapheme(new)} do
      {{grapheme, old_rest}, {grapheme, new_rest}} ->
        trim_common_prefix(old_rest, new_rest, length + 1)

      _different_or_exhausted ->
        {length, old, new}
    end
  end

  # Find the common byte suffix first, then intersect the grapheme boundaries
  # of both strings. The boundary merge is constant-space and prevents a trim
  # from separating a combining sequence, ZWJ emoji, regional indicators, or
  # CRLF even when their segmentation differs because of preceding content.
  defp common_grapheme_suffix_size(old, new) do
    raw_size = common_byte_suffix_size(old, new)

    common_boundary_suffix_size(
      {old, 0, byte_size(old)},
      {new, 0, byte_size(new)},
      raw_size
    )
  end

  defp common_byte_suffix_size(old, new) do
    limit = min(byte_size(old), byte_size(new))
    common_byte_suffix_size(old, new, byte_size(old), byte_size(new), limit, 0)
  end

  defp common_byte_suffix_size(_old, _new, _old_size, _new_size, limit, limit), do: limit

  defp common_byte_suffix_size(old, new, old_size, new_size, limit, matched) do
    if :binary.at(old, old_size - matched - 1) == :binary.at(new, new_size - matched - 1) do
      common_byte_suffix_size(old, new, old_size, new_size, limit, matched + 1)
    else
      matched
    end
  end

  defp common_boundary_suffix_size(old_state, new_state, raw_size) do
    old_suffix_size = boundary_suffix_size(old_state)
    new_suffix_size = boundary_suffix_size(new_state)

    cond do
      old_suffix_size == new_suffix_size and old_suffix_size <= raw_size ->
        old_suffix_size

      old_suffix_size == new_suffix_size ->
        common_boundary_suffix_size(
          advance_grapheme_boundary(old_state),
          advance_grapheme_boundary(new_state),
          raw_size
        )

      old_suffix_size > new_suffix_size ->
        common_boundary_suffix_size(advance_grapheme_boundary(old_state), new_state, raw_size)

      true ->
        common_boundary_suffix_size(old_state, advance_grapheme_boundary(new_state), raw_size)
    end
  end

  defp boundary_suffix_size({_rest, offset, total}), do: total - offset

  defp advance_grapheme_boundary({rest, offset, total}) do
    {grapheme, next_rest} = String.next_grapheme(rest)
    {next_rest, offset + byte_size(grapheme), total}
  end

  defp replacement_edits(old_graphemes, new_middle, cursor) do
    edits =
      case old_graphemes do
        [] -> []
        graphemes -> [{:delete, cursor, length(graphemes)}]
      end

    if new_middle == "" do
      edits
    else
      edits ++ [{:insert, cursor, new_middle}]
    end
  end

  # Convert Myers diff patches to positioned edit operations.
  #
  # Tracks a cursor position in the document-as-modified:
  # - :eq  -> advance cursor by length (no edit)
  # - :del -> delete at cursor, don't advance (chars removed)
  # - :ins -> insert at cursor, advance by inserted length
  defp patches_to_edits(patches, initial_cursor) do
    {edits, _cursor} =
      Enum.reduce(patches, {[], initial_cursor}, fn
        {:eq, chars}, {acc, cursor} ->
          {acc, cursor + length(chars)}

        {:del, chars}, {acc, cursor} ->
          {[{:delete, cursor, length(chars)} | acc], cursor}

        {:ins, chars}, {acc, cursor} ->
          text = Enum.join(chars)
          {[{:insert, cursor, text} | acc], cursor + length(chars)}
      end)

    Enum.reverse(edits)
  end
end
