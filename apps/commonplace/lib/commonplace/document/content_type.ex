defmodule Commonplace.Document.ContentType do
  @moduledoc """
  Document envelope system for commonplace.

  Every document is a single `Yelixer.Doc` holding TWO top-level Yjs
  types side by side:

  - the **envelope** — a YMap registered under the name `"root"` — whose
    keys are `"_type"` (`"text" | "map" | "array" | "xml"`), `"_name"`
    (a human-readable name), and any arbitrary metadata;
  - the **content** — a separate top-level type registered under the
    name `"content"` — holding the actual payload. Its Yjs type is
    chosen from `"_type"`: `Text` for text, `YMap` for map, `Array` for
    array, `XMLFragment` for xml.

  The key subtlety: `"content"` is NOT a key inside the envelope YMap —
  it is a *sibling* named type in the same Doc. So `_type` / `_name` /
  metadata are read from the `"root"` map (`get_type/1`), while the
  payload is read from the `"content"` type (`get_content/1`).
  """

  alias Yelixer.Doc
  alias Yelixer.Types.{YMap, Text, Array, XMLFragment, XMLElement, XMLText}

  @root_type "root"
  @content_type "content"

  @valid_types ~w(text map array xml)a
  @type_to_string %{text: "text", map: "map", array: "array", xml: "xml"}
  @string_to_type %{"text" => :text, "map" => :map, "array" => :array, "xml" => :xml}

  @doc """
  Create a new document with the envelope structure.

  Sets up the root YMap with "_type" and "_name", and registers
  the "content" type appropriate for the document type.
  """
  def create(%Doc{} = doc, type, name) when type in @valid_types and is_binary(name) do
    # Register the root type as a map
    {doc, _} = Doc.get_or_create_type(doc, @root_type, :map)

    # Set _type and _name in the root envelope
    doc = YMap.set(doc, @root_type, "_type", Map.fetch!(@type_to_string, type))
    doc = YMap.set(doc, @root_type, "_name", name)

    # Register and initialize the content type
    type_ref = content_type_ref(type)
    {doc, _} = Doc.get_or_create_type(doc, @content_type, type_ref)

    doc
  end

  @doc """
  Read the content type from an existing document.
  Returns an atom: :text, :map, :array, or :xml.
  """
  def get_type(%Doc{} = doc) do
    # Ensure the root type is registered for reading
    doc = ensure_root_type(doc)

    case YMap.get(doc, @root_type, "_type") do
      nil -> nil
      type_string -> Map.get(@string_to_type, type_string)
    end
  end

  @doc """
  Get the content value from the document.

  Returns the appropriate representation:
  - :text -> String
  - :map -> Map
  - :array -> List
  - :xml -> list of child trees (root fragment's children)
  - nil -> nil
  """
  def get_content(%Doc{} = doc) do
    type = get_type(doc)
    doc = ensure_content_type(doc, type)

    case type do
      :text -> Text.to_string(doc, @content_type)
      :map -> YMap.to_map(doc, @content_type)
      :array -> Array.to_list(doc, @content_type)
      :xml -> materialize_xml_fragment(doc, @content_type)
      nil -> nil
    end
  end

  defp materialize_xml_fragment(%Doc{} = doc, type_name) do
    XMLFragment.to_list(doc, type_name)
    |> Enum.map(&materialize_xml_child(doc, &1))
  end

  defp materialize_xml_element(%Doc{} = doc, type_name) do
    tag = XMLElement.tag_name(doc, type_name)
    attrs = XMLElement.get_attributes(doc, type_name)

    children =
      XMLElement.children(doc, type_name)
      |> Enum.map(&materialize_xml_child(doc, &1))

    {:element, tag, attrs, children}
  end

  defp materialize_xml_child(%Doc{} = doc, {:element, _tag, child_name}) do
    materialize_xml_element(doc, child_name)
  end

  defp materialize_xml_child(%Doc{} = doc, {:text, child_name}) do
    {:text, XMLText.to_string(doc, child_name)}
  end

  defp materialize_xml_child(%Doc{} = doc, {:fragment, child_name}) do
    {:fragment, materialize_xml_fragment(doc, child_name)}
  end

  @doc "Get a metadata value from the root envelope."
  def get_meta(%Doc{} = doc, key) when is_binary(key) do
    doc = ensure_root_type(doc)
    YMap.get(doc, @root_type, key)
  end

  @doc "Set a metadata value in the root envelope."
  def set_meta(%Doc{} = doc, key, value) when is_binary(key) do
    doc = ensure_root_type(doc)
    YMap.set(doc, @root_type, key, value)
  end

  # --- Content editing helpers ---

  @doc "Insert text at an index (for text documents)."
  def insert_text(%Doc{} = doc, index, text) do
    doc = ensure_content_type(doc, :text)
    Text.insert(doc, @content_type, index, text)
  end

  @doc "Delete text at an index (for text documents)."
  def delete_text(%Doc{} = doc, index, length) do
    doc = ensure_content_type(doc, :text)
    Text.delete(doc, @content_type, index, length)
  end

  @doc "Set a key in the content map (for map documents)."
  def set_key(%Doc{} = doc, key, value) do
    doc = ensure_content_type(doc, :map)
    YMap.set(doc, @content_type, key, value)
  end

  @doc "Delete a key from the content map (for map documents)."
  def delete_key(%Doc{} = doc, key) do
    doc = ensure_content_type(doc, :map)
    YMap.delete(doc, @content_type, key)
  end

  @doc "Push items to the end of the content array (for array documents)."
  def push_items(%Doc{} = doc, values) when is_list(values) do
    doc = ensure_content_type(doc, :array)
    Array.push(doc, @content_type, values)
  end

  @doc "Insert items at an index in the content array (for array documents)."
  def insert_items(%Doc{} = doc, index, values) when is_list(values) do
    doc = ensure_content_type(doc, :array)
    Array.insert(doc, @content_type, index, values)
  end

  @doc "Delete items from the content array (for array documents)."
  def delete_items(%Doc{} = doc, index, length) do
    doc = ensure_content_type(doc, :array)
    Array.delete(doc, @content_type, index, length)
  end

  # --- Private helpers ---

  defp ensure_root_type(%Doc{} = doc) do
    if Doc.has_type?(doc, @root_type) do
      doc
    else
      {doc, _} = Doc.get_or_create_type(doc, @root_type, :map)
      doc
    end
  end

  defp ensure_content_type(%Doc{} = doc, type) do
    if Doc.has_type?(doc, @content_type) do
      doc
    else
      type_ref = content_type_ref(type)
      {doc, _} = Doc.get_or_create_type(doc, @content_type, type_ref)
      doc
    end
  end

  defp content_type_ref(:text), do: :text
  defp content_type_ref(:map), do: :map
  defp content_type_ref(:array), do: :array
  defp content_type_ref(:xml), do: :xml_fragment
  defp content_type_ref(_), do: :map
end
