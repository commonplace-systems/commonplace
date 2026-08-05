defmodule Commonplace.Invariants.Invariant do
  @moduledoc """
  A declared resting-state invariant, per the 2026-08-05 resting-state
  invariants design ruling
  (`docs/plans/2026-08-05-resting-state-invariants-design.md`, §4.1):
  "invariant = (scope, check over resting state, response policy)".

  This is step 1 of the build shape at §4: the registry is a doc,
  naturally — checks are declared OBJECTS, not bare functions the
  runner special-cases. This struct is that object.

  ## Fields

    * `:name` — atom, unique within a registry (`Registry.validate!/1`
      enforces this).
    * `:scope` — `%{domain: atom(), granularity: :per_subject | :whole}`.
      `domain` groups invariants for `Registry.for_domain/1` (e.g. `:bd`
      today); `granularity` says whether the check runs once per
      enumerated subject or once over the whole context.
    * `:enumerate` — arity-1 fun `(context -> [subject])`. Required
      when `granularity: :per_subject` (the engine must know what to
      iterate); must be `nil` when `granularity: :whole` (there is
      nothing to enumerate — the check IS the whole-corpus judgment).
    * `:check` — the invariant's judgment function. For `:per_subject`,
      arity-2: `(context, subject -> :ok | {:violation, map()} |
      {:error, term()})`. For `:whole`, arity-1: `(context -> same)`.
    * `:responses` — non-empty list drawn from the design's §2 fixed
      response menu: `[:alarm, :block_promotion, :deterministic_repair,
      :serialize_via_green]`. Per §2, alarm is the always-present
      minimum ("Alarm (always, minimum)") — every invariant's list
      must include `:alarm`.
    * `:deferral` — `:immediate` or `:context_dependent` (§4.1 / §7 R7:
      "some checks are decidable from the arriving state alone... while
      others are context-dependent"). This is a DECLARED design
      judgment about the check's own nature, not something the engine
      infers.
    * `:owner` — String, who to page when this fires.
    * `:doc` — String, non-empty: why this invariant exists. The
      registry is a doc, so every entry must actually document itself.

  ## What this module does NOT do

  It validates SHAPE (`new!/1`) — it does not run anything, wire any
  response, or decide enforcement. Running is `Commonplace.Invariants.
  Engine`'s job; the enforce/dry-run knob is `Commonplace.Invariants.
  Mode`'s. This module has no opinion about either.
  """

  @enforce_keys [:name, :scope, :check, :responses, :deferral, :owner, :doc]
  defstruct [:name, :scope, :enumerate, :check, :responses, :deferral, :owner, :doc]

  @type granularity :: :per_subject | :whole
  @type response :: :alarm | :block_promotion | :deterministic_repair | :serialize_via_green
  @type deferral :: :immediate | :context_dependent

  @type t :: %__MODULE__{
          name: atom(),
          scope: %{domain: atom(), granularity: granularity()},
          enumerate: (term() -> [term()]) | nil,
          check: (term(), term() -> term()) | (term() -> term()),
          responses: [response()],
          deferral: deferral(),
          owner: String.t(),
          doc: String.t()
        }

  @valid_responses [:alarm, :block_promotion, :deterministic_repair, :serialize_via_green]
  @valid_deferrals [:immediate, :context_dependent]
  @required_fields [:name, :scope, :check, :responses, :deferral, :owner, :doc]

  @doc """
  Builds and validates a `%Invariant{}` from a keyword list or map.
  Raises `ArgumentError` with a message specific to the exact defect —
  each rejection below is independently distinguishable, on purpose:
  a registry with a bad entry should tell you WHICH contract it broke,
  not just that something is wrong.
  """
  @spec new!(keyword() | map()) :: t()
  def new!(fields) when is_list(fields) or is_map(fields) do
    attrs = Map.new(fields)

    check_required!(attrs)

    name = Map.fetch!(attrs, :name)
    scope = Map.fetch!(attrs, :scope)
    enumerate = Map.get(attrs, :enumerate)
    check = Map.fetch!(attrs, :check)
    responses = Map.fetch!(attrs, :responses)
    deferral = Map.fetch!(attrs, :deferral)
    owner = Map.fetch!(attrs, :owner)
    doc = Map.fetch!(attrs, :doc)

    check_responses!(name, responses)
    check_deferral!(name, deferral)
    check_doc!(name, doc)
    granularity = check_granularity!(name, scope)
    check_enumerate!(name, granularity, enumerate)
    check_check_arity!(name, granularity, check)

    %__MODULE__{
      name: name,
      scope: scope,
      enumerate: enumerate,
      check: check,
      responses: responses,
      deferral: deferral,
      owner: owner,
      doc: doc
    }
  end

  defp check_required!(attrs) do
    Enum.each(@required_fields, fn field ->
      unless Map.has_key?(attrs, field) do
        raise ArgumentError, "Invariant.new!/1: missing required field #{inspect(field)}"
      end
    end)
  end

  defp check_responses!(name, responses) do
    unless is_list(responses) and responses != [] do
      raise ArgumentError,
            "Invariant #{inspect(name)}: :responses must be a non-empty list, got #{inspect(responses)}"
    end

    Enum.each(responses, fn response ->
      unless response in @valid_responses do
        raise ArgumentError,
              "Invariant #{inspect(name)}: unknown response #{inspect(response)} — " <>
                "must be one of #{inspect(@valid_responses)} (the design's §2 fixed menu)"
      end
    end)

    unless :alarm in responses do
      raise ArgumentError,
            "Invariant #{inspect(name)}: :responses #{inspect(responses)} does not contain " <>
              ":alarm — per the design's §2, alarm is the always-present minimum response"
    end
  end

  defp check_deferral!(name, deferral) do
    unless deferral in @valid_deferrals do
      raise ArgumentError,
            "Invariant #{inspect(name)}: unknown deferral class #{inspect(deferral)} — " <>
              "must be one of #{inspect(@valid_deferrals)}"
    end
  end

  defp check_doc!(name, doc) do
    unless is_binary(doc) and String.trim(doc) != "" do
      raise ArgumentError, "Invariant #{inspect(name)}: :doc must be a non-empty string"
    end
  end

  defp check_granularity!(name, scope) do
    case scope do
      %{domain: domain, granularity: granularity}
      when is_atom(domain) and granularity in [:per_subject, :whole] ->
        granularity

      _ ->
        raise ArgumentError,
              "Invariant #{inspect(name)}: :scope must be %{domain: atom(), " <>
                "granularity: :per_subject | :whole}, got #{inspect(scope)}"
    end
  end

  defp check_enumerate!(name, :per_subject, nil) do
    raise ArgumentError,
          "Invariant #{inspect(name)}: granularity :per_subject requires a non-nil :enumerate"
  end

  defp check_enumerate!(name, :per_subject, enumerate) do
    unless is_function(enumerate, 1) do
      raise ArgumentError,
            "Invariant #{inspect(name)}: :enumerate must be an arity-1 fun, got #{inspect(enumerate)}"
    end
  end

  defp check_enumerate!(_name, :whole, nil), do: :ok

  defp check_enumerate!(name, :whole, _enumerate) do
    raise ArgumentError,
          "Invariant #{inspect(name)}: granularity :whole requires :enumerate to be nil"
  end

  defp check_check_arity!(name, :per_subject, check) do
    unless is_function(check, 2) do
      raise ArgumentError,
            "Invariant #{inspect(name)}: :per_subject :check must be an arity-2 fun " <>
              "(context, subject -> result), got #{inspect(check)}"
    end
  end

  defp check_check_arity!(name, :whole, check) do
    unless is_function(check, 1) do
      raise ArgumentError,
            "Invariant #{inspect(name)}: :whole :check must be an arity-1 fun " <>
              "(context -> result), got #{inspect(check)}"
    end
  end
end
