defmodule Commonplace.Store.MergeSnapshotter do
  @moduledoc """
  Merge-snapshot construction (CX-dx22 / Build 7.4).

  `build_merge_snapshot/4` is the two-parent generalization of
  `Commonplace.Store.Snapshotter`: where a plain snapshot re-encodes
  *one* branch's state into a fresh namespace, a *merge-snapshot* merges
  two divergent branches — `L` and `R`, identified by the commit ids
  `l_id` and `r_id` of the two branch heads being merged — and
  re-encodes the *merged* state into a fresh namespace that
  both branches derive from. (A *namespace* is the identity space a
  doc's CRDT items live in, named by the snapshot commit that opened it;
  the vocabulary is owned by `Commonplace.Store.Namespace`.)

  ## Why a merge-snapshot

  `Commonplace.Store.CrossEpochMerge` (the `:translate` strategy) folds
  R into L's *existing* namespace: the merged result still lives in
  `L_ns`, with R's edits re-expressed in terms of L's ids. The
  `:merge_snapshot` strategy this module builds makes the opposite move
  — it computes the same merged content but then *resets the id-space*,
  minting a brand-new namespace that BOTH L and R translate forward
  into. `Commonplace.Store.MergePolicy` owns the decision of *when* to
  pay for a reset instead of translating into an ever-growing namespace
  (large divergence / state-vector growth is what motivates the reset).

  Because there are now two source namespaces, the derivation map
  carries two inner entries — the multi-parent shape `Snapshotter`'s
  single-parent map anticipated. The result is a `:snapshot` commit with

      snapshot_parents = [L_ns, R_ns]
      derivation_map   = %{L_ns => DM_L_inner, R_ns => DM_R_inner}

  where each inner map goes `new_id → source_ns_id`. A late edit authored
  against either `L_ns` or `R_ns` translates through its corresponding
  inner map into the merge-snapshot's fresh namespace; the outer-map
  flatten in `LateEditTranslator.build_inverse_dm/1` (CX-2rd Build 6.2)
  already handles the two-entry shape transparently.

  ## Algorithm

  The construction below is reimplementation-grade detail: every step
  delegates the heavy CRDT machinery to a named module
  (`SnapshotAncestry`, `CrossEpochMerge`, `Snapshotter`). What a *caller*
  relies on is the metadata shape above plus byte-determinism (below);
  the steps exist to explain how the two inner derivation maps get
  populated correctly — the subtle part, since L/C content and R-only
  content reach the fresh namespace by different paths (steps 6–7).

  1. Resolve `C = common_ancestor(L, R)`, plus `L_chain` and `R_chain`.
  2. Compose each chain's forward DMs (`new → old` direction). The
     resulting composed maps go `L_ns → C_ns` and `R_ns → C_ns`.
  3. Reconstruct `D_L` and `D_R`.
  4. Call `CrossEpochMerge.merge/3` — its `update` field is the R-only
     post-C edits translated into `L_ns` (R→C via `r_composed`, C→L via
     inverse `l_composed`). Apply those bytes on `D_L` to get `D_merged`.
  5. Run `snapshot_update/1` on `D_merged` for deterministic bytes, then
     pair rebuilt ids to source ids at CHARACTER granularity. The MVP
     `Snapshotter.pair_ids/2` pairs by item-count in client-desc order,
     which breaks when multiple source items (from disjoint L/R clients)
     coalesce into a single rebuilt item under the deterministic
     client_id. This module walks both sequences in YATA/observable
     order and emits one explicit DM entry per clock — matched with
     `Translator.expand_inner`'s explicit-entry preference so the
     length-based sub-clock expansion doesn't clobber explicit entries.
  6. `DM_L_inner[new_id] = d_merged_id` for items whose d_merged_id is
     in L's clientID space (items authored within `D_L`, including
     L-chain re-authorings of C content). L-namespace late edits only
     reference L-ns ids, so filtering on L-ns clients is sufficient.
  7. `DM_R_inner` is built from two sources:
     - R-only translated items: in D_merged their own-ids are still
       R-ns (`CrossEpochMerge` rewrites references, not own-ids), so
       their d_merged_id IS their R-ns id — entry is identity.
     - C-ancestor items (appearing as L-ns ids in D_merged): translate
       `L_ns → C_ns` via forward-composed L_chain, then `C_ns → R_ns`
       via inverse-composed R_chain. When either chain is empty, the
       corresponding step is identity (L_ns == C_ns or C_ns == R_ns).

  ## Byte-determinism

  Inputs `(store, l_id, r_id)` plus the commit DAG's own byte-
  deterministic storage produce identical translated bytes, identical
  `D_merged` (Yjs V1 is byte-deterministic on observable state under
  a single deterministic client_id — see `Snapshotter.build/1`), and
  therefore identical snapshot `update` bytes and DM contents.

  ## Scope

  Ships with in-memory byte-determinism tests on the commit struct.
  CID-dedup-via-import (`CommitStore.import_commit/2` acceptance) is
  blocked on CX-fbs6 (namespace validator must accept cross-epoch
  translated commits whose item-authorship clients are new to the
  target namespace). End-to-end store-accepts-merge-snapshot tests
  land with CX-fbs6.

  ## Relationship to the writer-identity / hand model (CX-41qg, AUDIT ONLY)

  Like `Snapshotter`, the `deterministic_client_id/1` this module uses
  (via `Snapshotter.build/1`) is a "deterministic-anyone" value, not a
  writer hand — see `Snapshotter`'s moduledoc for the distinction. Do
  not substitute `Commonplace.WriterHand.for_doc/1` here: that would
  make the merge-snapshot's client_id a function of the doc's uuid
  instead of its merged content, breaking the property that two nodes
  computing the SAME merge independently still need — byte-identical
  output regardless of which node ran the merge. Audited under
  CX-41qg.3 and intentionally left unchanged.
  """

  alias Commonplace.Store.{
    Commit,
    CommitStore,
    CrossEpochMerge,
    Namespace,
    SnapshotAncestry,
    Snapshotter
  }

  alias Yelixer.{BlockStore, Doc, Encoding}

  @type result :: {:ok, Commit.t()} | {:error, term()}

  @spec build_merge_snapshot(GenServer.server(), binary(), binary(), keyword()) :: result()
  def build_merge_snapshot(store, l_id, r_id, opts \\ [])
      when is_binary(l_id) and is_binary(r_id) do
    with {:ok, l_commit} <- fetch_commit(store, l_id),
         {:ok, r_commit} <- fetch_commit(store, r_id),
         {:ok, {_c_id, l_chain, r_chain}} <-
           SnapshotAncestry.common_ancestor(store, l_id, r_id),
         {:ok, l_composed} <- compose_chain(store, l_chain, opts[:l_chain_override]),
         {:ok, r_composed} <- compose_chain(store, r_chain, opts[:r_chain_override]),
         {:ok, merge_commit} <- CrossEpochMerge.merge(store, l_id, r_id, opts),
         {:ok, d_l} <- reconstruct(store, l_id),
         {:ok, d_merged} <- apply_update(d_l, merge_commit.update) do
      # Character-level pair_ids — the MVP Snapshotter pairs by item-count
      # position (collect_item_ids in client-desc order), which fails when
      # multiple source items coalesce into a single rebuilt item under
      # the merge-snapshot's deterministic client_id. Walk the source and
      # new sequences in YATA/observable order at character granularity
      # so each rebuilt clock maps to the correct source id.
      {update_bytes, raw_pairs} = build_with_char_pairs(d_merged)

      l_ns_clients = client_ids(d_l)
      {dm_l_inner, dm_r_inner} = split_dm(raw_pairs, l_ns_clients, l_composed, r_composed)

      l_ns = Namespace.current_namespace(l_commit)
      r_ns = Namespace.current_namespace(r_commit)

      # When both chains hang directly off C, L_ns == R_ns and the DM
      # collapses to a single key — union the inner maps so late edits
      # from either side see a complete DM. In the two-distinct-ns case,
      # the outer map preserves both entries (6.2's 2-entry DM support).
      derivation_map =
        if l_ns == r_ns do
          %{l_ns => Map.merge(dm_l_inner, dm_r_inner)}
        else
          %{l_ns => dm_l_inner, r_ns => dm_r_inner}
        end

      metadata = %{
        kind: :snapshot,
        snapshot_parents: [l_ns, r_ns],
        derivation_map: derivation_map,
        snapshotter_version: Snapshotter.snapshotter_version()
      }

      snap_commit =
        Commit.new(
          r_commit.doc_uuid,
          update_bytes,
          l_commit.id,
          metadata,
          [r_commit.id]
        )

      {:ok, snap_commit}
    end
  end

  # --- helpers ---

  defp fetch_commit(store, id) do
    case CommitStore.get_commit(store, id) do
      {:ok, c} -> {:ok, c}
      :none -> {:error, {:unknown_commit, id}}
    end
  end

  # Compose a chain of snapshot commits into a single forward DM
  # (source-ns → C-ns). Shares the per-sub-clock expansion semantics of
  # CrossEpochMerge (CX-fdjh) — sub-clock refs resolve at every clock.
  defp compose_chain(_store, _chain, override) when is_list(override) do
    {:ok, compose(override)}
  end

  defp compose_chain(store, chain, nil) do
    Enum.reduce_while(chain, {:ok, []}, fn id, {:ok, acc} ->
      case CommitStore.get_commit(store, id) do
        {:ok, snap} -> {:cont, {:ok, [snap | acc]}}
        # get_commit/2 returns :none for a missing row (CX-tdkq.4).
        :none -> {:halt, {:error, {:unknown_snapshot, id}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, compose(Enum.reverse(reversed))}
      err -> err
    end
  end

  defp compose([]), do: %{}

  defp compose(snapshots) do
    snapshots
    |> Enum.map(&forward_dm_for/1)
    |> Enum.map(&expand_per_sub_clock/1)
    |> Namespace.compose_dms()
  end

  defp forward_dm_for(%{metadata: %{derivation_map: dm}}) when is_map(dm), do: dm
  defp forward_dm_for(_), do: %{}

  defp expand_per_sub_clock(dm) do
    lengths =
      dm
      |> Enum.flat_map(fn {_src, inner} -> Map.keys(inner) end)
      |> Map.new(fn id -> {id, 1} end)

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

  # Re-run DocBuilder-style reconstruction via CrossEpochMerge's
  # parent_id walker (works for branched commits not on :latest).
  defp reconstruct(store, commit_id) do
    case collect_replay_chain(store, commit_id, []) do
      {:ok, chain} ->
        Enum.reduce_while(chain, {:ok, Doc.new()}, fn c, {:ok, d} ->
          case Encoding.apply_update(d, c.update) do
            {:ok, d2} -> {:cont, {:ok, d2}}
            {:error, _} = err -> {:halt, err}
          end
        end)

      :error ->
        {:error, {:cannot_reconstruct, commit_id}}
    end
  end

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

      # get_commit/2 returns :none for a missing row (CX-tdkq.4).
      :none ->
        :error
    end
  end

  defp apply_update(doc, bytes) do
    case Encoding.apply_update(doc, bytes) do
      {:ok, d} -> {:ok, d}
      {:error, _} = err -> err
    end
  end

  defp client_ids(%Doc{store: %{clients: clients}}), do: MapSet.new(Map.keys(clients))

  # Character-level pair_ids. Replaces Snapshotter.pair_ids for merge-
  # snapshot construction because the MVP pair_ids pairs by item-count
  # in client-desc order, which fails for multi-source coalescence.
  #
  # Output contract matches Snapshotter.build/1: `{update_bytes,
  # pairs_map}` where pairs_map has entries for every clock in the
  # rebuilt doc — keys are `{new_client, new_clock}` tuples, values are
  # `{src_client, src_clock}` tuples, one per character.
  defp build_with_char_pairs(%Doc{} = source) do
    deterministic = %{source | client_id: deterministic_client_id(source)}
    # CX-umz: Doc.snapshot_update now returns {bytes, dm}; this path
    # builds its own char-granularity pair map so the inner dm is
    # discarded — the item-level pairing Doc emits doesn't fit merge-
    # snapshot's multi-source coalescence needs.
    #
    # CX-oh9z: force: true — merge-snapshot sources are reconstructed
    # merge results, not docs known to carry `__sub:` nested sub-types;
    # force preserves the pre-guard behavior rather than crashing this
    # match on a tagged-tuple return it doesn't expect.
    {update_bytes, _item_dm} = Doc.snapshot_update(deterministic, force: true)
    {:ok, new_doc} = Encoding.apply_update(Doc.new(), update_bytes)

    pairs =
      Map.keys(source.types)
      |> Enum.reduce(%{}, fn type_name, acc ->
        src_seq = BlockStore.get_sequence(source.store, type_name)
        new_seq = BlockStore.get_sequence(new_doc.store, type_name)
        Map.merge(acc, pair_sequences(new_seq, src_seq))
      end)

    {update_bytes, pairs}
  end

  defp deterministic_client_id(%Doc{store: store}) do
    # CX-w1fw: client_ids/1 includes clients whose only blocks are
    # still in client_pending — Map.keys(store.clients) alone would
    # miss them.
    case BlockStore.client_ids(store) do
      [] -> 0
      clients -> Enum.min(clients)
    end
  end

  # Walk two YATA sequences in parallel by character. For each character
  # position, emit `{new_id_at_pos, src_id_at_pos}` — the rebuilt clock
  # within its covering item paired with the source clock within its
  # covering item.
  defp pair_sequences(new_seq, src_seq) do
    new_chars = flatten_item_clocks(new_seq)
    src_chars = flatten_item_clocks(src_seq)

    new_chars
    |> Enum.zip(src_chars)
    |> Map.new()
  end

  defp flatten_item_clocks(items) do
    Enum.flat_map(items, fn item ->
      Enum.map(0..(max(item.length, 1) - 1), fn offset ->
        {item.id.client, item.id.clock + offset}
      end)
    end)
  end

  # Walk the raw DM_inner from Snapshotter.build/1 (which pairs new_ids
  # to d_merged source ids in L-ns for L/C content and R-ns for R-only
  # content) and split it into two namespace-scoped inner maps.
  defp split_dm(raw_pairs, l_clients, l_composed, r_composed) do
    l_composed_flat = flatten_inner(l_composed)
    r_composed_inverse_flat = flatten_inner(Namespace.inverse_derivation_map(r_composed))
    l_chain_empty? = l_composed == %{}
    r_chain_empty? = r_composed == %{}

    Enum.reduce(raw_pairs, {%{}, %{}}, fn {new_id, src_id}, {dm_l, dm_r} ->
      {src_client, _} = src_id

      cond do
        # L-ns item: translate src_id → C_ns → R_ns to populate DM_R.
        # Empty chains identity-fallthrough: L_chain empty means L_ns ==
        # C_ns (src_id is already the C-ns id); R_chain empty means
        # C_ns == R_ns (c_id is already the R-ns id). For non-empty
        # chains, missing lookups mean the item isn't in C (e.g., L-only
        # post-C edits) and shouldn't appear in DM_R.
        MapSet.member?(l_clients, src_client) ->
          dm_l2 = Map.put(dm_l, new_id, src_id)

          c_id =
            if l_chain_empty?, do: src_id, else: Map.get(l_composed_flat, src_id)

          r_id =
            cond do
              c_id == nil -> nil
              r_chain_empty? -> c_id
              true -> Map.get(r_composed_inverse_flat, c_id)
            end

          dm_r2 = if r_id, do: Map.put(dm_r, new_id, r_id), else: dm_r
          {dm_l2, dm_r2}

        # R-only translated item: own-id preserved through translation,
        # so src_id is already the R-ns id — entry is identity into DM_R.
        true ->
          {dm_l, Map.put(dm_r, new_id, src_id)}
      end
    end)
  end

  defp flatten_inner(dm) do
    Enum.reduce(dm, %{}, fn {_hash, inner}, acc -> Map.merge(acc, inner) end)
  end
end
