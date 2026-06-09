defmodule Commonplace.Store.LateEditTranslator do
  @moduledoc """
  Late-edit reference translator (CX-yvhs / Build 6.3).

  A *late edit* is an edit a peer authored against an older snapshot
  than the one the receiver now holds — encoded while its document was
  still in a *namespace* (identity space) the receiver has since
  replaced with a newer snapshot. (Namespace vocabulary is owned by
  `Commonplace.Store.Namespace`.) Such an edit's *references* — the ids
  it points at to position its new content relative to existing items —
  name item identities from that older namespace, which no longer exist
  under the receiver's current one. This module is the mechanical step
  that rewrites those references into the current namespace so the edit
  applies instead of failing or silently dropping. It is the low-level
  ref-rewriter that `Commonplace.Store.Translator`'s pipeline delegates
  its translate step to — Translator decides *whether* and *what* to
  translate and runs pre-flight validation; this module just rewrites
  the refs.

  Given a Yjs V1 update binary `E` and an inverse derivation map
  `inverse_dm`, `translate_update/2` produces a new update binary `E'`
  in which every item's reference fields (`origin`, `right_origin`, and
  `{:id, _}` parents) have been rewritten through the lookup table. Each
  item's *own* identity `(clientID, clock)` is preserved unchanged: the
  edit's own items are genuinely new content that should keep its
  identity — only the back-references into prior state are stale.
  Preserving identities is also what makes the translation
  byte-deterministic across peers (see CX-w62).

  The inverse DM has the shape produced by
  `Commonplace.Store.Namespace.inverse_derivation_map/1`:

      %{source_snapshot_hash => %{old_id => new_id}}

  where each `id` is a `{client_id, clock}` tuple. The translator
  flattens the outer-keyed form into a single lookup table — the
  source-hash layer is only load-bearing for pre-flight validation
  (Build 6.4), which asks a different question ("does every ref live
  in *some* known namespace?") than translation ("rewrite this ref if
  the table says so").

  ## Translation rules

  - `nil` origin / right_origin stays `nil` (bare-origin items —
    leftmost or rightmost in a sequence).
  - `{:named, name}` parents stay unchanged (string name, no id).
  - `{:id, id}` parents are translated as a single ref.
  - `{:infer, id}` parents (synthesized by the decoder for items with
    origin/right_origin set) are preserved as-is — the re-encode path
    never writes `:infer` parents to the wire (encoding inherits
    parent from origin at decode time on the receiver).
  - References absent from the flattened table are left untranslated.
    Build 6.4's pre-flight validator is responsible for catching
    refs that should have been present but weren't (origin-missing vs
    origin-tombstoned).

  ## Determinism

  `translate_update/2` must be byte-deterministic: two independent
  callers passing the same `(E, inverse_dm)` must produce identical
  output. The determinism property is covered by the encoder-level
  invariants landed in CX-w62 (client order, struct order, delete-set
  client order) plus the fact that translation preserves every item's
  identity and the store we hand `encode_diff/2` is populated in
  decoded (in-order) sequence per client.
  """

  alias Yelixer.{BlockStore, Doc, Encoding, ID, Item}

  @type ref_tuple :: {non_neg_integer(), non_neg_integer()}
  @type inverse_dm :: %{optional(binary()) => %{optional(ref_tuple()) => ref_tuple()}}

  @spec translate_update(binary(), inverse_dm()) ::
          {:ok, binary()} | {:error, {:malformed_update, String.t()}}
  def translate_update(binary, inverse_dm) when is_binary(binary) and is_map(inverse_dm) do
    case Encoding.decode_update(binary) do
      {:ok, {items, ds, _rest}} ->
        flat = flatten(inverse_dm)
        translated = Enum.map(items, &translate_item(&1, flat))
        {:ok, reencode(translated, ds)}

      {:error, _} = err ->
        err
    end
  end

  # --- Flatten outer-keyed inverse DM into a single lookup ---

  @spec flatten(inverse_dm()) :: %{ref_tuple() => ref_tuple()}
  defp flatten(inverse_dm) do
    Enum.reduce(inverse_dm, %{}, fn {_hash, inner}, acc -> Map.merge(acc, inner) end)
  end

  # --- Per-item translation ---

  defp translate_item(%Item{} = item, flat) do
    %{
      item
      | origin: translate_ref(item.origin, flat),
        right_origin: translate_ref(item.right_origin, flat),
        parent: translate_parent(item.parent, flat)
    }
  end

  defp translate_ref(nil, _flat), do: nil

  defp translate_ref(%ID{client: c, clock: k} = id, flat) do
    case Map.get(flat, {c, k}) do
      nil -> id
      {c2, k2} -> %ID{client: c2, clock: k2}
    end
  end

  defp translate_parent({:named, _} = parent, _flat), do: parent

  defp translate_parent({:id, %ID{} = id}, flat), do: {:id, translate_ref(id, flat)}

  defp translate_parent({:infer, ref}, flat), do: {:infer, translate_ref(ref, flat)}

  defp translate_parent(nil, _flat), do: nil

  # --- Re-encode translated items through the normal encoder ---
  #
  # We build a minimal %Doc{} whose BlockStore holds the translated
  # items in their decoded order per client, then call encode_update/1.
  # The encoder's `encode_diff/2` path:
  #   1. Derives a state-vector from store contents,
  #   2. Filters clients desc by id (determinism — CX-w62),
  #   3. Emits struct runs,
  #   4. Appends encode_delete_set/1 (determinism — CX-w62).
  #
  # The store IS only consulted for GC remapping (`remap_gc_origin/2`
  # and friends). Translated items' origins point at ids from the
  # source namespace — those ids are not in our synthetic store, so
  # the GC-remap lookups miss and return the ref unchanged, which is
  # exactly what we want.
  defp reencode(items, delete_set) do
    doc = build_doc(items, delete_set)
    Encoding.encode_update(doc)
  end

  defp build_doc(items, delete_set) do
    store =
      Enum.reduce(items, BlockStore.new(), fn item, s ->
        BlockStore.push(s, item)
      end)

    # client_id is a local-peer field, not persisted in the wire format;
    # we set it deterministically to 0 because `encode_update/1` never
    # reads it. types is empty — we don't need named-type registration
    # for re-encoding (the type-declaration items themselves carry their
    # names in `parent: {:named, _}`).
    %Doc{
      client_id: 0,
      store: store,
      delete_set: delete_set,
      types: %{}
    }
  end

end
