defmodule Commonplace.Gold.Chain do
  @moduledoc """
  Gold attestation chain management.

  Stores attestations in CommitStore's CubDB, keyed per-document.
  Each document can have one gold chain. The chain is append-only.
  """

  alias Commonplace.Gold.Attestation
  alias Commonplace.Store.CommitStore

  @doc """
  Attest the current head of a document.

  Creates a new attestation, chaining it to the previous one,
  and stores it in CubDB.
  """
  def attest(doc_uuid, store \\ CommitStore) do
    # Get the current head commit
    case CommitStore.latest_commit(store, doc_uuid) do
      {:ok, commit} ->
        # Get signing key
        case get_signing_key() do
          {:ok, private_key, signer_id} ->
            # Get the previous attestation
            prev_id =
              case latest_attestation(doc_uuid, store) do
                {:ok, att} -> att.id
                :none -> nil
              end

            att = Attestation.new(doc_uuid, commit.id, prev_id, signer_id, private_key)

            # Store the attestation
            GenServer.call(store, {:store_attestation, doc_uuid, att})

            {:ok, att}

          {:error, reason} ->
            {:error, reason}
        end

      :none ->
        {:error, :no_commits}
    end
  end

  @doc "Get the latest attestation for a document."
  def latest_attestation(doc_uuid, store \\ CommitStore) do
    GenServer.call(store, {:latest_attestation, doc_uuid})
  end

  @doc "Walk the attestation chain for a document, newest first."
  def chain(doc_uuid, store \\ CommitStore, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    GenServer.call(store, {:attestation_chain, doc_uuid, limit})
  end

  @doc "Verify the entire attestation chain for a document."
  def verify_chain(doc_uuid, public_key, store \\ CommitStore) do
    attestations = chain(doc_uuid, store)

    Enum.reduce_while(attestations, :ok, fn att, _acc ->
      with :ok <- Attestation.verify_id(att),
           :ok <- Attestation.verify(att, public_key) do
        {:cont, :ok}
      else
        error -> {:halt, {:error, att.id, error}}
      end
    end)
  end

  defp get_signing_key do
    alias Commonplace.Store.SecretStore
    alias Commonplace.Crypto.Signing

    case Process.whereis(SecretStore) do
      nil ->
        {:error, :no_secret_store}

      _pid ->
        with {:ok, encoded_key} <- SecretStore.get("signing_key:default"),
             {:ok, private_key} <- Base.decode64(encoded_key),
             {:ok, encoded_pub} <- SecretStore.get("signing_pub:default"),
             {:ok, public_key} <- Base.decode64(encoded_pub) do
          identity_uuid =
            case SecretStore.get("signing_identity") do
              {:ok, uuid} -> uuid
              :not_found -> "anonymous"
            end

          signer_id = Signing.signer_id(identity_uuid, public_key)
          {:ok, private_key, signer_id}
        else
          _ -> {:error, :no_signing_key}
        end
    end
  end
end
