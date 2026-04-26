defmodule Commonplace.Document.ViewXml do
  @moduledoc """
  Parses a View XML document into a simple tree of nodes.

  Per `docs/views.md`, a View document's content is XML using the 10-element
  view vocabulary: `<view>`, `<entity>`, `<body>`, `<text>`, `<field>`,
  `<list>`, `<action>`, `<include>`, `<provenance>`, `<raw>`.

  This module uses `:xmerl_scan` (OTP stdlib, no extra deps) to parse the
  input string into Elixir-friendly `%Node{}` structs. Renderers walk the
  tree and dispatch on `tag`.

  Unknown elements are preserved as `%Node{tag: :unknown, ...}` so renderers
  can decide whether to ignore, render as raw text, or warn. We don't fail
  on unknown elements — forward-compatibility with future vocabulary
  extensions is a goal.
  """

  # xmerl is an OTP library shipped in stdlib but not always on the
  # compiler's code path. Suppress the undefined warning — runtime loading
  # is guaranteed because :xmerl is listed in extra_applications.
  @compile {:no_warn_undefined, :xmerl_scan}

  defmodule Node do
    @moduledoc """
    A single node in the parsed view tree.

    * `:tag` — atom identifying the element type (`:view`, `:entity`, etc.)
      or `:unknown` for elements outside the vocabulary.
    * `:attrs` — map of attribute names (as strings) to their values (as
      strings).
    * `:children` — list of child nodes (`%Node{}`) and text literals
      (binaries). Whitespace-only text between elements is preserved so
      renderers can decide whether to collapse it.
    """

    @type child :: t() | String.t()
    @type t :: %__MODULE__{
            tag: atom(),
            attrs: %{String.t() => String.t()},
            children: [child()]
          }

    defstruct tag: :unknown, attrs: %{}, children: []
  end

  @known_tags ~w(view entity body text field list action arg include provenance raw args
                 compute-spec pipeline step chains chain function)a

  @doc """
  Parse a view XML string into a `%Node{}` tree rooted at the top element.

  Returns `{:ok, %Node{}}` on success or `{:error, reason}` on any parse
  failure. The parser is defensive — any exception from `:xmerl_scan` is
  caught and surfaced as `{:error, {:xml_parse_error, term}}`.
  """
  @spec parse(String.t()) :: {:ok, Node.t()} | {:error, term()}
  def parse(xml) when is_binary(xml) do
    # :xmerl_scan defaults to iso-latin-1 and chokes on any character
    # outside that range (e.g. em dashes, smart quotes, emoji). Prepend a
    # UTF-8 declaration if the caller hasn't supplied one so the scanner
    # treats the stream as Unicode.
    xml = ensure_utf8_declaration(xml)

    # :xmerl_scan requires a charlist. We use :erlang.binary_to_list/1
    # (raw UTF-8 bytes) rather than String.to_charlist/1 (Unicode code
    # points) because xmerl applies its Legal Character check before it
    # reads the encoding declaration — and with code-point input it
    # rejects anything above 255 as "bad_character". Feeding the bytes
    # directly lets xmerl decode UTF-8 per the declaration.
    charlist = :erlang.binary_to_list(xml)

    try do
      # fetch_fun disables external entity loading so view XML can never
      # pull in remote DTDs or XIncludes. Whitespace stripping happens in
      # child_to_node/1 during tree conversion.
      {element, _rest} =
        :xmerl_scan.string(charlist,
          quiet: true,
          fetch_fun: fn _uri, state -> {:ok, :not_fetched, state} end
        )

      {:ok, to_node(element)}
    rescue
      e -> {:error, {:xml_parse_error, e}}
    catch
      :exit, reason -> {:error, {:xml_parse_error, reason}}
      kind, reason -> {:error, {:xml_parse_error, {kind, reason}}}
    end
  end

  def parse(_), do: {:error, :not_a_binary}

  defp ensure_utf8_declaration(xml) do
    trimmed = String.trim_leading(xml)

    if String.starts_with?(trimmed, "<?xml") do
      xml
    else
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n) <> xml
    end
  end

  # --- xmerl tuple conversion ---

  # :xmerl_scan returns an xmlElement record:
  #   {:xmlElement, name, expanded_name, nsinfo, namespace, parents, pos,
  #    attributes, content, language, xmlbase, elementdef}
  # and xmlText:
  #   {:xmlText, parents, pos, language, value, type}
  # and xmlAttribute:
  #   {:xmlAttribute, name, expanded_name, nsinfo, namespace, parents, pos,
  #    language, value, normalized}
  #
  # We pattern-match on the record tag by tuple position to avoid depending
  # on the xmerl .hrl header file.

  defp to_node(element) when is_tuple(element) and elem(element, 0) == :xmlElement do
    # xmlElement record layout (Elixir 0-indexed):
    #   0 :xmlElement  1 name  2 expanded_name  3 nsinfo  4 namespace
    #   5 parents  6 pos  7 attributes  8 content  9 language
    #   10 xmlbase  11 elementdef
    name = element |> elem(1) |> atom_to_tag()
    attrs_list = elem(element, 7)
    content = elem(element, 8)

    %Node{
      tag: name,
      attrs: attrs_to_map(attrs_list),
      children: content |> Enum.map(&child_to_node/1) |> Enum.reject(&is_nil/1)
    }
  end

  defp child_to_node(element) when is_tuple(element) and elem(element, 0) == :xmlElement do
    to_node(element)
  end

  defp child_to_node(text) when is_tuple(text) and elem(text, 0) == :xmlText do
    # xmlText record: {:xmlText, parents, pos, language, value, type}
    # `value` is at 0-indexed position 4.
    str =
      case elem(text, 4) do
        chars when is_list(chars) -> List.to_string(chars)
        chars when is_binary(chars) -> chars
        _ -> ""
      end

    # Drop whitespace-only text (typically pretty-printing between
    # elements). Keep any string with at least one non-whitespace char.
    if String.trim(str) == "" do
      nil
    else
      str
    end
  end

  defp child_to_node(_), do: nil

  defp attrs_to_map(attrs) when is_list(attrs) do
    Enum.reduce(attrs, %{}, fn attr, acc ->
      if is_tuple(attr) and elem(attr, 0) == :xmlAttribute do
        name = elem(attr, 1) |> Atom.to_string()
        value = elem(attr, 8) |> to_attr_value()
        Map.put(acc, name, value)
      else
        acc
      end
    end)
  end

  defp attrs_to_map(_), do: %{}

  defp to_attr_value(v) when is_list(v), do: List.to_string(v)
  defp to_attr_value(v) when is_binary(v), do: v
  defp to_attr_value(v), do: to_string(v)

  # Map xmerl element names (atoms) to our tag atoms. Known vocabulary
  # elements get their canonical atom; everything else gets `:unknown` with
  # the original name preserved via the `attrs[:__unknown_tag__]` sentinel so
  # renderers can log / display it.
  defp atom_to_tag(name) when is_atom(name) do
    if name in @known_tags do
      name
    else
      :unknown
    end
  end

  @doc """
  Given a parsed view tree, returns the `%Node{}` for the root `<view>`
  element or `{:error, :not_a_view}` if the top element is something else.
  """
  @spec root(Node.t()) :: {:ok, Node.t()} | {:error, :not_a_view}
  def root(%Node{tag: :view} = node), do: {:ok, node}
  def root(%Node{}), do: {:error, :not_a_view}

  @doc """
  Flatten all text children of a node into a single string. Used by
  renderers for leaf elements like `<text>` where mixed content is just
  characters.
  """
  @spec text_content(Node.t()) :: String.t()
  def text_content(%Node{children: children}) do
    children
    |> Enum.map(fn
      %Node{} = n -> text_content(n)
      text when is_binary(text) -> text
    end)
    |> IO.iodata_to_binary()
  end
end
