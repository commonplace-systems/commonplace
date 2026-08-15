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

  @spec prepare_registration(CubDB.t(), binary(), binary()) ::
          {:ok, position(), [tuple()]} | {:error, term()}
  def prepare_registration(db, anchor_id, tombstone_id) do
    case tombstone_position(db, tombstone_id) do
      {:ok, position} ->
        {:ok, position, []}

      :none ->
        with :none <- retirement_position(db, anchor_id) do
          {sequence, activation_rows} = prepare_activation(db, anchor_id)
          registration_sequence = sequence + 1

          {position, registration_rows} =
            event_rows(registration_sequence, :registration, anchor_id, tombstone_id)

          rows =
            activation_rows ++
              registration_rows ++
              [
                {@sequence_key, registration_sequence},
                {{:sla_tombstone_position, tombstone_id}, position}
              ]

          {:ok, position, rows}
        else
          {:ok, retirement} ->
            {:error, {:eviction_anchor_already_retired, anchor_id, retirement}}
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
        {sequence, activation_rows} = prepare_activation(db, anchor_id)
        retirement_sequence = sequence + 1

        {position, retirement_rows} =
          event_rows(retirement_sequence, :retirement, anchor_id, anchor_id)

        rows =
          activation_rows ++
            retirement_rows ++
            [
              {@sequence_key, retirement_sequence},
              {{:eviction_anchor_retirement_position, anchor_id}, position}
            ]

        {:ok, position, rows}
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

  defp prepare_activation(db, anchor_id) do
    case activation_position(db, anchor_id) do
      {:ok, _position} ->
        {current_sequence(db), []}

      :none ->
        sequence = current_sequence(db) + 1
        {position, rows} = event_rows(sequence, :activation, anchor_id, anchor_id)

        {sequence,
         rows ++
           [{{:eviction_anchor_activation_position, anchor_id}, position}]}
    end
  end

  defp event_rows(sequence, kind, anchor_id, subject_id) do
    event = %{sequence: sequence, kind: kind, anchor_id: anchor_id, subject_id: subject_id}

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
