defmodule Commonplace.Document.ViewDetect do
  @moduledoc """
  Cheap detection of whether a document's content is a View.

  Per `docs/views.md`, a document is a View iff its content's root XML element
  is `<view>`. Detection is content-based only — there is no schema flag.

  The check is conservative: it skips leading whitespace and an optional XML
  declaration (`<?xml ... ?>`), then looks for a literal `<view` prefix
  (with or without attributes). Anything else is treated as non-view content
  (markdown, raw text, etc.) and handled by the existing rendering path.
  """

  @doc """
  Returns `true` if the given content is a view document, `false` otherwise.

  Accepts any binary. `nil` and non-binaries return `false`.
  """
  @spec is_view?(any()) :: boolean()
  def is_view?(content) when is_binary(content) do
    content
    |> skip_xml_prologue()
    |> String.starts_with?("<view")
    |> case do
      true -> true
      false -> false
    end
    |> then(fn
      true ->
        # Ensure the "<view" prefix is actually the start of a tag — followed
        # by whitespace, `>`, or `/` — rather than something like `<viewer>`.
        trimmed = skip_xml_prologue(content)
        after_prefix = binary_part(trimmed, 5, byte_size(trimmed) - 5)
        String.match?(after_prefix, ~r/^[\s>\/]/)

      false ->
        false
    end)
  end

  def is_view?(_), do: false

  # Skip leading whitespace and an optional `<?xml ... ?>` declaration.
  defp skip_xml_prologue(content) do
    trimmed = String.trim_leading(content)

    case trimmed do
      "<?xml" <> rest ->
        case String.split(rest, "?>", parts: 2) do
          [_, after_decl] -> String.trim_leading(after_decl)
          _ -> trimmed
        end

      _ ->
        trimmed
    end
  end
end
