defmodule Commonplace.Trust.EvictionAnchor do
  @moduledoc """
  The workspace-local declaration of a principal authorized to sign SLA
  tombstones.

  Eviction anchors are deliberately not capability roots and are never folded
  into `Commonplace.Trust`'s `trusted_identities`. An anchor grants exactly one
  meaning: its key may sign an eviction receipt.

  The declaration is append-only. Rotation appends another declaration and
  marks the old declaration with `retired_at`; it does not replace or delete
  the old key. `retired_at` is a commit id, not a timestamp. Its ordering is
  resolved by the commit store when a tombstone is verified.

  `id` excludes `retired_at`, so marking an anchor retired does not change the
  content address targeted by an existing `Commonplace.Trust.Revocation`.
  """

  alias Commonplace.Crypto.Signing

  @enforce_keys [:id, :identity_uuid, :public_key]
  defstruct [:id, :identity_uuid, :public_key, :retired_at]

  @type t :: %__MODULE__{
          id: binary(),
          identity_uuid: String.t(),
          public_key: binary(),
          retired_at: binary() | nil
        }

  @doc "Build an active anchor declaration from an identity and Ed25519 public key."
  @spec new(String.t(), binary()) :: {:ok, t()} | {:error, term()}
  def new(identity_uuid, public_key)
      when is_binary(identity_uuid) and identity_uuid != "" and is_binary(public_key) and
             byte_size(public_key) == 32 do
    {:ok,
     %__MODULE__{
       id: id(identity_uuid, public_key),
       identity_uuid: identity_uuid,
       public_key: public_key,
       retired_at: nil
     }}
  end

  def new(_identity_uuid, _public_key), do: {:error, :invalid_eviction_anchor}

  @doc "The stable content address used as the target of revocation records."
  @spec id(String.t(), binary()) :: binary()
  def id(identity_uuid, public_key) when is_binary(identity_uuid) and is_binary(public_key) do
    :crypto.hash(:sha256, :erlang.term_to_binary({identity_uuid, public_key}, [:deterministic]))
  end

  @doc "Decode one normalized trust-config entry."
  @spec from_config(map()) :: {:ok, t()} | {:error, term()}
  def from_config(entry) when is_map(entry) do
    with identity_uuid when is_binary(identity_uuid) and identity_uuid != "" <-
           fetch(entry, :identity_uuid),
         encoded when is_binary(encoded) <- fetch(entry, :public_key),
         {:ok, public_key} <- Signing.decode_key(encoded),
         true <- byte_size(public_key) == 32,
         {:ok, anchor} <- new(identity_uuid, public_key),
         {:ok, retired_at} <- decode_position(fetch(entry, :retired_at)) do
      {:ok, %{anchor | retired_at: retired_at}}
    else
      _ -> {:error, :invalid_eviction_anchor}
    end
  end

  def from_config(_entry), do: {:error, :invalid_eviction_anchor}

  @doc "Encode an anchor for the JSON-shaped trust config."
  @spec to_config(t()) :: map()
  def to_config(%__MODULE__{} = anchor) do
    %{
      identity_uuid: anchor.identity_uuid,
      public_key: Signing.encode_key(anchor.public_key),
      retired_at: encode_position(anchor.retired_at)
    }
  end

  @doc "Append an anchor, refusing an attempt to replace an existing declaration."
  @spec append([map()], t()) :: {:ok, [map()]} | {:error, term()}
  def append(entries, %__MODULE__{} = anchor) when is_list(entries) do
    decoded = Enum.map(entries, &from_config/1)

    cond do
      Enum.any?(decoded, &match?({:error, _}, &1)) ->
        {:error, :invalid_eviction_anchor_config}

      Enum.any?(decoded, fn {:ok, existing} -> existing.id == anchor.id end) ->
        {:error, :eviction_anchor_already_exists}

      true ->
        {:ok, entries ++ [to_config(anchor)]}
    end
  end

  def append(_entries, %__MODULE__{}), do: {:error, :invalid_eviction_anchor_config}

  @doc "Mark one declaration retired without removing or replacing any entry."
  @spec retire([map()], binary(), binary()) :: {:ok, [map()]} | {:error, term()}
  def retire(entries, anchor_id, chain_position)
      when is_list(entries) and is_binary(anchor_id) and is_binary(chain_position) do
    with {:ok, anchors} <- decode_all(entries),
         {:ok, target} <- fetch_anchor(anchors, anchor_id),
         :ok <- ensure_active(target) do
      updated =
        Enum.map(anchors, fn
          %{id: ^anchor_id} = anchor -> %{anchor | retired_at: chain_position} |> to_config()
          anchor -> to_config(anchor)
        end)

      {:ok, updated}
    end
  end

  def retire(_entries, _anchor_id, _chain_position),
    do: {:error, :invalid_eviction_anchor_retirement}

  defp decode_all(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, anchors} ->
      case from_config(entry) do
        {:ok, anchor} -> {:cont, {:ok, [anchor | anchors]}}
        {:error, _reason} -> {:halt, {:error, :invalid_eviction_anchor_config}}
      end
    end)
    |> case do
      {:ok, anchors} -> {:ok, Enum.reverse(anchors)}
      error -> error
    end
  end

  defp fetch_anchor(anchors, anchor_id) do
    case Enum.find(anchors, &(&1.id == anchor_id)) do
      nil -> {:error, :eviction_anchor_not_found}
      anchor -> {:ok, anchor}
    end
  end

  defp ensure_active(%__MODULE__{retired_at: nil}), do: :ok
  defp ensure_active(%__MODULE__{}), do: {:error, :eviction_anchor_already_retired}

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp decode_position(nil), do: {:ok, nil}

  defp decode_position(encoded) when is_binary(encoded) do
    case Base.decode16(encoded, case: :mixed) do
      {:ok, position} when byte_size(position) == 32 -> {:ok, position}
      _ -> {:error, :invalid_chain_position}
    end
  end

  defp decode_position(_position), do: {:error, :invalid_chain_position}

  defp encode_position(nil), do: nil
  defp encode_position(position), do: Base.encode16(position, case: :lower)
end
