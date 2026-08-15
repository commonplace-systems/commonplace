defmodule Commonplace.Store.SlaTombstone do
  @moduledoc """
  The durable signed receipt for a commit range evicted under a subtree SLA.

  This module defines and signs the format only. It does not delete, demote, or
  move commits.

  ⚠️ **There is no production writer yet, and that is deliberate for this slice
  (S36 evicts nothing) — but it means `Projection`'s `{:evicted_per_sla, …}`
  answer is currently unreachable outside tests.** That gap is owned by
  **CX-0vxt** (storage-SLA slice 1: the first production writer), filed at this
  module's landing so the inertness is temporary by record rather than
  accidental. The precedent it exists to avoid is CX-kaah — Yelixer's
  `Doc.gc/1` is fully built, fully inert, zero production callers, unnoticed
  for months. Delete this paragraph when CX-0vxt lands, not before. `commit_ids` is the exact covered range in oldest-to-newest
  order; `range_start` and `range_end` make its bounds explicit. The receipt
  records the governing SLA, eviction time, and SHA-256 hash of the dropped
  bytes. Its content address covers every field except the signature, and its
  Ed25519 signature covers that address.

  Verification is authorization-bearing: `verify/1` reads the workspace-local
  `Commonplace.Trust` config's distinct `eviction_anchors` list. It never treats
  `trusted_identities` or the local node identity as eviction authority.

  Every stored tombstone has a registration position in the store-owned
  eviction-authority ledger, including tombstones written while their anchor is
  active. Anchor activation, tombstone registration, and anchor retirement use
  that one ordering domain, so verification works across unrelated document
  chains. Verification always re-reads the registration and retirement
  positions and their ordering from the store; none can be supplied in options.

  Revocation is the separate, verify-time CX-bepn rule: a valid
  self-renunciation record targeting the anchor makes it terminally invalid for
  future verifies, including verifies of historical tombstones. Revocations are
  likewise read from the selected store rather than through a per-call fetcher.
  """

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Trust.{EvictionAnchor, Revocation}

  @enforce_keys [
    :id,
    :subtree_id,
    :sla,
    :commit_ids,
    :range_start,
    :range_end,
    :evicted_at,
    :dropped_hash,
    :signer_id,
    :signer_public_key,
    :signature
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: binary(),
          subtree_id: String.t(),
          sla: map(),
          commit_ids: [binary()],
          range_start: binary(),
          range_end: binary(),
          evicted_at: String.t(),
          dropped_hash: binary(),
          signer_id: String.t(),
          signer_public_key: binary(),
          signature: binary()
        }

  @doc "Construct and sign a tombstone receipt without evicting any data."
  @spec new(map(), SigningContext.t()) :: {:ok, t()} | {:error, term()}
  def new(attrs, %SigningContext{} = signing_context) when is_map(attrs) do
    with {:ok, subtree_id} <- non_empty_binary(attrs, :subtree_id),
         {:ok, sla} <- valid_sla(attrs),
         {:ok, commit_ids} <- valid_commit_ids(attrs),
         {:ok, evicted_at} <- valid_timestamp(attrs),
         {:ok, dropped_hash} <- hash_field(attrs, :dropped_hash) do
      signer_id = Signing.signer_id(signing_context.identity_uuid, signing_context.public_key)

      fields = %{
        subtree_id: subtree_id,
        sla: sla,
        commit_ids: commit_ids,
        range_start: List.first(commit_ids),
        range_end: List.last(commit_ids),
        evicted_at: evicted_at,
        dropped_hash: dropped_hash,
        signer_id: signer_id,
        signer_public_key: signing_context.public_key
      }

      id = content_address(fields)
      signature = :crypto.sign(:eddsa, :none, id, [signing_context.private_key, :ed25519])
      {:ok, struct!(__MODULE__, Map.merge(fields, %{id: id, signature: signature}))}
    end
  end

  @doc "Verify against the workspace trust config's distinct eviction-anchor set."
  @spec verify(t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = tombstone) do
    verify(tombstone, Commonplace.Trust.config(), [])
  end

  def verify(_other), do: {:error, :invalid_tombstone_shape}

  @doc "Verify against an explicit trust config."
  @spec verify(t(), map()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = tombstone, cfg) when is_map(cfg) do
    verify(tombstone, cfg, [])
  end

  def verify(%__MODULE__{}, nil), do: {:error, :no_eviction_anchor_configured}
  def verify(%__MODULE__{}, _cfg), do: {:error, :invalid_tombstone_trust_anchors}
  def verify(_other, _cfg), do: {:error, :invalid_tombstone_shape}

  @doc """
  Verify with explicit store context.

  Options:

    * `:store` — the store from which registration, activation, retirement,
      ordering, and revocation evidence is derived.

  No evidence seam survives on this path. In particular,
  `:chain_position`, `:position_before?`, and `:revocation_fetcher` are refused.
  """
  @spec verify(t(), map(), keyword()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = tombstone, cfg, opts) when is_map(cfg) and is_list(opts) do
    store = Keyword.get(opts, :store, CommitStore)

    with :ok <- valid_verification_options(opts),
         {:ok, anchor} <- verified_anchor(tombstone, cfg, store),
         :ok <- valid_at_store_position(anchor, tombstone, store) do
      :ok
    end
  end

  def verify(%__MODULE__{}, _cfg, _opts), do: {:error, :invalid_tombstone_trust_anchors}
  def verify(_other, _cfg, _opts), do: {:error, :invalid_tombstone_shape}

  @doc false
  @spec authorize_registration(t(), map(), GenServer.server()) ::
          {:ok, EvictionAnchor.t()} | {:error, term()}
  def authorize_registration(%__MODULE__{} = tombstone, cfg, store) when is_map(cfg) do
    verified_anchor(tombstone, cfg, store)
  end

  defp validate_shape(tombstone) do
    attrs = Map.from_struct(tombstone)

    with {:ok, _subtree_id} <- non_empty_binary(attrs, :subtree_id),
         {:ok, _sla} <- valid_sla(attrs),
         {:ok, commit_ids} <- valid_commit_ids(attrs),
         true <- tombstone.range_start == List.first(commit_ids),
         true <- tombstone.range_end == List.last(commit_ids),
         {:ok, _evicted_at} <- valid_timestamp(attrs),
         {:ok, _dropped_hash} <- hash_field(attrs, :dropped_hash),
         true <- is_binary(tombstone.id) and byte_size(tombstone.id) == 32,
         true <- is_binary(tombstone.signer_id) and tombstone.signer_id != "",
         true <-
           is_binary(tombstone.signer_public_key) and
             byte_size(tombstone.signer_public_key) == 32,
         true <- is_binary(tombstone.signature) do
      :ok
    else
      false -> {:error, :invalid_tombstone_shape}
      {:error, _reason} = error -> error
    end
  end

  defp verify_id(tombstone) do
    computed = tombstone |> signed_fields() |> content_address()

    if computed == tombstone.id,
      do: :ok,
      else: {:error, {:id_mismatch, computed, tombstone.id}}
  end

  defp eviction_anchors(cfg) do
    case Map.get(cfg, :eviction_anchors, Map.get(cfg, "eviction_anchors")) do
      nil ->
        {:error, :no_eviction_anchor_configured}

      [] ->
        {:error, :no_eviction_anchor_configured}

      entries when is_list(entries) ->
        Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, anchors} ->
          case EvictionAnchor.from_config(entry) do
            {:ok, anchor} -> {:cont, {:ok, [anchor | anchors]}}
            {:error, _reason} -> {:halt, {:error, :invalid_tombstone_trust_anchors}}
          end
        end)

      _other ->
        {:error, :invalid_tombstone_trust_anchors}
    end
  end

  defp trusted_anchor(tombstone, anchors) do
    Enum.find_value(anchors, fn anchor ->
      if tombstone.signer_public_key == anchor.public_key and
           tombstone.signer_id ==
             Signing.signer_id(anchor.identity_uuid, anchor.public_key) do
        {:ok, anchor}
      end
    end) || {:error, {:untrusted_tombstone_signer, tombstone.signer_id}}
  end

  defp verified_anchor(tombstone, cfg, store) do
    with :ok <- validate_shape(tombstone),
         :ok <- verify_id(tombstone),
         {:ok, anchors} <- eviction_anchors(cfg),
         {:ok, anchor} <- trusted_anchor(tombstone, anchors),
         :ok <- not_revoked(anchor, store),
         :ok <- verify_signature(tombstone, anchor.public_key) do
      {:ok, anchor}
    end
  end

  defp valid_verification_options(opts) do
    case Keyword.keys(opts) -- [:store] do
      [] -> :ok
      unsupported -> {:error, {:unsupported_tombstone_verification_options, unsupported}}
    end
  end

  defp not_revoked(anchor, store) do
    case CommitStoreClient.get_revocations(store, anchor.id) do
      revocations when is_list(revocations) ->
        if Enum.any?(revocations, &authorized_revocation?(&1, anchor)) do
          {:error, {:revoked_eviction_anchor, anchor.identity_uuid}}
        else
          :ok
        end

      _other ->
        {:error, :invalid_eviction_anchor_revocation_state}
    end
  end

  defp authorized_revocation?(%Revocation{revoker_pubkey: public_key} = revocation, anchor) do
    public_key == anchor.public_key and Revocation.verify_id(revocation) == :ok and
      Revocation.verify_sig(revocation) == :ok
  end

  defp authorized_revocation?(_revocation, _anchor), do: false

  defp valid_at_store_position(anchor, tombstone, store) do
    with {:ok, activation} <-
           required_position(
             CommitStoreClient.get_eviction_anchor_activation_position(store, anchor.id),
             :eviction_anchor_activation_position_required
           ),
         {:ok, registration} <-
           required_position(
             CommitStoreClient.get_sla_tombstone_position(store, tombstone.id),
             :tombstone_store_position_required
           ),
         :ok <-
           position_before(
             store,
             activation,
             registration,
             {:tombstone_not_after_anchor_activation, activation, registration}
           ) do
      valid_before_retirement(anchor, registration, store)
    end
  end

  defp valid_before_retirement(anchor, registration, store) do
    case CommitStoreClient.get_eviction_anchor_retirement_position(store, anchor.id) do
      :none ->
        :ok

      {:ok, retirement} ->
        position_before(
          store,
          registration,
          retirement,
          {:tombstone_not_before_anchor_retirement, registration, retirement}
        )

      _other ->
        {:error, :invalid_eviction_anchor_retirement_state}
    end
  end

  defp position_before(store, first, second, refusal) do
    case CommitStoreClient.eviction_authority_position_before?(store, first, second) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, refusal}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_eviction_authority_ordering_state}
    end
  end

  defp required_position({:ok, position}, _reason) when is_binary(position), do: {:ok, position}
  defp required_position(_other, reason), do: {:error, reason}

  defp verify_signature(tombstone, trusted_public_key) do
    case :crypto.verify(
           :eddsa,
           :none,
           tombstone.id,
           tombstone.signature,
           [trusted_public_key, :ed25519]
         ) do
      true -> :ok
      false -> {:error, :invalid_signature}
    end
  end

  defp signed_fields(tombstone) do
    Map.take(tombstone, [
      :subtree_id,
      :sla,
      :commit_ids,
      :range_start,
      :range_end,
      :evicted_at,
      :dropped_hash,
      :signer_id,
      :signer_public_key
    ])
  end

  defp content_address(fields) do
    fields
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp valid_sla(attrs) do
    with {:ok, sla} when is_map(sla) <- Map.fetch(attrs, :sla),
         {:ok, tier} <- Map.fetch(sla, :tier),
         true <- tier in ~w(compactable ephemeral),
         {:ok, retention} when is_binary(retention) and retention != "" <-
           Map.fetch(sla, :retention),
         {:ok, note} when is_binary(note) or is_nil(note) <- Map.fetch(sla, :note) do
      {:ok, %{tier: tier, retention: retention, note: note}}
    else
      _ -> {:error, :invalid_sla}
    end
  end

  defp valid_commit_ids(attrs) do
    case Map.fetch(attrs, :commit_ids) do
      {:ok, [_ | _] = ids} ->
        if Enum.all?(ids, &(is_binary(&1) and byte_size(&1) == 32)) and
             length(ids) == MapSet.size(MapSet.new(ids)) do
          {:ok, ids}
        else
          {:error, :invalid_commit_ids}
        end

      _ ->
        {:error, :invalid_commit_ids}
    end
  end

  defp valid_timestamp(attrs) do
    with {:ok, timestamp} when is_binary(timestamp) <- Map.fetch(attrs, :evicted_at),
         {:ok, _datetime, 0} <- DateTime.from_iso8601(timestamp) do
      {:ok, timestamp}
    else
      _ -> {:error, :invalid_evicted_at}
    end
  end

  defp non_empty_binary(attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_field, field}}
    end
  end

  defp hash_field(attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} when is_binary(value) and byte_size(value) == 32 -> {:ok, value}
      _ -> {:error, {:invalid_field, field}}
    end
  end
end
