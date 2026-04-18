defmodule Commonplace.Store.Translator do
  @moduledoc """
  End-to-end late-edit translation entry point (CX-fefz / Build 6.5).

  Composes the three sub-beads that make up the late-edit translation
  pipeline:

  - 6.2 `Commonplace.Store.Namespace.inverse_derivation_map/1` —
    inverts the target snapshot's forward derivation map so refs in
    the edit's source namespace can be rewritten to the target
    snapshot's namespace.
  - 6.3 `Commonplace.Store.LateEditTranslator.translate_update/2` —
    rewrites each item's `origin`, `right_origin`, and `{:id, _}`
    parent refs through the inverse DM, preserving every item's own
    identity.
  - 6.4 `Commonplace.Store.LateEditPreflight.translate_and_validate/2` —
    walks every ref before any translation output, short-circuiting
    atomically on the first missing entry.

  Returns `{:ok, translated_commit}` on success — a new
  `Commonplace.Store.Commit` struct whose `update` is the translated
  bytes, `parent_id` is the target snapshot's id, and metadata carries
  `%{kind: :regular, snapshot_parent: target_snapshot.id}`. The struct
  is returned in memory; callers persist via `CommitStore.import_commit/2`.

  Byte-determinism: because the translator preserves every item's
  identity and the content-address excludes timestamp, two independent
  peers translating the same `(edit, target_snapshot)` produce
  byte-identical translated commits (identical `id`, `update`,
  `metadata`, `parent_id`). The store's content-addressing then
  collapses them into a single stored entry.

  ## Red events

  All outcomes emit a telemetry event under the `[:commonplace,
  :late_edit, ...]` prefix (sibling to CX-ch5's
  `[:commonplace, :commit, :rejected, :namespace_mismatch]`):

  - `[:commonplace, :late_edit, :translated]` on success, with
    metadata `%{edit_hash, target_snapshot, commit_id}`.
  - `[:commonplace, :late_edit, :untranslatable]` on pre-flight
    failure, with metadata `%{edit_hash, target_snapshot, reason:
    :case_a | :case_b, ref_id}`. `ref_id` is the specific
    `{client_id, clock}` that failed lookup — the actionable detail
    for audit/debug.

  Does NOT dispatch to positional-rebase fallback — that's scoped to
  Build 6.6 (`fallback_to_positional: true` via `opts`).
  """

  alias Commonplace.Store.{Commit, CommitStore, LateEditPreflight, Namespace}
  alias Yelixer.Encoding

  @type edit :: Commit.t()
  @type translated :: Commit.t()

  @doc """
  Translate a late edit against a target snapshot identified by its
  commit id. Fetches the snapshot from `store` and delegates to
  `translate_edit_with_snapshot/3`.
  """
  @spec translate_edit(GenServer.server(), edit(), binary(), keyword()) ::
          {:ok, translated()} | {:error, term()}
  def translate_edit(store, %Commit{} = edit, target_snapshot_id, opts \\ [])
      when is_binary(target_snapshot_id) do
    case CommitStore.get_commit(store, target_snapshot_id) do
      {:ok, snapshot} ->
        translate_edit_with_snapshot(edit, snapshot, opts)

      :not_found ->
        {:error, {:target_snapshot_not_found, target_snapshot_id}}
    end
  end

  @doc """
  Translate a late edit against an already-resolved target snapshot
  commit. Exposed separately so callers that have fetched the snapshot
  (or need to pass a synthetic/corrupted snapshot in tests) can avoid
  a redundant store lookup.
  """
  @spec translate_edit_with_snapshot(edit(), Commit.t(), keyword()) ::
          {:ok, translated()} | {:error, term()}
  def translate_edit_with_snapshot(%Commit{} = edit, %Commit{} = snapshot, _opts \\ []) do
    inverse_dm = build_inverse_dm(snapshot)

    case LateEditPreflight.translate_and_validate(edit.update, inverse_dm) do
      {:ok, translated_update} ->
        translated =
          Commit.new(
            edit.doc_uuid,
            translated_update,
            snapshot.id,
            %{kind: :regular, snapshot_parent: snapshot.id}
          )

        emit_translated(edit, snapshot, translated)
        {:ok, translated}

      {:error, {:untranslatable, reason, ref_id}} = err ->
        emit_untranslatable(edit, snapshot, reason, ref_id)
        err

      {:error, _other} = err ->
        err
    end
  end

  # --- Internals ---

  # Expand a snapshot's derivation map per sub-clock before inverting.
  #
  # The snapshotter (CX-6sc) pairs item START clocks: for an item with
  # id `{client, clock}` and length L > 1, the DM carries only the
  # leading pair `{new_start, old_start}`. But Yjs references can point
  # anywhere in the `[clock, clock+L)` span (cursor positions inside a
  # multi-char insert), and both the pre-flight (6.4) and translator
  # (6.3) do exact-clock lookups. Without expansion, any ref into the
  # middle of a consolidated item fails as spurious :case_b.
  #
  # Expansion by the snapshot's own item lengths is safe whenever source
  # and new items align one-to-one at the given pair position (the MVP
  # snapshotter consolidates same-client runs but does NOT split items
  # or re-interleave clients within an item, so the span-for-span
  # correspondence holds at the item granularity pair_ids produces).
  defp build_inverse_dm(%Commit{metadata: %{derivation_map: dm}} = snapshot) when is_map(dm) do
    lengths = item_lengths_from_update(snapshot.update)

    dm
    |> expand_per_sub_clock(lengths)
    |> Namespace.inverse_derivation_map()
  end

  defp build_inverse_dm(_snapshot), do: %{}

  defp item_lengths_from_update(update) when is_binary(update) do
    case Encoding.decode_update(update) do
      {:ok, {items, _ds, _rest}} ->
        Map.new(items, fn it -> {{it.id.client, it.id.clock}, it.length} end)

      _ ->
        %{}
    end
  end

  defp item_lengths_from_update(_), do: %{}

  defp expand_per_sub_clock(dm, lengths) do
    Map.new(dm, fn {hash, inner} -> {hash, expand_inner(inner, lengths)} end)
  end

  defp expand_inner(inner, lengths) do
    Enum.reduce(inner, %{}, fn {{nc, nk}, {oc, ok}}, acc ->
      length = Map.get(lengths, {nc, nk}, 1)

      Enum.reduce(0..(max(length, 1) - 1), acc, fn offset, acc2 ->
        Map.put(acc2, {nc, nk + offset}, {oc, ok + offset})
      end)
    end)
  end

  defp emit_translated(edit, snapshot, translated) do
    :telemetry.execute(
      [:commonplace, :late_edit, :translated],
      %{system_time: System.system_time()},
      %{
        edit_hash: edit.id,
        target_snapshot: snapshot.id,
        commit_id: translated.id
      }
    )
  end

  defp emit_untranslatable(edit, snapshot, reason, ref_id) do
    :telemetry.execute(
      [:commonplace, :late_edit, :untranslatable],
      %{system_time: System.system_time()},
      %{
        edit_hash: edit.id,
        target_snapshot: snapshot.id,
        reason: reason,
        ref_id: ref_id
      }
    )
  end
end
