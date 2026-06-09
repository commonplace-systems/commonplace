defmodule Commonplace.Materialize do
  @moduledoc """
  CX-t7te (sub-bead i of CX-q15o M2): substrate-tier materialize primitive.

  Takes a list of decoded JSON entries + a rules config and produces
  the materialized output — one entry per "original" (an entry not
  itself a child in any declared chain), with chain semantics applied.

  Substrate-agnostic: no chat-specific knowledge. Chat (and any future
  view-shape with edit/delete-style chains) consumes this primitive
  with its own rule config.

  ## The chain model

  A *chain field* (like `"edit_of"`) set on an entry points back at the
  entry it modifies — its parent. Following those pointers from any
  entry walks toward an *original*: an entry that sets *none* of the
  declared chain fields (the root of its chain). Every materialized
  output corresponds to exactly one original. Among the links that
  resolve back to a given original, the *chain tip* is the most recent
  one *by array position* — input order is treated as chronological, so
  "latest" means "last in the entry list", not "end of the pointer
  walk". An entry whose pointers never terminate at a known original is
  an *orphan* (see Orphan filtering).

  ## Rules config shape

      %{
        chains: [
          %{field: "edit_of",      semantics: :latest_replaces},
          %{field: "tombstone_of", semantics: :marks_deleted}
        ]
      }

  Two enumerated chain semantics:

  * `:latest_replaces` — each entry whose `<field>` points at another
    entry forms a chain. The chain tip's *non-pointer* fields — every
    field except the chain `<field>` itself and the link's own `"id"` —
    override the original entry's fields. Always adds an `"edited?"`
    boolean (`false` when the original has no links) plus `"edited_at"`
    (the chain tip's `"ts"`, if present).
  * `:marks_deleted` — any entry whose `<field>` chain ultimately
    points at a given original marks that original as deleted. Always
    adds a `"deleted?"` boolean (`false` when nothing deletes the
    original).

  Multiple chain rules can be declared; they're processed independently
  per original. An entry can be a chain link in one chain and absent
  from another.

  ## Output shape

  The base of each output is the original entry itself — all its own
  fields pass through — and each declared rule layers its effect on
  top, applied in the order the rules are declared (so a later rule's
  override wins on any field two rules both touch):

      %{
        "id" => <original's id>,
        ...all the original's own fields,
        ...overridden by chain tip's non-pointer fields if :latest_replaces,
        "deleted?" => bool (added if any :marks_deleted chains in rules),
        "edited?" => bool (added if any :latest_replaces chains in rules),
        "edited_at" => <chain tip's ts, if present and edited>
      }

  ## Cycle safety

  Chain resolution uses a `MapSet` seen-set to prevent infinite loops
  on self-referencing or mutually-referencing entries. Cyclic chains
  are treated as orphans (their root never terminates at a known
  original) and filtered from output.

  ## Orphan filtering

  Chain links whose chain ultimately points at an unknown id are
  filtered from the output. This prevents an actor that wrote a
  malformed `<field>: "ghost"` entry from polluting unrelated
  originals' materialized state.
  """

  @doc """
  Materialize entries against the given rules. See module docs.
  """
  def materialize(entries, %{chains: chain_rules}) when is_list(entries) and is_list(chain_rules) do
    chain_field_set = chain_rules |> Enum.map(& &1.field) |> MapSet.new()
    indexed = Enum.with_index(entries)
    by_id = Map.new(indexed, fn {entry, idx} -> {entry["id"], {entry, idx}} end)

    # For each entry, walk its chain (if any) to find its root original.
    # Roots reach back to an entry that is itself original (no chain
    # field pointing anywhere). Entries whose chain doesn't terminate
    # at a known original are orphans (filtered).
    roots =
      Enum.reduce(indexed, %{}, fn {entry, _idx}, acc ->
        case resolve_root(entry, by_id, chain_field_set, MapSet.new()) do
          {:ok, root_id} -> Map.put(acc, entry["id"], root_id)
          :orphan -> acc
        end
      end)

    # Group every entry by its resolved root id (originals appear in
    # their own group keyed by their own id).
    grouped =
      Enum.reduce(indexed, %{}, fn {entry, idx}, acc ->
        case Map.get(roots, entry["id"]) do
          nil -> acc
          root_id -> Map.update(acc, root_id, [{entry, idx}], &[{entry, idx} | &1])
        end
      end)

    # Emit one materialized output per ORIGINAL (entry with no chain
    # field), in original-array-position order.
    indexed
    |> Enum.filter(fn {entry, _} -> original?(entry, chain_field_set) end)
    |> Enum.map(fn {original, _idx} ->
      chain_entries =
        Map.get(grouped, original["id"], [])
        |> Enum.sort_by(fn {_, idx} -> idx end)

      apply_chain_semantics(original, chain_entries, chain_rules)
    end)
  end

  # --- Private ---

  defp original?(entry, chain_field_set) do
    Enum.all?(chain_field_set, fn field -> not Map.has_key?(entry, field) end)
  end

  defp resolve_root(entry, by_id, chain_field_set, seen) do
    cond do
      MapSet.member?(seen, entry["id"]) ->
        # Cycle — treat as orphan to avoid infinite loop.
        :orphan

      original?(entry, chain_field_set) ->
        if Map.has_key?(by_id, entry["id"]),
          do: {:ok, entry["id"]},
          else: :orphan

      true ->
        # Find the chain field this entry uses + walk to its parent.
        target_id =
          chain_field_set
          |> Enum.find_value(fn field -> Map.get(entry, field) end)

        case Map.get(by_id, target_id) do
          {parent, _idx} ->
            resolve_root(parent, by_id, chain_field_set, MapSet.put(seen, entry["id"]))

          nil ->
            :orphan
        end
    end
  end

  # Apply each chain rule's semantics to produce the final materialized
  # output for this original.
  defp apply_chain_semantics(original, chain_entries, chain_rules) do
    Enum.reduce(chain_rules, original, fn rule, acc ->
      apply_rule(rule, acc, chain_entries)
    end)
  end

  defp apply_rule(%{field: field, semantics: :latest_replaces}, acc, chain_entries) do
    matches =
      chain_entries
      |> Enum.filter(fn {e, _} -> Map.has_key?(e, field) end)

    case matches do
      [] ->
        Map.put(acc, "edited?", false)

      _ ->
        {tip_entry, _idx} = Enum.max_by(matches, fn {_, idx} -> idx end)

        # Tip's non-pointer fields override original's (excludes the
        # chain pointer itself + the tip's own id, which is just the
        # link's id, not the original's).
        tip_overrides =
          tip_entry
          |> Map.drop(["id", field])

        acc
        |> Map.merge(tip_overrides)
        # Restore the original's id (Map.merge above would have dropped
        # it via Map.drop; but defensive in case future shape changes).
        |> Map.put("id", original_id(acc))
        |> Map.put("edited?", true)
        |> maybe_put_edited_at(tip_entry)
    end
  end

  defp apply_rule(%{field: field, semantics: :marks_deleted}, acc, chain_entries) do
    has_match? =
      Enum.any?(chain_entries, fn {e, _} -> Map.has_key?(e, field) end)

    Map.put(acc, "deleted?", has_match?)
  end

  defp original_id(%{"id" => id}), do: id

  defp maybe_put_edited_at(acc, tip_entry) do
    case Map.get(tip_entry, "ts") do
      nil -> acc
      ts -> Map.put(acc, "edited_at", ts)
    end
  end
end
