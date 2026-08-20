defmodule Commonplace.Runner.MediatorCredentials do
  @moduledoc """
  Loads the host mediator's vendor credentials from the operator's codex
  auth artifact (M-CUTOVER-1 host-side glue, plan-ratified 2026-08-20).

  Custody is identical to today's wrapper — the operator's `auth.json` is
  the same file `codex` reads under `sol-egress-run.sh` — with ONE FEWER
  COPY: the mediator reads `tokens.access_token`/`tokens.refresh_token`
  directly at service start rather than a value re-placed by hand.

  ⛔ Two invariants, both from the delegation-root corrupt-half lesson:

  1. **Refuse by name, never nil.** Every missing or empty key returns a
     named `{:error, ...}`; a nil credential must never limp into the
     mediator, where it would surface as a vendor auth failure at the
     first forward instead of a loud refusal at boot.
  2. **Key names only in every diagnostic.** No error term carries a token
     value. `{:credential_key_missing, "tokens.access_token"}` names the
     path; it never quotes what was or was not there.

  The returned map is exactly the `Mediator.start_link/1` `:credentials`
  shape: `%{access: String.t(), refresh: String.t()}`.
  """

  @spec load(Path.t()) ::
          {:ok, %{access: String.t(), refresh: String.t()}} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, raw} <- read(path),
         {:ok, json} <- decode(raw),
         {:ok, tokens} <- fetch_map(json, "tokens"),
         {:ok, access} <- fetch_nonempty(tokens, "tokens.access_token", "access_token"),
         {:ok, refresh} <- fetch_nonempty(tokens, "tokens.refresh_token", "refresh_token") do
      {:ok, %{access: access, refresh: refresh}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, raw} -> {:ok, raw}
      {:error, reason} -> {:error, {:credential_artifact_unreadable, reason}}
    end
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = json} -> {:ok, json}
      {:ok, _other} -> {:error, :credential_artifact_not_json}
      {:error, _} -> {:error, :credential_artifact_not_json}
    end
  end

  defp fetch_map(json, key) do
    case Map.get(json, key) do
      %{} = map -> {:ok, map}
      _ -> {:error, {:credential_key_missing, key}}
    end
  end

  # The error names the FULL path (e.g. "tokens.access_token") while the
  # lookup uses the leaf key inside the already-fetched submap — so a
  # diagnostic reader sees where to look without the value ever appearing.
  defp fetch_nonempty(map, path, leaf) do
    case Map.get(map, leaf) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:credential_key_missing, path}}
    end
  end
end
