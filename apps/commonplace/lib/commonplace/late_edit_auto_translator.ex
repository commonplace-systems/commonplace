defmodule Commonplace.LateEditAutoTranslator do
  @moduledoc """
  Auto-translation hook for incoming cross-epoch edits (CX-atk3).

  `maybe_auto_translate/3` is the wiring primitive Build 6's late-edit
  translator needs so the sync path can auto-recover when a peer ships
  an edit written against an older snapshot than the one the receiver
  now holds.

  ## Behavior

  - If the edit's `snapshot_parent` already matches local HEAD's
    current namespace, returns `{:ok, :no_translation_needed}` — the
    edit is already aligned and can be imported as-is.
  - If the local store has no head for `edit.doc_uuid`, returns
    `{:ok, :no_translation_needed}` — nothing to translate against.
  - Otherwise invokes
    `Commonplace.Store.Translator.translate_edit/4` against local
    HEAD's namespace. Success emits
    `[:commonplace, :late_edit, :auto_translated]` and returns
    `{:ok, :translated, translated_commit}`.
  - On primary translation error with `fallback: true` (the default,
    per sync-agent policy — cross-epoch peers should auto-recover),
    retries via
    `Commonplace.Store.Translator.translate_edit_with_snapshot/3`
    with a `pre_doc` reconstructed from the edit's source snapshot.
    Success emits `[:commonplace, :late_edit, :auto_fallback]` and
    returns `{:ok, :fallback, translated_commit}`.
  - With `fallback: false`, or when the fallback path also fails,
    emits `[:commonplace, :late_edit, :auto_skipped]` and returns
    `{:ok, :skipped, reason}` so the divergence is visible to
    observers.

  The returned commit is NOT persisted — the caller (NodeSync, import
  wrapper, CLI merge) decides whether to import or discard. Keeping
  the primitive free of side-effects matches the CX-4e2g / CX-4qn1
  pattern: race-safe, idempotent primitive; hooks and wiring live on
  top.
  """

  alias Commonplace.Store.{Commit, CommitStore, Namespace, Translator}
  alias Yelixer.{Doc, Encoding}

  @type result ::
          {:ok, :no_translation_needed}
          | {:ok, :translated, Commit.t()}
          | {:ok, :fallback, Commit.t()}
          | {:ok, :skipped, term()}

  @spec maybe_auto_translate(GenServer.server(), Commit.t(), keyword()) :: result()
  def maybe_auto_translate(store, %Commit{} = edit, opts \\ []) do
    fallback? = Keyword.get(opts, :fallback, true)

    case CommitStore.latest_commit(store, edit.doc_uuid) do
      :none ->
        {:ok, :no_translation_needed}

      {:ok, local_head} ->
        target_ns_id = Namespace.current_namespace(local_head)
        edit_ns_id = Map.get(edit.metadata, :snapshot_parent)

        cond do
          target_ns_id != nil and target_ns_id == edit_ns_id ->
            {:ok, :no_translation_needed}

          target_ns_id == nil ->
            {:ok, :no_translation_needed}

          true ->
            translate(store, edit, target_ns_id, fallback?)
        end
    end
  end

  defp translate(store, edit, target_ns_id, fallback?) do
    case Translator.translate_edit(store, edit, target_ns_id) do
      {:ok, translated} ->
        emit(:auto_translated, edit, target_ns_id, %{commit_id: translated.id})
        {:ok, :translated, translated}

      {:error, reason} ->
        if fallback? do
          try_fallback(store, edit, target_ns_id, reason)
        else
          emit(:auto_skipped, edit, target_ns_id, %{reason: reason})
          {:ok, :skipped, reason}
        end
    end
  end

  defp try_fallback(store, edit, target_ns_id, primary_reason) do
    with {:ok, target_snapshot} <- fetch_commit(store, target_ns_id),
         {:ok, pre_doc} <- build_pre_doc(store, edit),
         {:ok, translated} <-
           Translator.translate_edit_with_snapshot(edit, target_snapshot,
             fallback_to_positional: true,
             pre_doc: pre_doc
           ) do
      emit(:auto_fallback, edit, target_ns_id, %{commit_id: translated.id})
      {:ok, :fallback, translated}
    else
      _ ->
        emit(:auto_skipped, edit, target_ns_id, %{reason: primary_reason})
        {:ok, :skipped, primary_reason}
    end
  end

  defp fetch_commit(store, id) do
    case CommitStore.get_commit(store, id) do
      {:ok, commit} -> {:ok, commit}
      _ -> {:error, :not_found}
    end
  end

  defp build_pre_doc(store, %Commit{metadata: %{snapshot_parent: src_id}})
       when is_binary(src_id) do
    case CommitStore.get_commit(store, src_id) do
      {:ok, %Commit{update: update}} when byte_size(update) > 0 ->
        Encoding.apply_update(Doc.new(), update)

      {:ok, _} ->
        {:ok, Doc.new()}

      _ ->
        {:error, :source_snapshot_not_found}
    end
  end

  defp build_pre_doc(_store, _edit), do: {:error, :no_snapshot_parent}

  defp emit(event, edit, target_ns_id, extra) do
    meta = Map.merge(%{edit_hash: edit.id, target_snapshot: target_ns_id}, extra)

    :telemetry.execute(
      [:commonplace, :late_edit, event],
      %{system_time: System.system_time()},
      meta
    )
  end
end
