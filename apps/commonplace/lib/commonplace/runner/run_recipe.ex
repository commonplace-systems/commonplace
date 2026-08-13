defmodule Commonplace.Runner.RunRecipe do
  @moduledoc """
  The six-field, repository-owned declaration for running an application.

  A recipe declares setup commands, the run entry point, its serving port,
  environment variable names, a readiness path, and versioned service
  requirements. Environment values are forbidden. Service requirements are
  declarations for placement matching; this module never infers, provisions,
  starts, or probes anything.
  """

  alias Commonplace.Runner.PodProfile

  @fields [:setup, :run, :port, :env, :ready, :requires]
  @field_names Enum.map(@fields, &Atom.to_string/1)

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          setup: [String.t()],
          run: String.t(),
          port: 1..65_535,
          env: [String.t()],
          ready: String.t(),
          requires: %{String.t() => String.t()}
        }

  @type invalid_recipe :: {:invalid_recipe, String.t(), String.t()}

  @doc "Validate all six recipe fields and refuse unknown fields."
  @spec validate(t() | map()) :: :ok | {:error, invalid_recipe()}
  def validate(recipe) when is_map(recipe) do
    with :ok <- reject_unknown_fields(recipe),
         :ok <- required_string_list(recipe, :setup, "setup"),
         :ok <- required_binary(recipe, :run, "run"),
         :ok <- required_port(recipe),
         :ok <- required_env_names(recipe),
         :ok <- required_binary(recipe, :ready, "ready"),
         :ok <- required_requires(recipe) do
      :ok
    end
  end

  def validate(_recipe), do: invalid("recipe", "must be an object")

  @doc "Encode a valid recipe as JSON."
  @spec encode(t() | map()) :: {:ok, String.t()} | {:error, term()}
  def encode(recipe) do
    with :ok <- validate(recipe) do
      recipe
      |> normalized_recipe()
      |> Jason.encode()
    end
  end

  @doc "Decode JSON and validate it before returning a recipe struct."
  @spec decode(String.t()) :: {:ok, t()} | {:error, term()}
  def decode(document) when is_binary(document) do
    with {:ok, decoded} <- decode_json(document),
         :ok <- validate(decoded) do
      {:ok, to_recipe(decoded)}
    end
  end

  @doc "Read a caller-supplied recipe path, distinguishing absence from presence."
  @spec read(Path.t()) ::
          {:ok, %{case: :absent}}
          | {:ok, %{case: :present, recipe: t()}}
          | {:error, term()}
  def read(path) when is_binary(path) do
    case File.read(path) do
      {:ok, document} ->
        with {:ok, recipe} <- decode(document) do
          {:ok, %{case: :present, recipe: recipe}}
        end

      {:error, :enoent} ->
        {:ok, %{case: :absent}}

      {:error, reason} ->
        {:error, {:recipe_read_failed, path, reason}}
    end
  end

  defp decode_json(document) do
    case Jason.decode(document) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> invalid("recipe", "must be valid JSON")
    end
  end

  defp reject_unknown_fields(recipe) do
    recipe
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

  defp required_port(recipe) do
    case fetch(recipe, :port) do
      {:ok, port} when is_integer(port) and port in 1..65_535 -> :ok
      {:ok, _value} -> invalid("port", "must be an integer from 1 through 65535")
      :error -> invalid("port", "is required")
    end
  end

  defp required_env_names(recipe) do
    case fetch(recipe, :env) do
      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &non_empty_binary?/1),
          do: :ok,
          else: invalid("env", "must be a list of non-empty names")

      {:ok, values} when is_map(values) ->
        invalid("env", "must contain names only; values are forbidden")

      {:ok, _value} ->
        invalid("env", "must be a list of non-empty names")

      :error ->
        invalid("env", "is required")
    end
  end

  defp required_requires(recipe) do
    case fetch(recipe, :requires) do
      {:ok, requires} when is_map(requires) -> validate_requires(requires)
      {:ok, _value} -> invalid("requires", "must be an object")
      :error -> invalid("requires", "is required")
    end
  end

  defp validate_requires(requires) do
    valid? =
      Enum.all?(requires, fn
        {service, requirement}
        when is_binary(service) and service != "" and is_binary(requirement) ->
          requirement_valid?(service, requirement)

        _entry ->
          false
      end)

    if valid?,
      do: :ok,
      else: invalid("requires", "must contain non-empty service names and valid versions")
  end

  defp requirement_valid?(service, ">=" <> minimum) when minimum != "" do
    profile = %PodProfile{
      id: "recipe-validation",
      harness: "none",
      sandbox: "none",
      services: %{service => minimum}
    }

    PodProfile.match_requires(%{service => ">=" <> minimum}, profile) == :ok
  end

  defp requirement_valid?(_service, _requirement), do: false

  defp required_binary(map, key, field) do
    case fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> :ok
      {:ok, _value} -> invalid(field, "must be a non-empty string")
      :error -> invalid(field, "is required")
    end
  end

  defp required_string_list(map, key, field) do
    case fetch(map, key) do
      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &non_empty_binary?/1),
          do: :ok,
          else: invalid(field, "must be a list of non-empty strings")

      {:ok, _value} ->
        invalid(field, "must be a list of non-empty strings")

      :error ->
        invalid(field, "is required")
    end
  end

  defp non_empty_binary?(value), do: is_binary(value) and value != ""

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp field_name(field) when is_atom(field), do: Atom.to_string(field)
  defp field_name(field) when is_binary(field), do: field
  defp field_name(field), do: inspect(field)

  defp invalid(field, reason), do: {:error, {:invalid_recipe, field, reason}}

  defp normalized_recipe(recipe) do
    Map.new(@fields, fn field -> {Atom.to_string(field), value!(recipe, field)} end)
  end

  defp to_recipe(recipe) do
    struct!(__MODULE__, Map.new(@fields, fn field -> {field, value!(recipe, field)} end))
  end

  defp value!(map, key) do
    {:ok, value} = fetch(map, key)
    value
  end
end
