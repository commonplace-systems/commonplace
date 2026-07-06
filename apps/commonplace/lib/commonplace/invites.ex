defmodule Commonplace.Invites do
  @moduledoc """
  Invite-based player onboarding (CX-qat5.2 §2.1) — friends-tier login
  for the browser door. No self-serve signup: an operator (IEx / MCP /
  CLI) calls `mint/4` for a named player, hands them the resulting URL
  out of band, and the browser redeems it once at `GET /login/:token`
  (`CommonplaceWebWeb.SessionController`).

  ## Two custody-bearing artifacts, two different rules

  `mint/4` produces two things and they get opposite treatment:

    * The player's Ed25519 keypair (via `Commonplace.Crypto.AgentKeys`)
      — long-lived, lives in the node-local `SecretStore`, never synced.
    * The one-time login token — a BEARER credential. Per the spec's
      "tokens hashed at rest" constraint, only `SHA-256(token)` is ever
      persisted (SecretStore slot `"invite:" <> Base.encode64(hash)`).
      The raw token exists only in the `mint/4` return value and in
      whatever out-of-band channel the operator uses to hand it to the
      player — never written to a log, never round-tripped through a
      synced document.

  ## Single-use redemption

  `redeem/2` deletes the slot BEFORE returning success — "delete-then-
  return" per the spec — so a second redemption of the same token
  (replay, or an operator accidentally sharing a used link) always sees
  `{:error, :invalid}`, indistinguishable from a token that never
  existed. Expired tokens are deleted on contact too: the first redeem
  attempt after expiry both cleans up the slot and reports
  `{:error, :expired}`; a second attempt after that reports `:invalid`
  (the slot is already gone), which is fine — the caller only needed to
  observe expiry once.

  Idempotence across `mint/4` calls is explicitly NOT required (per the
  spec): minting twice for the same player name is two independent
  invites (two tokens, potentially two redemptions by whoever holds
  either link) rather than a de-duplicated single invite.
  """

  alias Commonplace.Presence.Identity
  alias Commonplace.Store.{CommitStoreClient, SecretStore}

  @default_ttl_seconds 7 * 24 * 3600

  @doc """
  Register (or re-use, if already registered) a `:usr` player identity
  and mint a fresh one-time login token for it.

  Returns `{:ok, %{identity_uuid: uuid, token: raw_token_string,
  expires_at: %DateTime{}}}`.

  `opts`:
    * `:secret_store` — the SecretStore holding both the player's key
      custody (delegated to `register_player/4`) and the invite-token
      hash (this function's own write). Defaults to the global
      `Commonplace.Store.SecretStore`.
    * `:ttl_seconds` — token lifetime, default 7 days.
    * `:signing_context` — forwarded to `register_player/4` (D9:
      the minting operator signs the registration commits).
  """
  @spec mint(String.t(), String.t(), GenServer.server(), keyword()) ::
          {:ok, %{identity_uuid: String.t(), token: String.t(), expires_at: DateTime.t()}}
          | {:error, term()}
  def mint(player_name, root_uuid, store \\ CommitStoreClient, opts \\ [])
      when is_binary(player_name) and is_binary(root_uuid) and is_list(opts) do
    secret_store = Keyword.get(opts, :secret_store, SecretStore)
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)

    with {:ok, identity_uuid, _pub} <-
           Identity.register_player(player_name, root_uuid, store, opts) do
      token = mint_token()
      expires_at = DateTime.add(DateTime.utc_now(), ttl_seconds, :second)

      payload =
        Jason.encode!(%{
          "identity_uuid" => identity_uuid,
          "expires_at" => DateTime.to_iso8601(expires_at)
        })

      :ok = SecretStore.set(secret_store, invite_slot(token), payload)

      {:ok, %{identity_uuid: identity_uuid, token: token, expires_at: expires_at}}
    end
  end

  @doc """
  Redeem a one-time login token. Single-use (delete-then-return): a
  second redemption of the same token, or redemption after expiry-
  triggered cleanup, returns `{:error, :invalid}`.

  Returns `{:ok, identity_uuid}` | `{:error, :invalid | :expired}`.
  """
  @spec redeem(String.t(), GenServer.server()) ::
          {:ok, String.t()} | {:error, :invalid | :expired}
  def redeem(token, secret_store \\ SecretStore) when is_binary(token) do
    slot = invite_slot(token)

    case SecretStore.get(secret_store, slot) do
      :not_found ->
        {:error, :invalid}

      {:ok, payload} ->
        # Delete-then-return (spec §2.1): the slot is gone the instant
        # we've observed it, win or lose — a concurrent or replayed
        # second redemption always lands in the :not_found branch above.
        :ok = SecretStore.delete(secret_store, slot)
        decode_and_check_expiry(payload)
    end
  end

  # --- Private ---

  defp mint_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp invite_slot(token) do
    "invite:" <> Base.encode64(:crypto.hash(:sha256, token))
  end

  defp decode_and_check_expiry(payload) do
    with {:ok, %{"identity_uuid" => uuid, "expires_at" => expires_iso}} <- Jason.decode(payload),
         {:ok, expires_at, _offset} <- DateTime.from_iso8601(expires_iso) do
      if DateTime.compare(DateTime.utc_now(), expires_at) == :gt do
        {:error, :expired}
      else
        {:ok, uuid}
      end
    else
      _ -> {:error, :invalid}
    end
  end
end
