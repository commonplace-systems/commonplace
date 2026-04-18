defmodule Commonplace.Store.CrossEpochMerge do
  @moduledoc """
  Cross-epoch translate-into-primary merge (CX-fdjh / Build 7.3).

  Given two commits `L` and `R` in the same Merkle commit DAG, produce
  a merge commit whose `update` carries R's edits-since-common-ancestor
  C commuted into L's namespace. The resulting commit has:

      parent_id     = L.id
      merge_parents = [R.id]
      metadata      = %{kind: :merge, snapshot_parent: L_ns}

  where `L_ns = Namespace.current_namespace(L)`.

  ## Algorithm

  1. Find the common ancestor `C` and the two namespace chains `L_chain`,
     `R_chain` via `SnapshotAncestry.common_ancestor/3`. Chains are
     ordered from just-after-C up to the input's namespace, inclusive.
  2. Fetch each chain's snapshots and extract their forward derivation
     maps (`%{source_hash => %{new_id => old_id}}`). Expand per sub-clock
     the same way the late-edit translator does (CX-fefz) so multi-char
     items align one-to-one at every clock.
  3. Compose R_chain's forward DMs → `r_composed` (keys=R-ns, values=C-ns).
     The forward DM is already in the "source→target" direction that
     `LateEditTranslator.translate_update/2` wants — no inversion needed
     for the R→C pass.
  4. Compose L_chain's forward DMs → `l_composed` (keys=L-ns, values=C-ns).
     Then `inverse_derivation_map/1` → `l_inverse` (keys=C-ns,
     values=L-ns) — what pass 2 needs to translate C-refs into L-refs.
  5. Reconstruct `D_R` (full doc at R) and `D_C` (full doc at C).
     Compute `r_edits = encode_diff(D_R, sv_of_D_C)` — bytes of all
     items R holds whose client isn't in C's state vector.
  6. Filter items whose own id is a key in `r_composed` — these are
     R-side re-authorings of C content that L ALSO has via L_chain's
     re-authorings under L-namespace ids. Including them would double-
     insert C's content when the merge is applied on D_L. The
     non-re-authored items (R's novel post-C edits) are what we
     translate and bundle.
  7. Pass 1 (R→C): `LateEditPreflight.translate_and_validate(filtered,
     r_composed)`. On failure emit `[:commonplace, :late_edit,
     :untranslatable]` with `phase: :r_to_c`.
  8. Pass 2 (C→L): `LateEditPreflight.translate_and_validate(pass1,
     l_inverse)`. On failure emit the same event with `phase: :c_to_l`.
  9. Emit merge commit struct via `Commit.new/5` with the pass-2 bytes.

  ## Scope

  Ships with in-memory byte-determinism on the commit struct. Persisting
  via `CommitStore.import_commit/2` requires CX-fbs6 (namespace
  validator must accept translated commits whose item-authorship
  clients are new to L's namespace). Integration-level CID-dedup
  tests deferred to a follow-up once CX-fbs6 lands.

  ## Red events

  All pre-flight failures re-use CX-fefz's `[:commonplace, :late_edit,
  :untranslatable]` event path, adding a `phase: :r_to_c | :c_to_l`
  key so downstream handlers can distinguish which translation pass
  rejected the merge.
  """

  alias Commonplace.Store.{
    Commit,
    CommitStore,
    LateEditPreflight,
    Namespace,
    SnapshotAncestry
  }

  alias Yelixer.{BlockStore, Doc, Encoding, Item}

  @type merge_result :: {:ok, Commit.t()} | {:error, term()}

  @spec merge(GenServer.server(), binary(), binary(), keyword()) :: merge_result()
  def merge(store, l_id, r_id, opts \\ []) when is_binary(l_id) and is_binary(r_id) do
    with {:ok, l_commit} <- fetch_commit(store, l_id),
         {:ok, r_commit} <- fetch_commit(store, r_id),
         {:ok, {c_id, l_chain, r_chain}} <-
           SnapshotAncestry.common_ancestor(store, l_id, r_id),
         {:ok, r_chain_snaps} <- resolve_chain_snapshots(store, r_chain, opts[:r_chain_override]),
         {:ok, l_chain_snaps} <- resolve_chain_snapshots(store, l_chain, opts[:l_chain_override]) do
      r_composed = compose_chain_forward(r_chain_snaps)
      l_composed = compose_chain_forward(l_chain_snaps)
      l_inverse = Namespace.inverse_derivation_map(l_composed)

      with {:ok, d_r} <- reconstruct(store, r_commit.doc_uuid, r_id),
           {:ok, d_c} <- reconstruct(store, r_commit.doc_uuid, c_id),
           {:ok, r_edits} <- encode_edits_since(d_r, d_c),
           {:ok, filtered} <- drop_reauthored_items(r_edits, r_composed),
           {:ok, in_c_ns} <- run_pass(filtered, r_composed, :r_to_c, l_commit, r_commit),
           {:ok, in_l_ns} <- run_pass(in_c_ns, l_inverse, :c_to_l, l_commit, r_commit) do
        l_ns = Namespace.current_namespace(l_commit)

        merge_commit =
          Commit.new(
            r_commit.doc_uuid,
            in_l_ns,
            l_commit.id,
            %{kind: :merge, snapshot_parent: l_ns},
            [r_commit.id]
          )

        {:ok, merge_commit}
      end
    end
  end

  # --- Commit & chain resolution ---

  defp fetch_commit(store, id) do
    case CommitStore.get_commit(store, id) do
      {:ok, c} -> {:ok, c}
      :not_found -> {:error, {:unknown_commit, id}}
    end
  end

  # Accept an override list of snapshot-shaped maps (used by tests to
  # force adversarial DM states; same shape as the `broken_snapshot`
  # pattern in translator_fallback_test.exs).
  defp resolve_chain_snapshots(_store, _chain, override) when is_list(override),
    do: {:ok, override}

  defp resolve_chain_snapshots(store, chain, nil) do
    Enum.reduce_while(chain, {:ok, []}, fn id, {:ok, acc} ->
      case CommitStore.get_commit(store, id) do
        {:ok, snap} -> {:cont, {:ok, [snap | acc]}}
        :not_found -> {:halt, {:error, {:unknown_snapshot, id}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      err -> err
    end
  end

  # Compose a chain's forward DMs into a single %{source_hash =>
  # %{new_id => old_id}} map. Chain order: [just-after-C, ..., tip].
  # Each snapshot's DM maps its own namespace → its parent's namespace,
  # so reducing left-to-right via `compose_dms/1` yields tip→C directly.
  #
  # Per-sub-clock expansion mirrors Translator.build_inverse_dm/1
  # (CX-fefz) so refs into the middle of a consolidated multi-char item
  # resolve at every clock, not just the leading clock.
  defp compose_chain_forward([]), do: %{}

  defp compose_chain_forward(snapshots) do
    snapshots
    |> Enum.map(&forward_dm_for/1)
    |> Enum.map(&expand_per_sub_clock(&1, snapshot_item_lengths(&1)))
    |> Namespace.compose_dms()
  end

  defp forward_dm_for(%{metadata: %{derivation_map: dm}}) when is_map(dm), do: dm
  defp forward_dm_for(_), do: %{}

  # For sub-clock expansion we need item lengths keyed by new-id. The
  # snapshot's `update` holds those lengths, but for synthetic overrides
  # (tests) there's no update — fall back to single-clock entries.
  defp snapshot_item_lengths(dm), do: lengths_fallback(dm)

  defp lengths_fallback(dm) do
    dm
    |> Enum.flat_map(fn {_src, inner} -> Map.keys(inner) end)
    |> Map.new(fn id -> {id, 1} end)
  end

  defp expand_per_sub_clock(dm, lengths) do
    Map.new(dm, fn {hash, inner} -> {hash, expand_inner(inner, lengths)} end)
  end

  defp expand_inner(inner, lengths) do
    Enum.reduce(inner, %{}, fn {{nc, nk}, {oc, ok}}, acc ->
      len = Map.get(lengths, {nc, nk}, 1)

      Enum.reduce(0..(max(len, 1) - 1), acc, fn offset, acc2 ->
        Map.put(acc2, {nc, nk + offset}, {oc, ok + offset})
      end)
    end)
  end

  # --- Doc reconstruction & edits delta ---

  # Reconstruct a doc at an arbitrary commit id by walking parent_id
  # links backward from the target, short-circuiting at the nearest
  # snapshot on the backward path, then replaying forward. Unlike
  # `Tree.DocBuilder.reconstruct_doc_at/3`, this walker does NOT start
  # from `:latest` — it starts from the requested commit and follows
  # `parent_id`, so it works on branched commits that aren't on
  # :latest's chain.
  defp reconstruct(store, _uuid, commit_id) do
    case collect_replay_chain(store, commit_id, []) do
      {:ok, chain} ->
        doc = Doc.new()

        Enum.reduce_while(chain, {:ok, doc}, fn c, {:ok, d} ->
          case Encoding.apply_update(d, c.update) do
            {:ok, d2} -> {:cont, {:ok, d2}}
            {:error, _} = err -> {:halt, err}
          end
        end)

      :error ->
        {:error, {:cannot_reconstruct, commit_id}}
    end
  end

  # Walk backward from `commit_id` via parent_id until we hit either a
  # snapshot (terminal — snapshot is self-contained) or a genesis
  # (skipped; its update is <<>>). Return commits in forward-replay
  # order [snapshot_or_first_regular, ..., target].
  defp collect_replay_chain(store, commit_id, acc) do
    case CommitStore.get_commit(store, commit_id) do
      {:ok, %{metadata: %{kind: :snapshot}} = c} ->
        {:ok, [c | acc]}

      {:ok, %{metadata: %{kind: :genesis}}} ->
        {:ok, acc}

      {:ok, %{parent_id: nil} = c} ->
        {:ok, [c | acc]}

      {:ok, c} ->
        collect_replay_chain(store, c.parent_id, [c | acc])

      :not_found ->
        :error
    end
  end

  # r_edits = items R has whose clients aren't in C's state vector. In
  # the cross-epoch case D_R's clients are R's re-authoring clients
  # plus any novel-edit clients — none overlap with C's re-authoring
  # client(s) — so encode_diff against D_C.sv captures all of them.
  defp encode_edits_since(d_r, d_c) do
    sv = BlockStore.state_vector(d_c.store)
    {:ok, Encoding.encode_diff(d_r, sv)}
  end

  # Drop items whose own id is a key in the flattened composed DM.
  # Those are R-side re-authorings of C-content; L already holds the
  # equivalent content under its own L-namespace ids via L_chain's
  # re-authorings. Including them would double-insert C's content when
  # the merge is applied to D_L.
  defp drop_reauthored_items(bytes, composed_dm) do
    with {:ok, {items, ds, _rest}} <- Encoding.decode_update(bytes) do
      flat = flatten(composed_dm)

      {kept_items, dropped_ids} =
        Enum.reduce(items, {[], MapSet.new()}, fn it, {acc, dropped} ->
          key = {it.id.client, it.id.clock}

          if Map.has_key?(flat, key) do
            {acc, MapSet.put(dropped, key)}
          else
            {[it | acc], dropped}
          end
        end)

      items = Enum.reverse(kept_items)
      ds = filter_delete_set(ds, dropped_ids)

      {:ok, reencode(items, ds)}
    end
  end

  defp flatten(dm) do
    Enum.reduce(dm, %{}, fn {_hash, inner}, acc -> Map.merge(acc, inner) end)
  end

  # Drop delete-set clocks that targeted dropped items (those are
  # already absent from our bundle; including the delete would produce
  # an unresolved ref). Leaving other ranges untouched — they target
  # items we're keeping.
  defp filter_delete_set(ds, dropped_ids) do
    dropped_by_client =
      dropped_ids
      |> Enum.group_by(fn {c, _} -> c end, fn {_, k} -> k end)

    clients =
      Map.new(ds.clients, fn {client, ranges} ->
        case Map.get(dropped_by_client, client) do
          nil -> {client, ranges}
          drops -> {client, trim_ranges(ranges, MapSet.new(drops))}
        end
      end)

    %{ds | clients: clients}
  end

  defp trim_ranges(ranges, drop_set) do
    Enum.flat_map(ranges, fn {start, stop} ->
      Enum.reduce(start..(stop - 1), [], fn clk, acc ->
        if MapSet.member?(drop_set, clk), do: acc, else: [{clk, clk + 1} | acc]
      end)
      |> Enum.reverse()
    end)
  end

  # Re-encode a filtered items+ds pair back into a Yjs V1 update. Same
  # shape as LateEditTranslator.reencode — builds a synthetic Doc and
  # runs encode_update.
  defp reencode(items, delete_set) do
    store =
      Enum.reduce(items, BlockStore.new(), fn %Item{} = item, s ->
        BlockStore.push(s, item)
      end)

    doc = %Doc{
      client_id: 0,
      store: store,
      delete_set: delete_set,
      types: %{}
    }

    Encoding.encode_update(doc)
  end

  # --- Translation passes ---

  # When the composed DM is empty the corresponding chain was empty —
  # source namespace == target namespace, so the refs are already in
  # the target namespace and no translation is needed. Short-circuit:
  # pass the bytes through unchanged. This is the correct behavior
  # both for empty L_chain (pass 2) and empty R_chain (pass 1).
  defp run_pass(bytes, dm, _phase, _l_commit, _r_commit) when map_size(dm) == 0,
    do: {:ok, bytes}

  defp run_pass(bytes, dm, phase, l_commit, r_commit) do
    case LateEditPreflight.translate_and_validate(bytes, dm) do
      {:ok, translated} ->
        {:ok, translated}

      {:error, {:untranslatable, reason, ref_id}} = err ->
        emit_untranslatable(l_commit, r_commit, phase, reason, ref_id)
        err

      {:error, _} = err ->
        err
    end
  end

  defp emit_untranslatable(l_commit, r_commit, phase, reason, ref_id) do
    :telemetry.execute(
      [:commonplace, :late_edit, :untranslatable],
      %{system_time: System.system_time()},
      %{
        edit_hash: r_commit.id,
        target_snapshot: Namespace.current_namespace(l_commit),
        reason: reason,
        ref_id: ref_id,
        phase: phase
      }
    )
  end

end
