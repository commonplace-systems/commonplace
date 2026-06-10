defmodule Commonplace.Store.Translator do
  @moduledoc """
  Entry point for translating a **late edit** onto a snapshot
  (CX-fefz / Build 6.5).

  A *late edit* is a commit authored against a prior namespace — call it
  `P` — that arrives after a snapshot — call it `S` — has already
  **re-identified** `P`'s items into a fresh namespace of its own.
  (`P` is the namespace the edit was written in; `S` is the snapshot
  commit it must be moved onto, and `S`'s re-identified ids form the
  target namespace.) The edit's refs (`origin`, `right_origin`,
  `{:id, _}` parents, delete-set targets) still name the `P`-namespace
  ids that `S` renamed, so the edit cannot be applied as-is: every such
  ref must be rewritten from its `P`-id to the equivalent id in `S`'s
  namespace. This module performs that rewrite and returns a commit that
  lands cleanly on `S`.

  Re-identification and the derivation maps (DMs) that record it are
  `Commonplace.Store.Namespace`'s domain — see its "derivation-map
  algebra" section. This module is that algebra's primary consumer.

  ## The pipeline

  `translate_edit/4` composes three Build-6 sub-steps:

    1. **Invert the DM** (6.2) — `Namespace.inverse_derivation_map/1`
       turns `S`'s forward DM (`new_id => old_id`) into the
       `old_id => new_id` lookup used to rewrite a `P`-ref to its
       `S`-ref. (`build_inverse_dm/1` first expands the per-item DM
       across each item's sub-clocks, so a ref into the middle of a
       consolidated insert still resolves; that function documents the
       why.)
    2. **Pre-flight** (6.4) —
       `LateEditPreflight.translate_and_validate/2` walks *every* ref
       before emitting any output, making translation all-or-nothing.
    3. **Translate** (6.3) — `LateEditTranslator` rewrites each ref
       through the inverse DM, preserving every item's own identity.

  On success, returns `{:ok, translated_commit}` — a fresh
  `Commonplace.Store.Commit` whose `update` is the rewritten bytes,
  `parent_id` is `S`'s id, and metadata is
  `%{kind: :regular, snapshot_parent: S.id}`. The struct is returned
  in memory; callers persist it via `CommitStore.import_commit/2`.

  ## When translation fails: case_a / case_b

  A ref is *untranslatable* when its target is absent from the inverse
  DM. In the MVP — where the DM carries only items still live in `S` —
  that absence means the target was **tombstoned before `S` was built**.
  Two sub-cases (owned by `LateEditPreflight`):

    - `:case_a` — the edit's *op target* is gone: a `{:id, _}` parent
      link or a delete-set entry points at an item `S` no longer has.
    - `:case_b` — the edit's *insert anchor* is gone: an `origin` or
      `right_origin` of an adjacent insert was tombstoned before `S`.

  Pre-flight short-circuits on the first such ref, emits
  `[:commonplace, :late_edit, :untranslatable]`, and returns
  `{:error, {:untranslatable, reason, ref_id}}` — `ref_id` is the
  exact `{client_id, clock}` that missed.

  ## Byte-determinism

  The primary path preserves every item's identity, and the
  content-address excludes `timestamp` (see `Commonplace.Store.Commit`).
  Two independent peers translating the same `(edit, S)` therefore
  produce byte-identical commits — same `id`, `update`, `metadata`,
  `parent_id` — and the store's content-addressing collapses them to one
  entry. The positional-rebase fallback is the one path that breaks this.

  ## Red events (audit telemetry)

  All outcomes emit a `:telemetry` event under the `[:commonplace,
  :late_edit, ...]` prefix — the "red" / audit-channel family (sibling
  to CX-ch5's
  `[:commonplace, :commit, :rejected, :namespace_mismatch]`):

  - `[:commonplace, :late_edit, :translated]` on success, with
    metadata `%{edit_hash, target_snapshot, commit_id}`.
  - `[:commonplace, :late_edit, :untranslatable]` on pre-flight
    failure, with metadata `%{edit_hash, target_snapshot, reason:
    :case_a | :case_b, ref_id}`. `ref_id` is the specific
    `{client_id, clock}` that failed lookup — the actionable detail
    for audit/debug.
  - `[:commonplace, :late_edit, :fallback]` when Build 6.6's
    positional-rebase fallback resolves an otherwise untranslatable
    edit, with metadata `%{edit_hash, target_snapshot, reason, ref_id,
    commit_id}`.

  ## Positional-rebase fallback (CX-7sln / Build 6.6)

  Callers may pass `fallback_to_positional: true` along with
  `pre_doc: %Yelixer.Doc{}` (a reconstruction of the edit's source
  namespace state). When set, pre-flight failures dispatch to
  `Commonplace.Document.Rebase.rebase/3` (CX-6a7) to re-author the
  edit as native-coordinate ops on the target snapshot. The result is a
  valid commit under the local peer's client id — at the cost of
  byte-determinism across peers. The default is `false`, matching
  6.5's fail-loud behavior.

  ## What this module is NOT

  - **Not the derivation-map algebra.** It consumes
    `Commonplace.Store.Namespace`'s inverse/compose maps; beyond the
    sub-clock expansion in `build_inverse_dm/1` it neither builds nor
    inverts them itself.
  - **Not the ref rewriter or the validator.** `LateEditTranslator`
    does the per-op rewrite; `LateEditPreflight` does the all-or-nothing
    pre-check. This module composes them and stamps the result commit.
  - **Not the persister.** It returns an in-memory commit;
    `CommitStore.import_commit/2` stores it (and re-runs namespace
    validation on the way in).
  """

  alias Commonplace.Document.Rebase
  alias Commonplace.Store.{Commit, CommitStore, LateEditPreflight, Namespace}
  alias Yelixer.{BlockStore, Doc, Encoding}

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

      # get_commit/2 returns :none for a missing row, never :not_found
      # (CX-tdkq.4 — dead clause surfaced by the R4(a) read refactor).
      :none ->
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
  def translate_edit_with_snapshot(%Commit{} = edit, %Commit{} = snapshot, opts \\ []) do
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
        if Keyword.get(opts, :fallback_to_positional, false) do
          positional_fallback(edit, snapshot, reason, ref_id, opts)
        else
          emit_untranslatable(edit, snapshot, reason, ref_id)
          err
        end

      {:error, _other} = err ->
        err
    end
  end

  # --- Positional-rebase fallback (CX-7sln / Build 6.6) ---

  # Opt-in path: when pre-flight fails with :case_a or :case_b and
  # `fallback_to_positional: true` is set, re-author the dirty edit as
  # native-coordinate ops on the target snapshot via `Rebase.rebase/3`
  # (CX-6a7). Requires the caller to supply `pre_doc:` — a fresh
  # reconstruction of the edit's P-namespace state (what the edit was
  # diffed against) — because reconstructing it from the store needs
  # history the translator doesn't own.
  #
  # Tradeoff (documented, opt-in): positional rebase re-authors under
  # the local peer's client id, losing the byte-determinism the
  # primary DM path provides. Two peers taking the fallback produce
  # different commits; the store won't collapse them.
  defp positional_fallback(edit, snapshot, reason, ref_id, opts) do
    with {:ok, pre_doc} <- fetch_pre_doc(opts),
         {:ok, dirty_doc} <- Encoding.apply_update(pre_doc, edit.update),
         {:ok, new_doc} <- Encoding.apply_update(Doc.new(), snapshot.update),
         {:ok, rebased} <- Rebase.rebase(pre_doc, dirty_doc, new_doc) do
      new_sv = BlockStore.state_vector(new_doc.store)
      translated_update = Encoding.encode_diff(rebased, new_sv)

      translated =
        Commit.new(
          edit.doc_uuid,
          translated_update,
          snapshot.id,
          %{kind: :regular, snapshot_parent: snapshot.id}
        )

      emit_fallback(edit, snapshot, reason, ref_id, translated)
      {:ok, translated}
    end
  end

  defp fetch_pre_doc(opts) do
    case Keyword.fetch(opts, :pre_doc) do
      {:ok, %Doc{} = pre_doc} -> {:ok, pre_doc}
      :error -> {:error, {:fallback_requires_pre_doc, :missing_opt}}
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
    # Explicit DM entries override length-based sub-clock expansion.
    # Merge-snapshots (CX-dx22) emit pre-expanded per-clock entries for
    # items that coalesce under the deterministic client_id; the length
    # on the rebuilt item would otherwise over-extrapolate and clobber
    # those explicit entries. Single-namespace snapshots remain
    # backwards-compatible — they emit one entry per item and rely on
    # length-based expansion for sub-clocks.
    explicit = MapSet.new(Map.keys(inner))

    Enum.reduce(inner, %{}, fn {{nc, nk}, {oc, ok}}, acc ->
      length = Map.get(lengths, {nc, nk}, 1)

      Enum.reduce(0..(max(length, 1) - 1), acc, fn offset, acc2 ->
        k = {nc, nk + offset}

        if offset == 0 or not MapSet.member?(explicit, k) do
          Map.put(acc2, k, {oc, ok + offset})
        else
          acc2
        end
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

  defp emit_fallback(edit, snapshot, reason, ref_id, translated) do
    :telemetry.execute(
      [:commonplace, :late_edit, :fallback],
      %{system_time: System.system_time()},
      %{
        edit_hash: edit.id,
        target_snapshot: snapshot.id,
        reason: reason,
        ref_id: ref_id,
        commit_id: translated.id
      }
    )
  end
end
