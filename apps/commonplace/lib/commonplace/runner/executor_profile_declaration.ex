defmodule Commonplace.Runner.ExecutorProfileDeclaration do
  @moduledoc """
  The one-field editable declaration selecting a repository-owned executor profile.

  The only declared fact is the repository-owned profile's name. Unknown
  fields are refused before selection, so recipe, command, exec, and any future
  field can neither reach a selector nor be passed through as profile data.
  This module declares and selects; it executes nothing.
  """

  alias Commonplace.Runner.ExecutorProfile

  @fields [:profile]
  @field_names Enum.map(@fields, &Atom.to_string/1)

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{profile: String.t()}
  @type invalid_declaration ::
          {:invalid_executor_profile_declaration, String.t(), String.t()}

  @doc "Validate the sole declaration field and refuse every unknown field."
  @spec validate(t() | map()) :: :ok | {:error, invalid_declaration()}
  def validate(declaration) when is_map(declaration) do
    with :ok <- reject_unknown_fields(declaration),
         :ok <- required_profile_name(declaration) do
      :ok
    end
  end

  def validate(_declaration), do: invalid("declaration", "must be an object")

  @doc "Encode a valid profile-name declaration as JSON."
  @spec encode(t() | map()) :: {:ok, String.t()} | {:error, term()}
  def encode(declaration) do
    with :ok <- validate(declaration) do
      Jason.encode(%{"profile" => value!(declaration, :profile)})
    end
  end

  @doc "Decode JSON and validate it before returning a declaration."
  @spec decode(String.t()) :: {:ok, t()} | {:error, term()}
  def decode(document) when is_binary(document) do
    with {:ok, decoded} <- decode_json(document),
         :ok <- validate(decoded) do
      {:ok, %__MODULE__{profile: value!(decoded, :profile)}}
    end
  end

  @doc "Validate a declaration before passing only its profile name to selection."
  @spec resolve(t() | map(), (String.t() -> {:ok, ExecutorProfile.t()} | {:error, term()})) ::
          {:ok, ExecutorProfile.t()} | {:error, term()}
  def resolve(declaration, selector \\ &ExecutorProfile.select/1) when is_function(selector, 1) do
    with :ok <- validate(declaration) do
      selector.(value!(declaration, :profile))
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

  defp required_profile_name(declaration) do
    case fetch(declaration, :profile) do
      {:ok, value} when is_binary(value) and value != "" -> :ok
      {:ok, _value} -> invalid("profile", "must be a non-empty string")
      :error -> invalid("profile", "is required")
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

  defp invalid(field, reason) do
    {:error, {:invalid_executor_profile_declaration, field, reason}}
  end

  defp value!(map, key) do
    {:ok, value} = fetch(map, key)
    value
  end
end
