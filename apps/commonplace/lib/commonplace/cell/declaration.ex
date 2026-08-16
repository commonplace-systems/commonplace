defmodule Commonplace.Cell.Declaration do
  @moduledoc """
  The three-field declaration of a spawned cell's public identity.

  A declaration records the cell's UUID, name, and encoded public key. It never
  infers an identity, provisions a cell, starts a process, probes readiness, or
  grants authority. It declares who a cell is and does nothing else.
  """

  alias Commonplace.Crypto.Signing

  @fields [:child_uuid, :name, :public_key]
  @field_names Enum.map(@fields, &Atom.to_string/1)

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          child_uuid: String.t(),
          name: String.t(),
          public_key: String.t()
        }

  @type invalid_declaration :: {:invalid_declaration, String.t(), String.t()}

  @doc "Validate all three declaration fields and refuse unknown fields."
  @spec validate(t() | map()) :: :ok | {:error, invalid_declaration()}
  def validate(declaration) when is_map(declaration) do
    with :ok <- reject_unknown_fields(declaration),
         :ok <- required_binary(declaration, :child_uuid, "child_uuid"),
         :ok <- required_binary(declaration, :name, "name"),
         :ok <- required_public_key(declaration) do
      :ok
    end
  end

  def validate(_declaration), do: invalid("declaration", "must be an object")

  @doc "Encode a valid declaration as JSON."
  @spec encode(t() | map()) :: {:ok, String.t()} | {:error, term()}
  def encode(declaration) do
    with :ok <- validate(declaration) do
      declaration
      |> normalized_declaration()
      |> Jason.encode()
    end
  end

  @doc "Decode JSON and validate it before returning a declaration struct."
  @spec decode(String.t()) :: {:ok, t()} | {:error, term()}
  def decode(document) when is_binary(document) do
    with {:ok, decoded} <- decode_json(document),
         :ok <- validate(decoded) do
      {:ok, to_declaration(decoded)}
    end
  end

  defp decode_json(document) do
    case Jason.decode(document) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> invalid("declaration", "must be valid JSON")
    end
  end

  defp reject_unknown_fields(declaration) do
    declaration
    |> Map.keys()
    |> Enum.reject(&(&1 == :__struct__))
    |> Enum.map(&field_name/1)
    |> Enum.reject(&(&1 in @field_names))
    |> Enum.sort()
    |> case do
      [] -> :ok
      [field | _rest] -> invalid(field, "is not a recognized field")
    end
  end

  defp required_public_key(declaration) do
    case fetch(declaration, :public_key) do
      {:ok, value} when is_binary(value) ->
        case Signing.decode_key(value) do
          {:ok, key} when byte_size(key) == 32 -> :ok
          {:error, _reason} -> invalid("public_key", "must be an encoded public key")
          {:ok, _key} -> invalid("public_key", "must be an encoded public key")
        end

      {:ok, _value} ->
        invalid("public_key", "must be an encoded public key")

      :error ->
        invalid("public_key", "is required")
    end
  end

  defp required_binary(map, key, field) do
    case fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> :ok
      {:ok, _value} -> invalid(field, "must be a non-empty string")
      :error -> invalid(field, "is required")
    end
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp field_name(field) when is_atom(field), do: Atom.to_string(field)
  defp field_name(field) when is_binary(field), do: field
  defp field_name(field), do: inspect(field)

  defp invalid(field, reason), do: {:error, {:invalid_declaration, field, reason}}

  defp normalized_declaration(declaration) do
    Map.new(@fields, fn field -> {Atom.to_string(field), value!(declaration, field)} end)
  end

  defp to_declaration(declaration) do
    struct!(__MODULE__, Map.new(@fields, fn field -> {field, value!(declaration, field)} end))
  end

  defp value!(map, key) do
    {:ok, value} = fetch(map, key)
    value
  end
end
