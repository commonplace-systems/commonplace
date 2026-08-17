defmodule Commonplace.Runner.PodProfile do
  @moduledoc """
  The declared pod-profile format and pure requirement matcher for CX-3shs.

  A profile is a document with four required fields: `id`, `harness`,
  `sandbox`, and `services`. The first three are non-empty strings. `services`
  is a map from a non-empty service name to its declared version string.

  `network` is optional and declares the pod's network posture from a closed
  set. It is never a boolean and never a free-form value: a posture is a NAMED
  arrangement the provisioner knows how to build, and the profile -- not the
  launch caller -- is what selects it. An absent field means `"none"`, which is
  the strictest posture and the only one that exists today (`--unshare-all`,
  no network re-shared). The vocabulary is deliberately closed so that a new
  posture can only arrive together with the mechanism that enforces it --
  a value the provisioner cannot build is refused at validation, not
  discovered at launch.

  `match_requires/2` compares a declared `requires` map with that declared
  inventory. It does not inspect, probe, start, or provision services. It
  returns `:ok` only when every requirement is satisfied; otherwise it returns
  `{:refused, reasons}` with one reason for every unsatisfied requirement.

  Version requirements deliberately use a small, non-SemVer grammar. The only
  operator is `>=`, and both sides accept one to three dot-separated,
  non-negative integer components. Missing components are zero-filled before
  numeric tuple comparison. Thus `>=14` means `>=14.0.0`: it is satisfied by
  inventory version `16.2` and refused by `13.1`. Pre-release labels, build
  metadata, other operators, and any malformed requirement or inventory
  version are refused closed.
  """

  @enforce_keys [:id, :harness, :sandbox, :services]
  defstruct [:id, :harness, :sandbox, :services, network: "none"]

  # The closed set of network postures. Extend ONLY together with the
  # provisioner mechanism that builds the new posture (see
  # commonplace-plan docs/plans/2026-08-17-pod-model-credential.md for the
  # ruled next member, "mediator-socket": --unshare-net plus one bind-mounted
  # pathname socket -- its admission here waits on that mechanism landing).
  @network_postures ~w(none)

  @type t :: %__MODULE__{
          id: String.t(),
          harness: String.t(),
          sandbox: String.t(),
          services: %{String.t() => String.t()},
          network: String.t()
        }

  @spec network_postures() :: [String.t()]
  def network_postures, do: @network_postures

  @type match_result :: :ok | {:refused, [String.t()]}

  @spec decode(binary()) ::
          {:ok, t()}
          | {:error, String.t()}
          | {:error, {:invalid_profile, String.t(), String.t()}}
  def decode(document) when is_binary(document) do
    case Jason.decode(document) do
      {:ok, decoded} -> validate(decoded)
      {:error, _error} -> {:error, "invalid pod profile document JSON"}
    end
  end

  @spec validate(term()) ::
          {:ok, t()} | {:error, {:invalid_profile, String.t(), String.t()}}
  def validate(document) when is_map(document) do
    with {:ok, id} <- required_string(document, "id"),
         {:ok, harness} <- required_string(document, "harness"),
         {:ok, sandbox} <- required_string(document, "sandbox"),
         {:ok, services} <- required_services(document),
         {:ok, network} <- optional_network(document) do
      {:ok,
       %__MODULE__{
         id: id,
         harness: harness,
         sandbox: sandbox,
         services: services,
         network: network
       }}
    end
  end

  def validate(_document), do: invalid("profile", "must be an object")

  @spec match_requires(%{String.t() => String.t()}, t()) :: match_result()
  def match_requires(requires, %__MODULE__{services: services}) when is_map(requires) do
    refusals =
      requires
      |> Enum.sort_by(fn {service, _requirement} -> service end)
      |> Enum.reduce([], fn {service, requirement}, reasons ->
        if requirement_satisfied?(requirement, Map.get(services, service)) do
          reasons
        else
          [refusal_reason(service, requirement) | reasons]
        end
      end)
      |> Enum.reverse()

    case refusals do
      [] -> :ok
      reasons -> {:refused, reasons}
    end
  end

  defp required_string(document, field) do
    case fetch(document, field) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> invalid(field, "must be a non-empty string")
      :error -> invalid(field, "is required")
    end
  end

  defp required_services(document) do
    case fetch(document, "services") do
      {:ok, services} when is_map(services) -> validate_services(services)
      {:ok, _value} -> invalid("services", "must be an object")
      :error -> invalid("services", "is required")
    end
  end

  defp validate_services(services) do
    if Enum.all?(services, fn
         {service, version}
         when is_binary(service) and service != "" and is_binary(version) and version != "" ->
           true

         _entry ->
           false
       end) do
      {:ok, services}
    else
      invalid("services", "must contain non-empty service names and version strings")
    end
  end

  defp optional_network(document) do
    case fetch(document, "network") do
      :error ->
        # Absence selects the STRICTEST posture, explicitly normalized here so no
        # consumer ever reasons about a missing key.
        {:ok, "none"}

      {:ok, value} when value in @network_postures ->
        {:ok, value}

      {:ok, value} ->
        invalid(
          "network",
          "must be one of #{inspect(@network_postures)}, got #{inspect(value)}"
        )
    end
  end

  defp fetch(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, String.to_existing_atom(field))
    end
  end

  defp invalid(field, reason), do: {:error, {:invalid_profile, field, reason}}

  defp requirement_satisfied?(">=" <> minimum, provided) when is_binary(provided) do
    with {:ok, minimum_version} <- parse_version(minimum),
         {:ok, provided_version} <- parse_version(provided) do
      provided_version >= minimum_version
    else
      :error -> false
    end
  end

  defp requirement_satisfied?(_requirement, _provided), do: false

  defp parse_version(version) do
    components = String.split(version, ".")

    if length(components) in 1..3 and Enum.all?(components, &numeric_component?/1) do
      [major, minor, patch] =
        components
        |> Kernel.++(List.duplicate("0", 3 - length(components)))
        |> Enum.map(&String.to_integer/1)

      {:ok, {major, minor, patch}}
    else
      :error
    end
  end

  defp numeric_component?(component),
    do: Regex.match?(~r/\A(?:0|[1-9][0-9]*)\z/, component)

  defp refusal_reason(service, requirement),
    do: "this placement cannot satisfy requirement #{service} #{requirement}"
end
