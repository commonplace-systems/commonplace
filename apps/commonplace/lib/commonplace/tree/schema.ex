defmodule Commonplace.Tree.Schema do
  @moduledoc """
  Directory document schema — a YMap tree structure.

  Schema docs are Yelixer.Docs with a specific YMap layout:
    "schema" YMap {
      "version": 1,
      "root": { ... }  -- stored but not used as nested YMap yet
    }
    "entries" YMap {
      "name": { "type": "doc"|"dir", "node_id": "uuid" }
    }

  Entries map child names to their type and node UUID.
  Directories have type "dir", files have type "doc".
  """

  alias Yelixer.{Doc, Types.YMap}

  @schema_type "schema"
  @entries_type "entries"

  defmodule Entry do
    @moduledoc "A single entry in a schema document."
    defstruct [:name, :type, :node_id]

    @type t :: %__MODULE__{
            name: String.t(),
            type: :doc | :dir,
            node_id: String.t()
          }
  end

  @doc "Create a new empty schema document."
  def new_schema do
    doc = Doc.new()
    {doc, _} = Doc.get_or_create_type(doc, @schema_type, :map)
    {doc, _} = Doc.get_or_create_type(doc, @entries_type, :map)
    doc = YMap.set(doc, @schema_type, "version", "1")
    doc
  end

  @doc "Get the schema version."
  def version(doc) do
    doc = ensure_types(doc)

    case YMap.get(doc, @schema_type, "version") do
      nil -> nil
      v when is_binary(v) -> String.to_integer(v)
      v -> v
    end
  end

  @doc "Add a file entry to the schema."
  def add_file(doc, name, node_id) when is_binary(name) and is_binary(node_id) do
    add_entry(doc, name, "doc", node_id)
  end

  @doc "Add a directory entry to the schema."
  def add_directory(doc, name, node_id) when is_binary(name) and is_binary(node_id) do
    add_entry(doc, name, "dir", node_id)
  end

  @doc "Remove an entry by name."
  def remove_entry(doc, name) when is_binary(name) do
    doc = ensure_types(doc)
    YMap.delete(doc, @entries_type, name)
  end

  @doc "Get all entries as a raw map of {name => %{type, node_id}}."
  def entries(doc) do
    doc = ensure_types(doc)
    raw = YMap.to_map(doc, @entries_type)

    Map.new(raw, fn {name, value} ->
      case value do
        v when is_binary(v) ->
          {type, node_id} = decode_entry(v)
          {name, %{"type" => type, "node_id" => node_id}}

        _ ->
          {name, %{}}
      end
    end)
  end

  @doc "Get a single entry by name."
  def get_entry(doc, name) when is_binary(name) do
    all = entries(doc)

    case Map.get(all, name) do
      nil ->
        :error

      entry_map ->
        {:ok,
         %Entry{
           name: name,
           type: parse_type(entry_map["type"]),
           node_id: entry_map["node_id"]
         }}
    end
  end

  @doc "List all entries as Entry structs."
  def list_entries(doc) do
    entries(doc)
    |> Enum.map(fn {name, entry_map} ->
      %Entry{
        name: name,
        type: parse_type(entry_map["type"]),
        node_id: entry_map["node_id"]
      }
    end)
  end

  @doc "Resolve a name to its node_id."
  def resolve_name(doc, name) when is_binary(name) do
    case get_entry(doc, name) do
      {:ok, entry} -> {:ok, entry.node_id}
      :error -> :error
    end
  end

  # --- Private ---

  defp add_entry(doc, name, type, node_id) do
    doc = ensure_types(doc)
    # Store as a simple string encoding since we can't nest YMaps easily
    # Use a JSON-like encoding: "type:node_id"
    doc = YMap.set(doc, @entries_type, name, encode_entry(type, node_id))
    doc
  end

  defp encode_entry(type, node_id) do
    "#{type}:#{node_id}"
  end

  defp decode_entry(encoded) when is_binary(encoded) do
    case String.split(encoded, ":", parts: 2) do
      [type, node_id] -> {type, node_id}
      _ -> {"doc", encoded}
    end
  end

  defp ensure_types(doc) do
    doc =
      if Doc.has_type?(doc, @schema_type) do
        doc
      else
        {doc, _} = Doc.get_or_create_type(doc, @schema_type, :map)
        doc
      end

    if Doc.has_type?(doc, @entries_type) do
      doc
    else
      {doc, _} = Doc.get_or_create_type(doc, @entries_type, :map)
      doc
    end
  end

  defp parse_type("doc"), do: :doc
  defp parse_type("dir"), do: :dir
  defp parse_type(_), do: :unknown
end
