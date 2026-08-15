defmodule Commonplace.Document.DocRef do
  @moduledoc """
  Stable identity format for referencing documents.

  Format: `path:uuid@cid`

  - `path` — the path in the schema tree (e.g. "notes/todo.txt")
  - `uuid` — the document's UUID
  - `cid` — optional commit ID (hex-encoded, for pinning to a specific version)

  Examples:
  - `notes/todo.txt:550e8400-e29b-41d4-a716-446655440000` — latest version
  - `notes/todo.txt:550e8400-e29b-41d4-a716-446655440000@a1b2c3d4e5f6` — pinned version
  - `:550e8400-e29b-41d4-a716-446655440000` — UUID-only (no path context)
  """

  @type t :: %__MODULE__{
          path: String.t() | nil,
          uuid: String.t(),
          cid: String.t() | nil
        }

  defstruct [:path, :uuid, :cid]

  @doc """
  Create a new DocRef.
  """
  def new(uuid, opts \\ []) do
    %__MODULE__{
      path: Keyword.get(opts, :path),
      uuid: uuid,
      cid: Keyword.get(opts, :cid)
    }
  end

  @doc """
  Parse a DocRef string into a struct.

  Handles these formats:
  - "path:uuid@cid"
  - "path:uuid"
  - ":uuid@cid"
  - ":uuid"
  - "uuid" (bare UUID, no path)
  """
  def parse(str) when is_binary(str) do
    case String.split(str, ":", parts: 2) do
      [path, rest] ->
        {uuid, cid} = parse_uuid_cid(rest)
        path = if path == "", do: nil, else: path
        {:ok, %__MODULE__{path: path, uuid: uuid, cid: cid}}

      [maybe_uuid] ->
        if uuid?(maybe_uuid) do
          {:ok, %__MODULE__{path: nil, uuid: maybe_uuid, cid: nil}}
        else
          {:error, :invalid_format}
        end
    end
  end

  @doc """
  Format a DocRef as a string.
  """
  def to_string(%__MODULE__{} = ref) do
    base = if ref.path, do: "#{ref.path}:#{ref.uuid}", else: ":#{ref.uuid}"
    if ref.cid, do: "#{base}@#{ref.cid}", else: base
  end

  @doc """
  Return the document UUID, ignoring path and version pin.
  """
  def uuid(%__MODULE__{uuid: uuid}) when is_binary(uuid) and uuid != "" do
    {:ok, uuid}
  end

  def uuid(%__MODULE__{path: path, uuid: nil}) when is_binary(path) do
    {:error, :uuid_required}
  end

  def uuid(%__MODULE__{}) do
    {:error, :invalid_ref}
  end

  defp parse_uuid_cid(str) do
    case String.split(str, "@", parts: 2) do
      [uuid, cid] -> {uuid, cid}
      [uuid] -> {uuid, nil}
    end
  end

  defp uuid?(str) do
    Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, str)
  end
end

defimpl String.Chars, for: Commonplace.Document.DocRef do
  def to_string(ref) do
    Commonplace.Document.DocRef.to_string(ref)
  end
end
