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
    defstruct [:name, :type, :node_id, sync: true]

    @type t :: %__MODULE__{
            name: String.t(),
            type: :doc | :dir,
            node_id: String.t(),
            sync: boolean()
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

  @honorific_extensions ~w(.bot .exe .usr .who)

  @doc """
  Return true iff `name` ends in one of the reserved honorific
  extensions: `.bot`, `.exe`, `.usr`, `.who` (CX-edy). The comparison
  is case-insensitive.

  Honorific extensions are reserved for presence documents — files
  that advertise an actor's live existence. The
  `Commonplace.Presence` module is the only trusted path for creating
  them; any user-facing write path must refuse to place new entries
  with these extensions, or an attacker could double-publish presence
  and break the single-presence-location invariant.
  """
  @spec honorific_extension?(String.t()) :: boolean()
  def honorific_extension?(name) when is_binary(name) do
    lower = String.downcase(name)
    Enum.any?(@honorific_extensions, &String.ends_with?(lower, &1))
  end

  @doc """
  Raise `ArgumentError` when `name` ends in a reserved honorific
  extension (CX-edy). Call this at untrusted write entrypoints (CLI
  ln, CLI import, future presence.move MCP tool) before adding
  user-provided names to the schema.
  """
  @spec forbid_honorific!(String.t()) :: :ok
  def forbid_honorific!(name) when is_binary(name) do
    if honorific_extension?(name) do
      raise ArgumentError,
            "reserved honorific extension in #{inspect(name)}: " <>
              ".bot / .exe / .usr / .who are reserved for presence documents " <>
              "(see Commonplace.Presence)"
    else
      :ok
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
          {type, node_id, sync} = decode_entry(v)
          {name, %{"type" => type, "node_id" => node_id, "sync" => sync}}

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
           node_id: entry_map["node_id"],
           sync: Map.get(entry_map, "sync", true)
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
        node_id: entry_map["node_id"],
        sync: Map.get(entry_map, "sync", true)
      }
    end)
  end

  @doc "Set the sync flag on an entry (activate/deactivate)."
  def set_sync(doc, name, sync) when is_binary(name) and is_boolean(sync) do
    doc = ensure_types(doc)
    all = entries(doc)

    case Map.get(all, name) do
      nil ->
        doc

      entry_map ->
        type = entry_map["type"]
        node_id = entry_map["node_id"]
        YMap.set(doc, @entries_type, name, encode_entry(type, node_id, sync))
    end
  end

  @doc "Activate a branch (set sync:true)."
  def activate(doc, name), do: set_sync(doc, name, true)

  @doc "Deactivate a branch (set sync:false)."
  def deactivate(doc, name), do: set_sync(doc, name, false)

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
    doc = YMap.set(doc, @entries_type, name, encode_entry(type, node_id, true))
    doc
  end

  defp encode_entry(type, node_id, true), do: "#{type}:#{node_id}"
  defp encode_entry(type, node_id, false), do: "#{type}:#{node_id}:nosync"

  defp decode_entry(encoded) when is_binary(encoded) do
    case String.split(encoded, ":") do
      [type, node_id, "nosync"] -> {type, node_id, false}
      [type, node_id] -> {type, node_id, true}
      _ -> {"doc", encoded, true}
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
