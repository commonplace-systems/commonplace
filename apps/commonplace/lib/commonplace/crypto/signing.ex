defmodule Commonplace.Crypto.Signing do
  @moduledoc """
  Ed25519 commit signing and verification.

  Uses Erlang's :crypto module for Ed25519 operations.
  Private keys are stored in SecretStore, public keys are
  shared in the __keys document.
  """

  alias Commonplace.Store.Commit

  @doc "Generate a new Ed25519 keypair. Returns {public_key, private_key}."
  def generate_keypair do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {pub, priv}
  end

  @doc """
  Sign a commit with an Ed25519 private key.
  Returns a new commit with signature and signer_id fields set.
  """
  def sign_commit(%Commit{} = commit, private_key, signer_id)
      when is_binary(private_key) and is_binary(signer_id) do
    signature = :crypto.sign(:eddsa, :none, commit.id, [private_key, :ed25519])
    %{commit | signature: signature, signer_id: signer_id}
  end

  @doc """
  Verify a commit's signature against a public key.
  Returns :ok or {:error, reason}.
  """
  def verify_commit(%Commit{signature: nil}), do: {:error, :unsigned}

  def verify_commit(%Commit{} = commit, public_key) when is_binary(public_key) do
    case :crypto.verify(:eddsa, :none, commit.id, commit.signature, [public_key, :ed25519]) do
      true -> :ok
      false -> {:error, :invalid_signature}
    end
  end

  @doc "Check if a commit is signed."
  def signed?(%Commit{signature: sig}) when not is_nil(sig), do: true
  def signed?(%Commit{}), do: false

  @doc "Encode a public key as base64 for storage/display."
  def encode_key(key), do: Base.encode64(key)

  @doc "Decode a base64-encoded key."
  def decode_key(encoded) do
    case Base.decode64(encoded) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :invalid_encoding}
    end
  end
end
