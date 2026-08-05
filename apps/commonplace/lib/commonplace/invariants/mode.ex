defmodule Commonplace.Invariants.Mode do
  @moduledoc """
  The invariant-layer enforce knob, per the 2026-08-05 resting-state
  invariants design (`docs/plans/2026-08-05-resting-state-invariants-design.md`,
  §4.3 / §7 R9 point 3): "Alarm-only first (observe before refuse),
  with the explicit enforce knob separate from trust config — the
  dry-run trap is lesson 1 of the gate-testing checklist, and an
  invariant layer that silently runs in dry-run forever is this week's
  drift lesson waiting to recur."

  This module is read in exactly ONE place by design — `mode/0` is the
  single resolution point, so there is exactly one function in the
  codebase that can get the knob wrong. Everything else (the Engine,
  future response wiring) calls `mode/0` or `enforcement_active?/0`
  rather than re-reading `Application.get_env`/`System.get_env` itself.

  ## Resolution order

  1. `Application.get_env(:commonplace, :invariant_enforcement)` —
     checked first so tests and release config can pin a value.
  2. `System.get_env("COMMONPLACE_INVARIANT_ENFORCEMENT")` — accepts
     the literal strings `"alarm_only"` or `"enforce"`.
  3. Default: `:alarm_only`.

  ## The "check that cannot fail" note

  An explicitly-set but UNRECOGNISED value (wrong atom in app env, a
  typo'd env var string) raises `ArgumentError` naming the bad value,
  rather than silently falling back to `:alarm_only`. Absence of the
  knob is a valid, intentional default; a *typo* of the knob silently
  reading as `:alarm_only` is exactly the defect class this repo calls
  "a check that cannot fail" (`reference_checks_that_cannot_fail.md`)
  — a misconfigured enforce knob that LOOKS like a deliberately
  conservative default is worse than one that visibly breaks, because
  nobody investigates a knob that appears to be working.

  ## What this module does NOT do (the rest of §4.3)

  §4.3 also requires the knob's state be visible **as a doc, not only
  app env** ("The knob's state must be visible (a doc, not a config
  file nobody reads)"). This module does not do that yet —
  `describe/0` returns a plain map for a caller to surface, but nothing
  here writes it anywhere durable or readable outside the BEAM node
  that resolved it. Making the resolved mode visible as a doc (so it
  survives a restart, is readable without RPC, and is auditable the
  way the rest of this design treats truth as state) is the remaining
  part of §4.3 and is NOT built by this module. Do not read
  `describe/0`'s existence as satisfying that requirement.
  """

  @env_var "COMMONPLACE_INVARIANT_ENFORCEMENT"
  @default :alarm_only
  @valid_modes [:alarm_only, :enforce]

  @type mode :: :alarm_only | :enforce
  @type source :: :app_env | :env_var | :default

  @doc """
  Resolves the current enforce mode. See moduledoc for resolution
  order. Raises `ArgumentError` if an explicitly-set value (app env or
  env var) doesn't parse to a known mode.
  """
  @spec mode() :: mode()
  def mode(), do: describe().mode

  @doc "`true` when the resolved mode is `:enforce`."
  @spec enforcement_active?() :: boolean()
  def enforcement_active?(), do: mode() == :enforce

  @doc """
  Resolves the mode AND reports where it came from, so any report
  built on top of the engine can state which knob position produced
  it, not just what the position was.
  """
  @spec describe() :: %{mode: mode(), source: source(), raw: term()}
  def describe() do
    case Application.get_env(:commonplace, :invariant_enforcement) do
      nil ->
        resolve_env_var()

      raw ->
        %{mode: validate_app_env!(raw), source: :app_env, raw: raw}
    end
  end

  defp resolve_env_var() do
    case System.get_env(@env_var) do
      nil ->
        %{mode: @default, source: :default, raw: nil}

      raw ->
        %{mode: validate_env_string!(raw), source: :env_var, raw: raw}
    end
  end

  defp validate_app_env!(raw) when raw in @valid_modes, do: raw

  defp validate_app_env!(raw) do
    raise ArgumentError,
          "Commonplace.Invariants.Mode: application env :commonplace, " <>
            ":invariant_enforcement is set to #{inspect(raw)}, which is not a recognised " <>
            "mode — must be one of #{inspect(@valid_modes)}. Absence is a valid default " <>
            "(:alarm_only); an unrecognised VALUE is not — it is treated as a " <>
            "misconfiguration and raised, not silently downgraded."
  end

  defp validate_env_string!("alarm_only"), do: :alarm_only
  defp validate_env_string!("enforce"), do: :enforce

  defp validate_env_string!(raw) do
    raise ArgumentError,
          "Commonplace.Invariants.Mode: environment variable #{@env_var} is set to " <>
            "#{inspect(raw)}, which is not a recognised mode — must be \"alarm_only\" or " <>
            "\"enforce\". Absence is a valid default (:alarm_only); an unrecognised VALUE " <>
            "is not — it is treated as a misconfiguration and raised, not silently downgraded."
  end
end
