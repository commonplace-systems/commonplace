defmodule Commonplace.Invariants.Engine do
  @moduledoc """
  The generic runner over declared `%Commonplace.Invariants.Invariant{}`
  objects, per the 2026-08-05 resting-state invariants design
  (`docs/plans/2026-08-05-resting-state-invariants-design.md`, §4 build
  shape item 2: "One validator engine"). Step 1 scope only: this
  module READS and REPORTS. It never writes, refuses, or repairs
  anything.

  ## What "generic" means here

  Before this module, `Commonplace.Bd.Invariants.check_all/2` hardcoded
  which invariants exist, how each is enumerated (per-ticket vs.
  whole-corpus), and how results are shaped. This engine takes that
  knowledge OUT of the runner and INTO the declared `Invariant` structs
  (`Commonplace.Invariants.Registry`) — the engine only knows how to
  run a `:per_subject` invariant (enumerate, then check each subject)
  or a `:whole` one (check once), uniformly, regardless of domain.
  `Commonplace.Bd.Invariants.check_all/2` is now a thin shape-adapter
  on top of `run/2` (see that module).

  ## The knob is load-bearing on every result

  Per `Commonplace.Invariants.Mode`'s moduledoc, an invariant layer
  that silently runs in dry-run forever is a known drift class. So
  every `run/2` result carries `Mode.describe()` — no output of this
  engine is readable without knowing which knob position produced it.

  ## The engine performs exactly one response: alarm

  It reports. That IS the alarm (§2 item 1: "red event + standing
  black query as the continuous audit"; this engine's return value is
  the substrate a caller turns into that red event — this module does
  not itself emit one, see the "not built" note below). Any OTHER
  response an invariant declares (`:block_promotion`,
  `:deterministic_repair`, `:serialize_via_green`) is never silently
  ignored: it is collected into `unimplemented_responses` so declaring
  a response ahead of the wiring that performs it is visible, not a
  silent no-op. With the registry as shipped (step 1: every entry is
  `responses: [:alarm]`), `unimplemented_responses` is always empty —
  this path exists for when a future registry entry declares more
  than the engine can yet perform.

  ## Not built by this module

  This is the choke-bound dispatch (§4 item 2, §7 R2/R9) — hooking
  `set_latest`/`create_chained_commit` so validation runs on every
  head-advance regardless of caller — is NOT this module's job and
  is not wired here. `run/2` is called explicitly by whatever invokes
  it (today: `Commonplace.Bd.Invariants.check_all/2`, in turn called
  by `bin/bd-invariants`'s standing audit). Nothing here subscribes to
  writes or intercepts the store.
  """

  alias Commonplace.Invariants.{Invariant, Mode, Registry}

  @type result_map :: %{
          name: atom(),
          scope: map(),
          deferral: Invariant.deferral(),
          responses: [Invariant.response()],
          checked: non_neg_integer(),
          ok: non_neg_integer(),
          violations: [map()],
          errors: [map()]
        }

  @performed_responses [:alarm]
  @valid_opts [:only, :domain, :deferral]

  @doc """
  Runs a set of invariants against `context` and returns a structured,
  per-invariant report.

  ## Options

    * `:only` — list of invariant names; run exactly these.
    * `:domain` — run only invariants whose `scope.domain` matches.
    * `:deferral` — run only invariants whose `:deferral` matches.

  Filters compose (AND). Unknown option keys raise `ArgumentError` —
  a typo'd filter should never silently run the unfiltered set.

  Returns:

      %{
        mode: :alarm_only | :enforce,
        knob: %{mode:, source:, raw:},
        results: %{invariant_name => result_map},
        unimplemented_responses: %{invariant_name => [atom()]}
      }
  """
  @spec run(term(), keyword()) :: %{
          mode: Mode.mode(),
          knob: map(),
          results: %{atom() => result_map()},
          unimplemented_responses: %{atom() => [Invariant.response()]}
        }
  def run(context, opts \\ []) do
    check_opts!(opts)

    knob = Mode.describe()
    invariants = select(opts)

    results =
      invariants
      |> Enum.map(fn invariant -> {invariant.name, run_invariant(invariant, context)} end)
      |> Map.new()

    unimplemented =
      invariants
      |> Enum.map(fn invariant ->
        {invariant.name, invariant.responses -- @performed_responses}
      end)
      |> Enum.reject(fn {_name, unimplemented} -> unimplemented == [] end)
      |> Map.new()

    %{
      mode: knob.mode,
      knob: knob,
      results: results,
      unimplemented_responses: unimplemented
    }
  end

  @doc """
  Runs a single invariant (by name, or an already-fetched
  `%Invariant{}`) against `context` and returns its `result_map`
  directly, without the `run/2` envelope.
  """
  @spec run_one(atom() | Invariant.t(), term()) :: result_map()
  def run_one(%Invariant{} = invariant, context), do: run_invariant(invariant, context)

  def run_one(name, context) when is_atom(name) do
    name |> Registry.fetch!() |> run_invariant(context)
  end

  defp check_opts!(opts) do
    Enum.each(Keyword.keys(opts), fn key ->
      unless key in @valid_opts do
        raise ArgumentError,
              "Commonplace.Invariants.Engine.run/2: unknown option #{inspect(key)} — " <>
                "must be one of #{inspect(@valid_opts)}"
      end
    end)
  end

  defp select(opts) do
    Registry.all()
    |> filter_only(Keyword.get(opts, :only))
    |> filter_domain(Keyword.get(opts, :domain))
    |> filter_deferral(Keyword.get(opts, :deferral))
  end

  defp filter_only(invariants, nil), do: invariants

  defp filter_only(invariants, names) when is_list(names) do
    Enum.filter(invariants, &(&1.name in names))
  end

  defp filter_domain(invariants, nil), do: invariants

  defp filter_domain(invariants, domain) do
    Enum.filter(invariants, &(&1.scope.domain == domain))
  end

  defp filter_deferral(invariants, nil), do: invariants

  defp filter_deferral(invariants, deferral) do
    Enum.filter(invariants, &(&1.deferral == deferral))
  end

  defp run_invariant(%Invariant{scope: %{granularity: :per_subject}} = invariant, context) do
    subjects = invariant.enumerate.(context)

    {ok, violations, errors} =
      Enum.reduce(subjects, {0, [], []}, fn subject, {ok, violations, errors} ->
        case invariant.check.(context, subject) do
          :ok ->
            {ok + 1, violations, errors}

          {:violation, details} ->
            {ok, [Map.put_new(details, :subject, subject) | violations], errors}

          {:error, reason} ->
            {ok, violations, [%{subject: subject, error: reason} | errors]}
        end
      end)

    base(invariant)
    |> Map.merge(%{
      checked: length(subjects),
      ok: ok,
      violations: Enum.reverse(violations),
      errors: Enum.reverse(errors)
    })
  end

  defp run_invariant(%Invariant{scope: %{granularity: :whole}} = invariant, context) do
    result =
      case invariant.check.(context) do
        :ok ->
          %{checked: 1, ok: 1, violations: [], errors: []}

        {:violation, details} ->
          %{checked: 1, ok: 0, violations: [details], errors: []}

        {:error, reason} ->
          %{checked: 1, ok: 0, violations: [], errors: [%{error: reason}]}
      end

    Map.merge(base(invariant), result)
  end

  defp base(%Invariant{} = invariant) do
    %{
      name: invariant.name,
      scope: invariant.scope,
      deferral: invariant.deferral,
      responses: invariant.responses
    }
  end
end
