defmodule Commonplace.ProtoChit.IntentRecord do
  @moduledoc """
  Signs and verifies proto-chit WAL intent envelopes.

  The signature covers the RFC-8259 JSON value formed by removing the
  top-level `authentication` member and encoding the remainder with object
  keys sorted lexicographically at every depth. This makes verification
  independent of the JSON member order chosen by a writer or reader.

  Signed and unsigned envelopes are deliberately different wire shapes.
  An unsigned envelope is a last-resort durability record, never a weaker
  interpretation of a signed envelope.
  """

  alias Commonplace.Crypto.{Signing, SigningContext}

  @authentication "authentication"
  @unsigned_reason "deployment-signer-unavailable"

  @spec sign(map(), SigningContext.t()) :: {:ok, map()} | {:error, term()}
  def sign(record, %SigningContext{} = context) when is_map(record) do
    record =
      record
      |> Map.delete(@authentication)
      |> put_author_principal(context.identity_uuid)

    signature =
      :crypto.sign(:eddsa, :none, canonical_json(record), [context.private_key, :ed25519])

    authentication = %{
      "state" => "signed",
      "algorithm" => "Ed25519",
      "principal" => context.identity_uuid,
      "key-fingerprint" => Signing.fingerprint(context.public_key),
      "signature" => Base.encode64(signature)
    }

    {:ok, Map.put(record, @authentication, authentication)}
  rescue
    error -> {:error, {:signing_failed, Exception.message(error)}}
  end

  @spec unsigned(map()) :: map()
  def unsigned(record) when is_map(record) do
    Map.put(record, @authentication, %{
      "state" => "unsigned",
      "reason" => @unsigned_reason
    })
  end

  @spec verify(map(), binary()) :: :ok | {:error, term()}
  def verify(%{@authentication => %{"state" => "unsigned"}}, _public_key),
    do: {:error, :unsigned}

  def verify(
        %{
          @authentication => %{
            "state" => "signed",
            "algorithm" => "Ed25519",
            "principal" => principal,
            "key-fingerprint" => fingerprint,
            "signature" => encoded_signature
          }
        } = record,
        public_key
      )
      when is_binary(principal) and is_binary(fingerprint) and is_binary(encoded_signature) and
             is_binary(public_key) do
    with :ok <- verify_fingerprint(fingerprint, public_key),
         :ok <- verify_author_principal(record, principal),
         {:ok, signature} <- decode_signature(encoded_signature) do
      payload = record |> Map.delete(@authentication) |> canonical_json()

      if :crypto.verify(:eddsa, :none, payload, signature, [public_key, :ed25519]) do
        :ok
      else
        {:error, :invalid_signature}
      end
    end
  rescue
    _error -> {:error, :invalid_signature}
  end

  def verify(%{@authentication => %{"state" => "signed"}}, _public_key),
    do: {:error, :malformed_authentication}

  def verify(_record, _public_key), do: {:error, :authentication_missing}

  defp put_author_principal(%{"event" => event} = record, principal) when is_map(event) do
    Map.put(record, "event", Map.put(event, "author-principal", principal))
  end

  defp put_author_principal(record, _principal), do: record

  defp verify_fingerprint(fingerprint, public_key) do
    if fingerprint == Signing.fingerprint(public_key),
      do: :ok,
      else: {:error, :public_key_mismatch}
  end

  defp verify_author_principal(%{"event" => %{"author-principal" => principal}}, principal),
    do: :ok

  defp verify_author_principal(%{"event" => _event}, _principal),
    do: {:error, :principal_mismatch}

  defp verify_author_principal(_record, _principal), do: :ok

  defp decode_signature(encoded_signature) do
    case Base.decode64(encoded_signature) do
      {:ok, signature} when byte_size(signature) == 64 -> {:ok, signature}
      _ -> {:error, :invalid_signature_encoding}
    end
  end

  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(",", fn {key, child} ->
        Jason.encode!(key) <> ":" <> canonical_json(child)
      end)

    "{" <> entries <> "}"
  end

  defp canonical_json(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"
  end

  defp canonical_json(value), do: Jason.encode!(value)
end
