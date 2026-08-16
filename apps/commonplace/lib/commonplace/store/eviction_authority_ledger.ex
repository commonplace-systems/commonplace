defmodule Commonplace.Store.EvictionAuthorityLedger do
  @moduledoc """
  The store-owned ordering domain for eviction authority.

  Anchor activation, tombstone registration, and anchor retirement all append
  to one monotonic sequence. Positions are opaque content hashes; ordering is
  resolved only through the sequence index stored beside each event. Callers
  never choose a position or supply the relation that compares two positions.

  The functions which prepare appends return every ledger row to the
  `CommitStore`; the store lands those rows atomically with the operation's
  index rows in one `CubDB.put_multi/2`.
  """

  @sequence_key :eviction_authority_ledger_sequence

  @type position :: <<_::256>>

  @spec prepare_activation(CubDB.t(), binary(), <<_::256>>) ::
          {:ok, position(), [tuple()]} | {:error, term()}
  def prepare_activation(db, anchor_id, ratification_cid)
      when is_binary(anchor_id) and is_binary(ratification_cid) and
             byte_size(ratification_cid) == 32 do
    case activation(db, anchor_id) do
      {:ok, %{position: position, ratification_cid: ^ratification_cid}} ->
        {:ok, position, []}

      {:ok, %{ratification_cid: existing_ratification_cid}} ->
        {:error, {:eviction_anchor_already_activated, anchor_id, existing_ratification_cid}}

      :none ->
        sequence = current_sequence(db) + 1

        {position, event_rows} =
          event_rows(sequence, :activation, anchor_id, anchor_id, %{
            ratification_cid: ratification_cid
          })

        rows =
          event_rows ++
            [
              {@sequence_key, sequence},
              {{:eviction_anchor_activation_position, anchor_id}, position}
            ]

        {:ok, position, rows}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def prepare_activation(_db, _anchor_id, _ratification_cid),
    do: {:error, :invalid_eviction_anchor_ratification_cid}

  @spec prepare_registration(CubDB.t(), binary(), binary()) ::
          {:ok, position(), [tuple()]} | {:error, term()}
  def prepare_registration(db, anchor_id, tombstone_id) do
    case tombstone_position(db, tombstone_id) do
      {:ok, position} ->
        {:ok, position, []}

      :none ->
        with :none <- retirement_position(db, anchor_id),
             {:ok, _activation} <- require_anchor_activation(db, anchor_id) do
          registration_sequence = current_sequence(db) + 1

          {position, registration_rows} =
            event_rows(registration_sequence, :registration, anchor_id, tombstone_id)

          rows =
            registration_rows ++
              [
                {@sequence_key, registration_sequence},
                {{:sla_tombstone_position, tombstone_id}, position}
              ]

          {:ok, position, rows}
        else
          {:ok, retirement} ->
            {:error, {:eviction_anchor_already_retired, anchor_id, retirement}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec prepare_retirement(CubDB.t(), binary()) ::
          {:ok, position(), [tuple()]} | {:error, term()}
  def prepare_retirement(db, anchor_id) do
    case retirement_position(db, anchor_id) do
      {:ok, position} ->
        {:ok, position, []}

      :none ->
        with {:ok, _activation} <- require_anchor_activation(db, anchor_id) do
          retirement_sequence = current_sequence(db) + 1

          {position, retirement_rows} =
            event_rows(retirement_sequence, :retirement, anchor_id, anchor_id)

          rows =
            retirement_rows ++
              [
                {@sequence_key, retirement_sequence},
                {{:eviction_anchor_retirement_position, anchor_id}, position}
              ]

          {:ok, position, rows}
        end
    end
  end

  @spec activation(CubDB.t(), binary()) :: {:ok, map()} | :none | {:error, term()}
  def activation(db, anchor_id) do
    with {:ok, position} <- activation_position(db, anchor_id),
         sequence when is_integer(sequence) <-
           CubDB.get(db, {:eviction_authority_position_sequence, position}),
         %{kind: :activation, anchor_id: ^anchor_id, position: ^position} = event <-
           CubDB.get(db, {:eviction_authority_event, sequence}),
         ratification_cid when is_binary(ratification_cid) and byte_size(ratification_cid) == 32 <-
           Map.get(event, :ratification_cid) do
      {:ok, event}
    else
      :none -> :none
      _other -> {:error, :invalid_eviction_anchor_activation_state}
    end
  end

  @spec activation_position(CubDB.t(), binary()) :: {:ok, position()} | :none
  def activation_position(db, anchor_id) do
    fetch_position(db, {:eviction_anchor_activation_position, anchor_id})
  end

  @spec retirement_position(CubDB.t(), binary()) :: {:ok, position()} | :none
  def retirement_position(db, anchor_id) do
    fetch_position(db, {:eviction_anchor_retirement_position, anchor_id})
  end

  @spec tombstone_position(CubDB.t(), binary()) :: {:ok, position()} | :none
  def tombstone_position(db, tombstone_id) do
    fetch_position(db, {:sla_tombstone_position, tombstone_id})
  end

  @spec before?(CubDB.t(), position(), position()) ::
          {:ok, boolean()} | {:error, :unknown_eviction_authority_position}
  def before?(db, first, second) when is_binary(first) and is_binary(second) do
    with first_sequence when is_integer(first_sequence) <-
           CubDB.get(db, {:eviction_authority_position_sequence, first}),
         second_sequence when is_integer(second_sequence) <-
           CubDB.get(db, {:eviction_authority_position_sequence, second}) do
      {:ok, first_sequence < second_sequence}
    else
      _ -> {:error, :unknown_eviction_authority_position}
    end
  end

  def before?(_db, _first, _second), do: {:error, :unknown_eviction_authority_position}

  defp require_anchor_activation(db, anchor_id) do
    case activation(db, anchor_id) do
      {:ok, activation} -> {:ok, activation}
      :none -> {:error, {:eviction_anchor_activation_required, anchor_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp event_rows(sequence, kind, anchor_id, subject_id, attributes \\ %{}) do
    event =
      Map.merge(
        %{sequence: sequence, kind: kind, anchor_id: anchor_id, subject_id: subject_id},
        attributes
      )

    position =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({__MODULE__, event}, [:deterministic])
      )

    {position,
     [
       {{:eviction_authority_event, sequence}, Map.put(event, :position, position)},
       {{:eviction_authority_position_sequence, position}, sequence}
     ]}
  end

  defp current_sequence(db), do: CubDB.get(db, @sequence_key) || 0

  defp fetch_position(db, key) do
    case CubDB.get(db, key) do
      nil -> :none
      position -> {:ok, position}
    end
  end
end
