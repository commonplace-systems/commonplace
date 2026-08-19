defmodule Commonplace.Gold.Attestation do
  @moduledoc """
  A signed attestation that a specific commit is the head of a document.

  Gold attestations form their own hash-linked chain per document,
  separate from the commit DAG. Each attestation asserts: "I, signer X,
  attest that commit Y is the head of document Z at time T."

  The chain is append-only and tamper-evident — each attestation
  references the previous one, forming a verifiable audit trail.
  """

  defstruct [
    :id,
    :doc_uuid,
    :commit_id,
    :prev_attestation_id,
    :signer_id,
    :timestamp,
    :signature
  ]

  @type t :: %__MODULE__{
          id: binary(),
          doc_uuid: String.t(),
          commit_id: binary(),
          prev_attestation_id: binary() | nil,
          signer_id: String.t(),
          timestamp: DateTime.t(),
          signature: binary()
        }

  @doc "Create and sign a new attestation."
  def new(doc_uuid, commit_id, prev_attestation_id, signer_id, private_key) do
    timestamp = DateTime.utc_now()
    timestamp_str = DateTime.to_iso8601(timestamp)

    id = content_address(commit_id, prev_attestation_id, signer_id, timestamp_str)
    signature = :crypto.sign(:eddsa, :none, id, [private_key, :ed25519])

    %__MODULE__{
      id: id,
      doc_uuid: doc_uuid,
      commit_id: commit_id,
      prev_attestation_id: prev_attestation_id,
      signer_id: signer_id,
      timestamp: timestamp,
      signature: signature
    }
  end

  @doc "Verify an attestation's signature against a public key."
  def verify(%__MODULE__{} = att, public_key) when is_binary(public_key) do
    case :crypto.verify(:eddsa, :none, att.id, att.signature, [public_key, :ed25519]) do
      true -> :ok
      false -> {:error, :invalid_signature}
    end
  end

  @doc "Verify the attestation's content address (id matches content)."
  def verify_id(%__MODULE__{} = att) do
    timestamp_str = DateTime.to_iso8601(att.timestamp)

    expected =
      content_address(att.commit_id, att.prev_attestation_id, att.signer_id, timestamp_str)

    if expected == att.id do
      :ok
    else
      {:error, :id_mismatch}
    end
  end

  defp content_address(commit_id, prev_attestation_id, signer_id, timestamp_str) do
    data =
      (commit_id || <<>>) <>
        (prev_attestation_id || <<>>) <>
        signer_id <>
        timestamp_str

    :crypto.hash(:sha256, data)
  end
end
