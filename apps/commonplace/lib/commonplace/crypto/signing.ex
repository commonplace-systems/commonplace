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

  # Guard nil signatures on the /2 head too: :crypto.verify raises badarg on a
  # nil signature, and the adversarial input at the import gate is precisely an
  # unsigned commit. Return the same {:error, :unsigned} as /1 rather than crash.
  def verify_commit(%Commit{signature: nil}, _public_key), do: {:error, :unsigned}

  def verify_commit(%Commit{} = commit, public_key) when is_binary(public_key) do
    case :crypto.verify(:eddsa, :none, commit.id, commit.signature, [public_key, :ed25519]) do
      true -> :ok
      false -> {:error, :invalid_signature}
    end
  end

  @doc "Compute a short fingerprint of a public key (first 8 hex chars of SHA256)."
  def fingerprint(public_key) when is_binary(public_key) do
    :crypto.hash(:sha256, public_key)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  @doc "Build a signer_id from identity UUID and public key."
  def signer_id(identity_uuid, public_key) do
    "#{identity_uuid}@#{fingerprint(public_key)}"
  end

  @doc "Parse a signer_id into {identity_uuid, fingerprint}."
  def parse_signer_id(signer_id) when is_binary(signer_id) do
    case String.split(signer_id, "@", parts: 2) do
      [uuid, fp] -> {:ok, uuid, fp}
      _ -> {:error, :invalid_signer_id}
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
