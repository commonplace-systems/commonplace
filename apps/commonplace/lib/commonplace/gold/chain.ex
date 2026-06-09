defmodule Commonplace.Gold.Chain do
  @moduledoc """
  Gold attestation chain management — the storage and verification
  layer over `Commonplace.Gold.Attestation`.

  A *gold attestation* is a signed, content-addressed statement that a
  specific commit was the head of a document at a moment in time
  ("signer X attests commit Y is the head of doc Z at time T").
  Attestations form a per-document, hash-linked, append-only chain that
  lives *separately from the commit DAG*: where the commit DAG records
  what the document's content IS, the gold chain is a tamper-evident
  audit trail of who vouched for which head, and when. ("Gold" is
  Commonplace's name for this signed-provenance tier; the color-channel
  vocabulary is owned by `Commonplace.Dataflow.Channel`.
  `Commonplace.Dataflow.RedLog.commit/1` is one producer — it cuts a
  commit and then best-effort attests it.)

  This module owns the chain as a whole; `Attestation` owns a single
  record (its struct, signing, and per-record verification). Chains are
  stored in `CommitStore`'s CubDB keyed per document — one gold chain
  per document.

  ## Operations

    * `attest/2` — sign the document's current head commit and append
      it to the chain, linking it to the previous attestation via
      `prev_attestation_id`. Requires a signing key from
      `Commonplace.Store.SecretStore`; with no SecretStore or no key it
      returns `{:error, :no_secret_store}` / `{:error, :no_signing_key}`,
      and with no commits to attest yet `{:error, :no_commits}`.
    * `latest_attestation/2` — the newest attestation, or `:none`.
    * `chain/3` — walk the chain newest-first (default `limit: 100`).
    * `verify_chain/3` — verify every attestation, both its content
      address (`Attestation.verify_id/1` — the id is a hash over the
      commit id, previous-attestation id, signer id and timestamp) and
      its Ed25519 signature against the given public key. Returns `:ok`,
      or `{:error, att_id, reason}` at the first attestation that fails.

  The two checks in `verify_chain/3` are complementary: the content
  address makes the chain *tamper-evident* — because each id folds in
  its `prev_attestation_id`, you cannot rewrite or reorder history
  without breaking every id downstream — and the signature makes it
  *unforgeable*, since only the holder of the signing key could have
  produced it.

  ## Store routing (MVP)

  Attestation calls go directly to a local `CommitStore` GenServer.
  `CommitStoreClient` — the stateless routing *module* some onramps
  (e.g. RedLog) pass as the default `store` — is normalized to the
  local `CommitStore` first, because a direct `GenServer.call` to the
  routing module would crash with `:no_process`. Attestation operations
  are not yet routed across nodes; the single-node assumption is
  acceptable for the MVP (followup if multi-node attestation surfaces).
  """

  alias Commonplace.Gold.Attestation
  alias Commonplace.Store.{CommitStore, CommitStoreClient}

  # CommitStoreClient is a stateless routing MODULE, not a registered
  # GenServer process. RedLog passes it as `store` (its default for the
  # onramp), but Gold.Chain's direct GenServer.call(store, ...) crashes
  # with :no_process when store == CommitStoreClient. Normalize to the
  # actual local GenServer for direct calls. (Attestation operations
  # are not yet routed remotely; single-node assumption acceptable for
  # MVP — followup if multi-node attestation surfaces.)
  defp normalize_store(CommitStoreClient), do: CommitStore
  defp normalize_store(other), do: other

  @doc """
  Attest the current head of a document.

  Creates a new attestation, chaining it to the previous one,
  and stores it in CubDB.
  """
  def attest(doc_uuid, store \\ CommitStore) do
    store = normalize_store(store)
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
    GenServer.call(normalize_store(store), {:latest_attestation, doc_uuid})
  end

  @doc "Walk the attestation chain for a document, newest first."
  def chain(doc_uuid, store \\ CommitStore, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    GenServer.call(normalize_store(store), {:attestation_chain, doc_uuid, limit})
  end

  @doc "Verify the entire attestation chain for a document."
  def verify_chain(doc_uuid, public_key, store \\ CommitStore) do
    attestations = chain(doc_uuid, normalize_store(store))

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
