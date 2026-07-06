defmodule Commonplace.GitBridge.CanonicalXml do
  @moduledoc """
  Deterministic, byte-stable XML rendering for GitBridge's `:xml`
  content type export (outliner `_outline` bullet trees, chat
  `_view.xml` action surfaces, and any other `XMLFragment`-backed doc).

  Input is the materialized tuple tree `Commonplace.Document.ContentType`
  already produces for `:xml` docs (`get_content/1`): a list of
  `{:element, tag, attrs, children}` / `{:text, str}` / `{:fragment,
  children}` nodes, `attrs` an Elixir map.

  This is the sibling of `Commonplace.GitBridge.CanonicalJson`: same
  determinism contract (sorted keys — here, sorted attributes — fixed
  indent, single trailing newline), applied to XML instead of JSON, so
  the same phantom-diff-freedom holds for XML-typed exports.

  ## Format decisions (frozen — G2's inbound ingest parses to this
  exact shape, so these are not just style, they're the wire contract)

    * **Attributes**: sorted by key (byte-wise `String` ordering), each
      rendered as `key="value"` separated by single spaces, in
      declaration order after sorting. Same rule as `CanonicalJson`'s
      sorted map keys — makes output byte-identical for two attribute
      maps that are equal regardless of construction/insertion order.
    * **Indentation**: fixed 2 spaces per level, only applied to
      **element-only** children (every child is `{:element, _, _, _}`
      or `{:fragment, _}` — none is `{:text, _}`). One child per line.
    * **Mixed content**: if a node's children include so much as one
      `{:text, _}` node, the *entire subtree* under that node renders
      inline — no newlines, no indentation inserted anywhere below
      it — because indentation is itself whitespace *text*, and
      injecting it into a mixed-content element would silently change
      the element's text semantics. This "poisons" descendants: an
      element-only grandchild nested inside a mixed-content child does
      NOT regain block formatting just because it has no text of its
      own; once inline, always inline for that whole branch. A single
      text-only child list (no elements) also renders inline — it's
      not "element-only" either.
    * **Self-closing**: an element with an empty children list
      (`[]`) ALWAYS self-closes (`<tag attrs/>`), in both block and
      inline contexts. An element with any children (even a single
      empty fragment) always uses an explicit open/close pair. This
      rule never varies — required for byte-stability (an empty
      element must not sometimes render as `<a></a>` and sometimes as
      `<a/>` depending on context).
    * **Fragments**: `{:fragment, children}` is transparent — it
      contributes no wrapping tag of its own. In block mode its
      children render at the *same* indent level as the fragment's own
      position (no extra nesting level for the fragment itself).
    * **Escaping**: text nodes escape `&` `<` `>` (as `&amp;` `&lt;`
      `&gt;`, `&` first to avoid double-escaping). Attribute values
      additionally escape `"` as `&quot;`. Unicode content passes
      through unescaped (UTF-8 binaries are valid output as-is).
    * **No XML declaration**: output has no `<?xml ... ?>` prolog —
      matches the existing hand-authored `_view.xml` templates
      (`Commonplace.Outline.view_xml_template/1`), which have none
      either. Root: the input tree is a *list* of sibling nodes (the
      fragment's children), not necessarily a single-rooted document,
      so multiple top-level nodes render one after another, newline
      separated — same rule as block-mode element-only children, just
      with no wrapping tag and no added indent (indent 0).
    * Output always ends with exactly one trailing newline (empty tree
      encodes to just `"\\n"`).

  Anything that doesn't match the expected tuple shapes (unknown node
  tag, non-binary XML tag name, etc.) returns `{:error, reason}` —
  callers (the GitBridge exporter) fall back to the previous
  canonical-JSON-of-tree rendering rather than writing garbage.
  """

  @doc """
  Render a materialized XML child list (as returned by
  `Commonplace.Document.ContentType.get_content/1` for an `:xml` doc)
  to a deterministic, pretty-printed XML string.

  Returns `{:ok, string}` or `{:error, reason}`.
  """
  @spec encode([term()]) :: {:ok, String.t()} | {:error, term()}
  def encode(tree) when is_list(tree) do
    rendered =
      tree
      |> Enum.map(&render_block(&1, 0))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    {:ok, IO.iodata_to_binary([rendered, "\n"])}
  rescue
    error -> {:error, error}
  end

  def encode(other), do: {:error, {:not_a_list, other}}

  # --- Block-mode rendering (indentation-eligible contexts) ---

  defp render_block({:element, tag, attrs, []}, indent) when is_binary(tag) do
    pad(indent) <> self_close(tag, attrs)
  end

  defp render_block({:element, tag, attrs, children}, indent) when is_binary(tag) do
    if mixed?(children) do
      pad(indent) <> open(tag, attrs) <> inline_children(children) <> close(tag)
    else
      inner =
        children
        |> Enum.map(&render_block(&1, indent + 1))
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      pad(indent) <> open(tag, attrs) <> "\n" <> inner <> "\n" <> pad(indent) <> close(tag)
    end
  end

  defp render_block({:fragment, []}, _indent), do: ""

  defp render_block({:fragment, children}, indent) do
    if mixed?(children) do
      pad(indent) <> inline_children(children)
    else
      children
      |> Enum.map(&render_block(&1, indent))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    end
  end

  # A bare {:text, _} at block level (no wrapping element) has nowhere
  # sensible to be indented, so it renders inline at its own position.
  defp render_block({:text, str}, indent) when is_binary(str) do
    pad(indent) <> escape_text(str)
  end

  defp render_block(other, _indent), do: raise(ArgumentError, "unserializable XML node: #{inspect(other)}")

  # --- Inline-mode rendering (once mixed content is entered, no node
  # below ever adds a newline or indent again) ---

  defp inline_children(children), do: children |> Enum.map(&render_inline/1) |> Enum.join("")

  defp render_inline({:text, str}) when is_binary(str), do: escape_text(str)

  defp render_inline({:element, tag, attrs, []}) when is_binary(tag) do
    self_close(tag, attrs)
  end

  defp render_inline({:element, tag, attrs, children}) when is_binary(tag) do
    open(tag, attrs) <> inline_children(children) <> close(tag)
  end

  defp render_inline({:fragment, children}), do: inline_children(children)

  defp render_inline(other), do: raise(ArgumentError, "unserializable XML node: #{inspect(other)}")

  # --- Shared tag/attr rendering ---

  defp mixed?(children), do: Enum.any?(children, &match?({:text, _}, &1))

  defp open(tag, attrs), do: "<" <> tag <> render_attrs(attrs) <> ">"
  defp close(tag), do: "</" <> tag <> ">"
  defp self_close(tag, attrs), do: "<" <> tag <> render_attrs(attrs) <> "/>"

  defp render_attrs(attrs) when is_map(attrs) do
    attrs
    |> Map.to_list()
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> " " <> to_string(k) <> "=\"" <> escape_attr(v) <> "\"" end)
    |> Enum.join("")
  end

  defp render_attrs(other), do: raise(ArgumentError, "unserializable XML attrs: #{inspect(other)}")

  defp escape_text(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape_attr(value) do
    value
    |> to_string()
    |> escape_text()
    |> String.replace("\"", "&quot;")
  end

  defp pad(indent), do: String.duplicate("  ", indent)
end
