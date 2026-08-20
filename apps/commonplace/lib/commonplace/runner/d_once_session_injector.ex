defmodule Commonplace.Runner.DOnceSessionInjector do
  @moduledoc """
  (D)-ONCE host-side-once session store + per-pod injection (S2, discovery
  build). Reads the durable device-auth session the runner holds host-side,
  and extracts ONLY the per-pod bundle — `access_token` + `installation_id`
  — REFUSING the `refresh_token` BY CONSTRUCTION. The durable refresh token
  stays home; the pod gets a short-lived access token (via codex's own
  `--with-access-token` stdin) plus the copyable `installation_id`.

  Design read + accepted by boss (storage read, 2026-08-20), path named:
  `$XDG_STATE_HOME/commonplace-runner/d-once-session/`, fallback
  `~/.local/state/commonplace-runner/d-once-session/`. ⛔ boss's added
  clause, honored: an unset `XDG_STATE_HOME` must NOT silently produce
  `/commonplace-runner/...` or a relative path — the resolution REFUSES
  rather than guesses when neither an absolute XDG state dir nor an
  absolute HOME is available.

  ⛔ Invariants, each a red-capable test not a design intention:
  1. **The store is STRUCTURALLY outside any git tree** — the caller
     provides an absolute base; this module never joins a repo path.
  2. **`refresh_token` never enters the pod bundle** — `pod_bundle/1`
     returns exactly `%{access_token, installation_id}` and no other key;
     no code path reads `refresh_token` into what a pod can see.
  3. **Key PATHS in diagnostics, never VALUES** — every error names the
     missing key path (e.g. `"tokens.access_token"`) and never a value.
  """

  @store_subpath ["commonplace-runner", "d-once-session"]
  @session_file "auth.json"

  @doc """
  Resolve the durable host-side session store DIRECTORY.

  `$XDG_STATE_HOME/commonplace-runner/d-once-session/` when XDG_STATE_HOME
  is an absolute path; else `$HOME/.local/state/commonplace-runner/d-once-session/`
  when HOME is absolute; else `{:error, :session_store_unresolvable}` —
  REFUSE, never guess. Both fallbacks are EXPLICIT; neither is an
  empty-variable path join.
  """
  @spec store_dir() :: {:ok, Path.t()} | {:error, :session_store_unresolvable}
  def store_dir do
    case absolute_env("XDG_STATE_HOME") do
      {:ok, xdg} ->
        {:ok, Path.join([xdg | @store_subpath])}

      :unset ->
        case absolute_env("HOME") do
          {:ok, home} -> {:ok, Path.join([home, ".local", "state" | @store_subpath])}
          :unset -> {:error, :session_store_unresolvable}
        end
    end
  end

  @doc "The durable session file path, or the store's unresolvable refusal."
  @spec session_path() :: {:ok, Path.t()} | {:error, :session_store_unresolvable}
  def session_path do
    with {:ok, dir} <- store_dir(), do: {:ok, Path.join(dir, @session_file)}
  end

  @doc """
  Extract the per-pod injection bundle from a decoded session map.

  Returns `{:ok, %{access_token: String.t(), installation_id: String.t()}}`
  — EXACTLY those two keys, never the refresh token. Refuses by naming the
  missing key PATH, never a value.
  """
  @spec pod_bundle(map()) ::
          {:ok, %{access_token: String.t(), installation_id: String.t()}} | {:error, term()}
  def pod_bundle(%{} = session) do
    with {:ok, tokens} <- fetch_map(session, "tokens"),
         {:ok, access} <- fetch_nonempty(tokens, "access_token", "tokens.access_token"),
         {:ok, installation_id} <- fetch_installation_id(session) do
      # ⛔ The returned map is CONSTRUCTED with exactly two keys. There is no
      # path by which refresh_token reaches it: it is never read here.
      {:ok, %{access_token: access, installation_id: installation_id}}
    end
  end

  def pod_bundle(_other), do: {:error, :session_not_a_map}

  # installation_id may live at the top level or under a client/session
  # sub-object depending on how codex persisted it; accept either, refuse
  # by name if absent.
  defp fetch_installation_id(session) do
    cond do
      is_binary(session["installation_id"]) and session["installation_id"] != "" ->
        {:ok, session["installation_id"]}

      is_map(session["tokens"]) and is_binary(session["tokens"]["installation_id"]) and
          session["tokens"]["installation_id"] != "" ->
        {:ok, session["tokens"]["installation_id"]}

      true ->
        {:error, {:credential_key_missing, "installation_id"}}
    end
  end

  defp absolute_env(name) do
    case System.get_env(name) do
      v when is_binary(v) and v != "" ->
        if String.starts_with?(v, "/"), do: {:ok, v}, else: :unset

      _ ->
        :unset
    end
  end

  defp fetch_map(map, key) do
    case Map.get(map, key) do
      %{} = m -> {:ok, m}
      _ -> {:error, {:credential_key_missing, key}}
    end
  end

  defp fetch_nonempty(map, leaf, path) do
    case Map.get(map, leaf) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:credential_key_missing, path}}
    end
  end
end
