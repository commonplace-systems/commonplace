defmodule Commonplace.Store.LateEditPreflight do
  @moduledoc """
  Pre-flight validator for late-edit translation (CX-0ut2 / Build 6.4).

  Before a late edit `E` — authored against some prior namespace `P` —
  can be applied to a snapshot `S` derived from `P`, every reference
  in `E` that points *outside* `E`'s own items must resolve via the
  inverse derivation map (which maps `P`-namespace ids back to
  equivalent `S`-namespace ids).

  For the MVP, derivation maps carry only *live* items in `S`, so a
  missing entry unambiguously means the target was tombstoned before
  `S` was built. Two sub-cases surface per
  docs/late-edits-and-derivation-map.md § "Missing entries in the
  inverse":

  - `:case_a` — `E` edits an item tombstoned-in-`S` (the missing ref
    is the op's target: a `parent: {:id, _}` link or a `delete_set`
    entry).
  - `:case_b` — `E`'s adjacent-insert origin was tombstoned before
    `S` (the missing ref is an `origin` or `right_origin`).

  On first missing reference, `validate/2` returns
  `{:error, {:untranslatable, :case_a | :case_b, ref_id}}` and
  short-circuits. Because `validate/2` is pure and runs entirely
  *before* any CRDT apply, a failed pre-flight leaves the target
  snapshot unmodified — atomicity is a property of the calling
  protocol (check, then apply), not a transactional rollback.

  `translate_and_validate/2` wraps `validate/2` with the 6.3
  translator, returning `{:ok, translated_binary}` when pre-flight
  passes and the same `:untranslatable` or `:malformed_update` error
  shapes otherwise. It guarantees the translator is only invoked on
  updates that pre-flight has already cleared — no partial output is
  ever returned.

  ## Refs exempt from lookup

  Items whose identity is defined within `E` itself (the new ops `E`
  is introducing) are exempt from DM lookup — they're the subject of
  the update, not references into an existing namespace.
  """

  alias Commonplace.Store.LateEditTranslator
  alias Yelixer.Encoding

  @type id_tuple :: {non_neg_integer(), non_neg_integer()}
  @type inverse_dm :: %{optional(binary()) => %{optional(id_tuple()) => id_tuple()}}
  @type case_tag :: :case_a | :case_b
  @type error :: {:untranslatable, case_tag(), id_tuple()} | {:malformed_update, String.t()}

  @spec validate(binary(), inverse_dm()) :: :ok | {:error, error()}
  def validate(binary, inverse_dm) when is_binary(binary) and is_map(inverse_dm) do
    case Encoding.decode_update(binary) do
      {:ok, {items, ds, _rest}} ->
        do_validate(items, ds, flatten(inverse_dm))

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec translate_and_validate(binary(), inverse_dm()) ::
          {:ok, binary()} | {:error, error()}
  def translate_and_validate(binary, inverse_dm)
      when is_binary(binary) and is_map(inverse_dm) do
    case validate(binary, inverse_dm) do
      :ok -> LateEditTranslator.translate_update(binary, inverse_dm)
      {:error, _} = err -> err
    end
  end

  # --- Core walk ---

  defp do_validate(items, ds, flat_dm) do
    own = collect_own_ids(items)

    with :ok <- validate_items(items, flat_dm, own),
         :ok <- validate_delete_set(ds, flat_dm, own) do
      :ok
    end
  end

  defp collect_own_ids(items) do
    Enum.reduce(items, MapSet.new(), fn it, acc ->
      MapSet.put(acc, {it.id.client, it.id.clock})
    end)
  end

  # --- Items: origin / right_origin / parent:id ---

  defp validate_items(items, flat_dm, own) do
    Enum.reduce_while(items, :ok, fn it, _acc ->
      case check_item(it, flat_dm, own) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp check_item(it, flat_dm, own) do
    with :ok <- check_ref(it.origin, flat_dm, own, :case_b),
         :ok <- check_ref(it.right_origin, flat_dm, own, :case_b),
         :ok <- check_parent(it.parent, flat_dm, own) do
      :ok
    end
  end

  defp check_ref(nil, _flat_dm, _own, _case), do: :ok

  defp check_ref(%{client: c, clock: k}, flat_dm, own, case_tag) do
    key = {c, k}

    cond do
      MapSet.member?(own, key) -> :ok
      Map.has_key?(flat_dm, key) -> :ok
      true -> {:error, {:untranslatable, case_tag, key}}
    end
  end

  defp check_parent({:id, %{client: c, clock: k}}, flat_dm, own) do
    check_ref(%{client: c, clock: k}, flat_dm, own, :case_a)
  end

  defp check_parent(_other, _flat_dm, _own), do: :ok

  # --- Delete set: every clock in every range must resolve ---

  defp validate_delete_set(ds, flat_dm, own) do
    Enum.reduce_while(Map.to_list(ds.clients), :ok, fn {client, ranges}, _acc ->
      case check_ranges(client, ranges, flat_dm, own) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp check_ranges(_client, [], _flat_dm, _own), do: :ok

  defp check_ranges(client, [{start, stop} | rest], flat_dm, own) do
    case check_range_clocks(client, start, stop, flat_dm, own) do
      :ok -> check_ranges(client, rest, flat_dm, own)
      {:error, _} = err -> err
    end
  end

  defp check_range_clocks(_client, clock, stop, _flat_dm, _own) when clock >= stop, do: :ok

  defp check_range_clocks(client, clock, stop, flat_dm, own) do
    key = {client, clock}

    cond do
      MapSet.member?(own, key) ->
        check_range_clocks(client, clock + 1, stop, flat_dm, own)

      Map.has_key?(flat_dm, key) ->
        check_range_clocks(client, clock + 1, stop, flat_dm, own)

      true ->
        {:error, {:untranslatable, :case_a, key}}
    end
  end

  # --- Flatten outer-keyed inverse DM into a single lookup ---

  defp flatten(inverse_dm) do
    Enum.reduce(inverse_dm, %{}, fn {_hash, inner}, acc -> Map.merge(acc, inner) end)
  end
end
