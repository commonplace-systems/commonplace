defmodule Commonplace.Crypto.AgentKeys do
  @moduledoc """
  Per-agent Ed25519 signing keys (CX-88mw, federate-for-real phase B).

  The per-agent analog of `Commonplace.Crypto.NodeIdentity`: private keys
  live in the node-local SecretStore (never synced), keyed by the agent's
  identity UUID under `"signing_key:<identity_uuid>"` /
  `"signing_pub:<identity_uuid>"` — base64 at rest, mirroring the
  `:default` slots (decision D5). `CommitStore.global_secret_context` is
  not touched; per-call `SigningContext` threading bypasses the global
  slots by design.

  The public key is additionally appended to the agent's identity doc for
  convenience (`Presence.Identity.add_public_key/4`) — but AUTHORITY
  comes from a capability cert delegated to the key (phase 3), not from
  the doc (decision D6, the anchor rule from trust-and-attenuation.md).

  Rotation (D10, minimal v1): `rotate/2` mints a replacement pair and
  overwrites the SecretStore slots; callers append the new pubkey to the
  identity doc (history preserved — `add_public_key` appends). Certs
  delegated to the OLD key stay valid until expiry; as-of-commit-time
  verification semantics are deferred.

  Every function takes a trailing SecretStore server argument (default:
  the application's global `Commonplace.Store.SecretStore`) so tests and
  multi-store embedders can isolate custody.
  """

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Store.SecretStore

  @doc """
  Mint (idempotently) a keypair for an identity. Returns `{:ok, public_key}`
  (raw 32-byte Ed25519 pubkey). A second call returns the same key.
  """
  @spec ensure(String.t(), GenServer.server()) :: {:ok, binary()} | {:error, term()}
  def ensure(identity_uuid, secret_store \\ SecretStore) when is_binary(identity_uuid) do
    case SecretStore.get(secret_store, pub_slot(identity_uuid)) do
      {:ok, encoded} ->
        case Base.decode64(encoded) do
          {:ok, pub} -> {:ok, pub}
          :error -> {:error, :corrupt_key}
        end

      :not_found ->
        mint(identity_uuid, secret_store)
    end
  end

  @doc """
  The agent's `%SigningContext{}` (raw key bytes, ready for the
  `:signing_context` commit opt), or `:not_found` when no keypair has
  been minted for this identity.
  """
  @spec signing_context_for(String.t(), GenServer.server()) ::
          {:ok, SigningContext.t()} | :not_found | {:error, :corrupt_key}
  def signing_context_for(identity_uuid, secret_store \\ SecretStore)
      when is_binary(identity_uuid) do
    with {:ok, enc_priv} <- SecretStore.get(secret_store, priv_slot(identity_uuid)),
         {:ok, enc_pub} <- SecretStore.get(secret_store, pub_slot(identity_uuid)),
         {:ok, priv} <- Base.decode64(enc_priv),
         {:ok, pub} <- Base.decode64(enc_pub) do
      {:ok, %SigningContext{identity_uuid: identity_uuid, private_key: priv, public_key: pub}}
    else
      :not_found -> :not_found
      :error -> {:error, :corrupt_key}
    end
  end

  @doc """
  The agent's `%SigningContext{}` in the `{:error, reason}`-tupled shape
  the browser-session resolution seam expects (CX-qat5.2 §2.3): checks
  custody FIRST (no minting here — that's `ensure/2`'s job) and returns
  `{:error, :not_found}` rather than the bare `:not_found` atom
  `signing_context_for/2` uses, so `SessionIdentity.resolve/1` can treat
  every failure branch (missing key, corrupt key) uniformly with a
  single `with`/`else`.
  """
  @spec signing_context(String.t(), GenServer.server()) ::
          {:ok, SigningContext.t()} | {:error, :not_found | :corrupt_key}
  def signing_context(identity_uuid, secret_store \\ SecretStore) when is_binary(identity_uuid) do
    case signing_context_for(identity_uuid, secret_store) do
      {:ok, ctx} -> {:ok, ctx}
      :not_found -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  @doc "Read an identity's current public key without touching its private-key slot."
  @spec public_key(String.t(), GenServer.server()) ::
          {:ok, binary()} | {:error, :not_found | :corrupt_key}
  def public_key(identity_uuid, secret_store \\ SecretStore) when is_binary(identity_uuid) do
    case SecretStore.get(secret_store, pub_slot(identity_uuid)) do
      {:ok, encoded} ->
        case Base.decode64(encoded) do
          {:ok, pub} when byte_size(pub) == 32 -> {:ok, pub}
          _ -> {:error, :corrupt_key}
        end

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc """
  Mint a replacement keypair, overwriting the custody slots (D10).
  Certs delegated to the old key stay valid until expiry; the caller is
  responsible for appending the new pubkey to the identity doc.
  """
  @spec rotate(String.t(), GenServer.server()) :: {:ok, binary()}
  def rotate(identity_uuid, secret_store \\ SecretStore) when is_binary(identity_uuid) do
    mint(identity_uuid, secret_store)
  end

  defp mint(identity_uuid, secret_store) do
    {pub, priv} = Signing.generate_keypair()
    :ok = SecretStore.set(secret_store, priv_slot(identity_uuid), Base.encode64(priv))
    :ok = SecretStore.set(secret_store, pub_slot(identity_uuid), Base.encode64(pub))
    {:ok, pub}
  end

  defp priv_slot(uuid), do: "signing_key:" <> uuid
  defp pub_slot(uuid), do: "signing_pub:" <> uuid
end
