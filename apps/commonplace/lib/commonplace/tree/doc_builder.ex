defmodule Commonplace.Tree.DocBuilder do
  @moduledoc """
  Shared helpers for reconstructing Y.Docs from commit chains.

  Used by Fork and Merge to replay commits and build documents.
  """

  require Logger

  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Yelixer.{Doc, Encoding}

  @doc """
  Reconstruct a doc by replaying its commit chain (oldest -> newest).

  Use for content docs where edits are stored incrementally.
  Returns `{:ok, doc}` or `:none` if no commits exist.

  CX-u7p: when a snapshot commit (metadata.kind == :snapshot) appears
  in the chain, the backward walk stops at the most recent snapshot —
  the snapshot is itself a self-contained encoding of the doc state at
  that point — and the forward replay starts from that snapshot plus
  any commits chained on top. Docs with no snapshot commits replay the
  full chain exactly as before (backward-compatible).

  CX-ggdv did NOT bound this walk, deliberately. Unlike a pin read, a
  head read has no target commit to walk backward from, and its full
  window is what `maybe_warn_truncated/2` and `maybe_warn_chain_incomplete/2`
  inspect and what `maybe_lazy_snapshot/3` measures — so a
  `until_snapshot: true` here would change warning behaviour and snapshot
  triggering, not just cost. The head walk is still O(total chain length);
  bounding it is its own ticket with its own neutrality fence.

  CX-41qg.3: pass `client_id: id` (mirrors `reconstruct_snapshot/3`,
  CX-41qg.1) to fix the replica's identity for write funnels that
  reconstruct the FULL chain (rather than just the latest commit)
  before re-encoding a new commit — e.g. `Commonplace.Outline`'s
  mutation helpers. Without it every such write mints a fresh random
  client_id and the state vector grows one slot per write, forever.
  Read-only callers can omit the option.
  """
  def reconstruct_doc(store, uuid, opts \\ []) do
    # CX-6scm: `mint: false` suppresses the CX-fkvc lazy-snapshot
    # write-on-read. `Commonplace.Projection.project_at/4` uses this path
    # as tier (ii)'s authority and must NEVER mint — a read that writes
    # cannot be a verification primitive, and it would perturb the very
    # `:latest` pointer the tier-(ii) TOCTOU guard is checking.
    # (`reconstruct_doc`'s minting in general is CX-68m6, out of scope.)
    {mint?, opts} = Keyword.pop(opts, :mint, true)

    commits =
      CommitStoreClient.commit_log(store, uuid, limit: CommitStore.max_commit_log_limit())
      |> Enum.reverse()

    case commits do
      [] ->
        :none

      _ ->
        maybe_warn_truncated(commits, uuid)
        maybe_warn_chain_incomplete(commits, uuid)

        commits_to_apply = commits |> trim_to_latest_snapshot() |> Enum.reject(&genesis?/1)
        doc = Doc.new(opts)

        result =
          Enum.reduce(commits_to_apply, {:ok, doc}, fn c, {:ok, d} ->
            Encoding.apply_update(d, c.update)
          end)

        # CX-fkvc: opportunistically trigger a snapshot when the post-trim
        # chain is long enough to be worth compacting. The trigger primitive
        # is itself idempotent / CAS-safe, so racing the producer-side hook
        # (CX-tvyb), the periodic sweeper (CX-fab5), or the explicit CLI
        # command (CX-2ok0) collapses to a single snapshot via CX-umz.
        # Fired in a Task so the read isn't blocked on the snapshot build.
        if mint?, do: maybe_lazy_snapshot(store, uuid, length(commits_to_apply))

        result
    end
  end

  defp maybe_lazy_snapshot(store, uuid, chain_length) do
    if lazy_snapshot_enabled?() and chain_length >= lazy_snapshot_threshold() do
      # R4(b) / CX-tdkq.4: route through the single-flight SnapshotWorker
      # instead of an unbounded `Task.start`. Under read pressure many reads
      # of the same doc fire this path at once; the worker collapses them to
      # one in-flight snapshot attempt (plus at most one coalesced re-run)
      # rather than piling up redundant Tasks. Replaces the old ETS debounce.
      Commonplace.SnapshotWorker.request(store, uuid)
    end

    :ok
  end

  # CX-fkvc: default-on in dev/prod, default-off in test (see
  # config/test.exs) so background snapshot writes don't race with
  # test isolation. Tests that exercise the lazy path flip this in
  # their setup.
  defp lazy_snapshot_enabled? do
    Application.get_env(:commonplace, :reader_lazy_snapshot_enabled, true)
  end

  defp lazy_snapshot_threshold do
    Application.get_env(
      :commonplace,
      :reader_lazy_snapshot_threshold,
      100
    )
  end

  # Given commits in chronological order (oldest -> newest), return the
  # tail starting at the most recent snapshot. If no snapshot is found,
  # returns the full list unchanged.
  defp trim_to_latest_snapshot(commits) do
    case Enum.find_index(Enum.reverse(commits), &snapshot?/1) do
      nil ->
        commits

      idx_from_end ->
        # idx_from_end is 0-based from the *end* of the list. Convert
        # to a position from the start, then drop everything before it.
        Enum.drop(commits, length(commits) - 1 - idx_from_end)
    end
  end

  # CX-klpi: the commit_log walk is capped at max_commit_log_limit(). If
  # we got back exactly that many commits AND none of them is a snapshot,
  # the walk may have stopped short of genesis with nothing to short-
  # circuit reconstruction — make the previously-silent truncation loud.
  # Behavior is unchanged; this only adds observability.
  defp maybe_warn_truncated(commits, uuid) do
    limit = CommitStore.max_commit_log_limit()

    if length(commits) >= limit and not Enum.any?(commits, &snapshot?/1) do
      Logger.warning(
        "DocBuilder.reconstruct_doc: commit_log hit the #{limit}-commit cap for doc #{uuid} " <>
          "with no snapshot found in the window — reconstruction may be silently truncated (CX-klpi)"
      )

      :telemetry.execute(
        [:commonplace, :doc_builder, :truncated_no_snapshot],
        %{count: length(commits)},
        %{uuid: uuid}
      )
    end

    :ok
  end

  # CX-vzod: the missing-parent sibling of the cap case above. collect_log
  # terminates silently when a parent commit is absent from the store —
  # indistinguishable from genesis-reached. If no snapshot grounds the
  # replay, reconstruction starts from a fresh doc mid-chain and serves
  # silently wrong content. Loudness only (read-path availability
  # preserved); the trust walks fail closed on this same condition
  # (CX-klpi's {:authorization_chain_incomplete, _}).
  defp maybe_warn_chain_incomplete([oldest | _] = commits, uuid) do
    # A full-length page means the walk stopped at the CAP, not at a
    # missing parent — that case is maybe_warn_truncated/2's. Only a
    # SHORT page ending at a commit with a live parent_id pointer means
    # the store is actually missing a commit.
    grounded? =
      length(commits) >= CommitStore.max_commit_log_limit() or
        Enum.any?(commits, &snapshot?/1) or genesis?(oldest) or is_nil(oldest.parent_id)

    unless grounded? do
      Logger.warning(
        "DocBuilder.reconstruct_doc: chain for doc #{uuid} does not reach genesis — " <>
          "oldest fetched commit has a parent_id the store is missing; reconstruction " <>
          "starts mid-chain and content may be silently wrong (CX-vzod)"
      )

      :telemetry.execute(
        [:commonplace, :doc_builder, :chain_incomplete],
        %{count: length(commits)},
        %{uuid: uuid, oldest_commit_id: oldest.id}
      )
    end

    :ok
  end

  defp maybe_warn_chain_incomplete([], _uuid), do: :ok

  defp snapshot?(commit) do
    case Map.get(commit, :metadata) do
      %{kind: :snapshot} -> true
      _ -> false
    end
  end

  # CX-m3x: genesis commits are synthetic DAG roots with an empty
  # `update` payload. They exist to establish a deterministic namespace
  # root, not to carry any Yjs state, so the reducer must skip them —
  # `Encoding.apply_update` on <<>> would crash the replay.
  defp genesis?(commit) do
    case Map.get(commit, :metadata) do
      %{kind: :genesis} -> true
      _ -> false
    end
  end

  @doc """
  Reconstruct a doc by applying only the latest commit to a fresh doc.

  Use for schema docs where fork always stores full snapshots.
  This avoids CRDT inconsistency from applying full snapshots on top of each other.
  Returns `{:ok, doc}` or `:none` if no commits exist.

  CX-41qg.1: pass `client_id: id` to fix the replica's identity on the
  reconstructed doc — needed by write funnels (CommandRouter, Sync.Agent)
  that re-encode a NEW commit from this doc. Without a stable client_id,
  every write mints a fresh random one and the state vector grows one
  slot per write, forever. Read-only callers can omit the option.
  """
  def reconstruct_snapshot(store, uuid, opts \\ []) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Doc.new(opts)
        Encoding.apply_update(doc, commit.update)

      :none ->
        :none
    end
  end

  @doc """
  Reconstruct a doc by replaying commits up to (and including) a specific commit.

  Returns `{:ok, doc}` or `:none` if the target commit is not found in the chain.

  CX-u7p: like `reconstruct_doc/2`, this short-circuits on snapshot
  commits (metadata.kind == :snapshot). If a snapshot commit exists on
  the path from root to `target_commit_id`, the replay starts at the
  most recent snapshot at or before the target and applies only that
  snapshot plus any commits chained on top, up to and including the
  target. Without this, merges of compacted branches would start from a
  wrong baseline (`Tree.Merge.merge_leaf/5` uses this function).

  CX-b0ow.9: accepts and forwards `Doc.new/1` opts (mirrors the
  `reconstruct_doc/3` forwarding added in CX-41qg.3) — in particular
  `client_id:` (a stable writer hand) and `clock_floor:` (see
  `Yelixer.Doc.new/1`'s moduledoc), used by
  `Commonplace.GitBridge.Inbound` to reconstruct an anchor replica
  under the bridge's hand with mints continued past ops that landed
  later in the chain.

  CX-ggdv: the walk is bounded — see `chain_to/4`. `require_head_reachable:
  true` restores the pre-CX-ggdv `:none`-as-ancestry-oracle contract for
  callers that use it as one (`Commonplace.Tree.Fork`).
  """
  def reconstruct_doc_at(store, uuid, target_commit_id, opts \\ []) do
    {walk_opts, doc_opts} = Keyword.split(opts, [:require_head_reachable])

    case chain_to(store, uuid, target_commit_id, walk_opts) do
      {:ok, commits_to_apply} ->
        doc = Doc.new(doc_opts)

        Enum.reduce(commits_to_apply, {:ok, doc}, fn c, {:ok, d} ->
          Encoding.apply_update(d, c.update)
        end)

      :none ->
        :none
    end
  end

  @doc """
  The exact commit list `reconstruct_doc_at/4` would replay for
  `target_commit_id` — post-snapshot-trim, genesis commits already
  rejected — oldest first.

  Extracted for `Commonplace.Projection` (CX-6scm), which threads
  signature verification along **the chain it actually walks**. Sharing
  this function is what makes "the chain we verified" and "the chain we
  replayed" the same list by construction rather than by two
  implementations agreeing. It changes nothing about which commits the
  walk visits — `reconstruct_doc_at/4` is now its only other caller.

  Returns `{:ok, commits}` or `:none` when `target_commit_id` is not on
  the doc's chain. Note `{:ok, []}` is a legitimate answer: a genesis pin
  replays nothing and IS the empty state (F7).

  ## The bounded walk (CX-ggdv)

  The pin-read caller already **has** the target commit id, so the walk
  starts there and goes backward, stopping at the nearest `:snapshot`
  commit (inclusive) or at genesis. The pre-CX-ggdv implementation walked
  forward from `:latest` to the target and only then trimmed to the
  latest snapshot — so the walk term was linear in TOTAL chain length and
  independent of distance-to-snapshot. A pin 50 commits past a snapshot
  on a 10,000-deep chain paid ~1.9 s of walk to replay 50 commits.
  Snapshots bounded the REPLAY; nothing bounded the WALK. Now the walk is
  O(distance-to-nearest-snapshot) exactly.

  **This is a pure cost change. Same commits, same order, same bytes.**
  Both directions produce the same list because both are the same
  `parent_id` walk over the same edges, and the forward version's only
  extra work was fetching ancestors that `trim_to_latest_snapshot/1` then
  discarded. Three places where that identity needed care:

    * **Cross-doc chains (F5).** 2.2% of docs have commits carrying a
      FOREIGN `doc_uuid` in-chain (fork lineage). The store's walk follows
      `parent_id` and never filters on `doc_uuid`, in either direction, so
      a forked lineage is traversed identically. Proven by fixture rather
      than argued.

    * **Cap truncation.** The old walk's window was anchored at HEAD:
      positions `0..limit-1` from `:latest`. The backward walk's natural
      window is anchored at the TARGET. When a snapshot grounds the
      replay the two windows select the same snapshot and the question is
      moot; when the backward walk instead runs out of budget with **no
      snapshot found and the chain still continuing**, the two windows
      genuinely differ — so that case returns the old head-anchored
      answer (`cap_fallback/5`), which it does WITHOUT a second full walk
      because the two windows are nested. The cap-truncated docs keep
      returning exactly what they returned. See
      "Residual" below for the one shape this does not cover, which is
      measured rather than assumed.

    * **Reachability.** The old `:none` doubled as an ancestry oracle:
      "target is among the first `limit` commits walking back from
      `:latest(uuid)`". A backward walk cannot observe that without the
      head walk it exists to avoid, so a pin on an ABANDONED branch (a
      commit orphaned by a reflog reset, say) now reconstructs where it
      used to return `:none`. Callers that use `:none` AS the oracle pass
      `require_head_reachable: true` and get the old contract verbatim
      — `Commonplace.Tree.Fork` is the one such caller in the tree.

      The same change has a second, cap-shaped form: a pin FURTHER from
      head than `max_commit_log_limit/0` fell outside the old window
      entirely and was reported "not on the chain", while the backward
      walk sees a pin perfectly well grounded in its own history and
      reconstructs it. Strictly more information in both forms — and a
      byte change all the same, which is why both are tested rather than
      left to be discovered.

  ## Residual, stated rather than hidden

  One shape can still differ: a target at depth `t` from head whose
  nearest snapshot lies at depth `> limit - 1` — i.e. `t + walk_length >
  10,000`. There the old path replayed from an arbitrary mid-chain
  position (a truncated, less complete baseline) and the new path replays
  from the real snapshot (a complete one). Detecting it would cost the
  head walk, which is the cost this whole function exists to avoid, so it
  is not detected — it is measured.

  Measured 2026-08-06 against a read-only `CubDB.back_up/2` copy of the
  live serve (69,973 rows, 5,186 docs, depth classes 2–10: 4,900 · 11–100:
  187 · 101–1,000: 50 · >1,000: 49): the census's 80 head docs, its 27
  conflicted pins, and a depth-stratified sample of 390 (doc, pin) pairs
  taking EVERY doc in the deepest class — **0 divergences**, chain and
  projection alike. New bytes would be *more* correct in this shape, not
  less, but it is a byte change and so it is named rather than assumed
  absent.
  """
  @spec chain_to(term(), String.t(), binary(), keyword()) :: {:ok, [struct()]} | :none
  def chain_to(store, uuid, target_commit_id, opts \\ []) do
    if Keyword.get(opts, :require_head_reachable, false) do
      head_anchored_chain_to(store, uuid, target_commit_id)
    else
      bounded_chain_to(store, uuid, target_commit_id)
    end
  end

  defp bounded_chain_to(store, uuid, target_commit_id) do
    limit = CommitStore.max_commit_log_limit()

    walked =
      CommitStoreClient.commit_log_from(store, target_commit_id,
        limit: limit,
        until_snapshot: true
      )

    case walked do
      [] ->
        # The target commit itself is not in the store. The old path
        # reported this the same way, via "not found on the chain".
        :none

      [newest | _] = desc when newest.id == target_commit_id ->
        if cap_bound_without_snapshot?(store, desc, limit) do
          cap_fallback(store, uuid, target_commit_id, desc, limit)
        else
          emit_walk(uuid, desc, :bounded)
          {:ok, desc |> Enum.reverse() |> Enum.reject(&genesis?/1)}
        end

      _ ->
        :none
    end
  end

  # The walk stopped because it exhausted `limit`, not because it found a
  # snapshot or reached the DAG root — and the chain provably continues
  # (the oldest commit still names a parent the store holds). Only then do
  # the two anchorings select different baselines.
  defp cap_bound_without_snapshot?(store, desc, limit) do
    oldest = List.last(desc)

    length(desc) >= limit and
      not Enum.any?(desc, &snapshot?/1) and
      not is_nil(oldest.parent_id) and
      match?({:ok, _}, CommitStoreClient.get_commit(store, oldest.parent_id))
  end

  # The ambiguous window, answered with the OLD bytes without paying the
  # old walk twice.
  #
  # Naively re-running `head_anchored_chain_to/3` here doubles the cost on
  # exactly the deepest documents in the corpus — measured 1.7 s → 3.8 s
  # on a >10,000-commit chain pinned below its last snapshot. A
  # performance ticket that makes its worst case worse has not shipped.
  #
  # It is avoidable, because the two windows are nested. Number positions
  # from head (head = 0). The head-anchored answer is positions
  # `t..limit-1`; the walk just done covers `t..t+limit-1`, a SUPERSET.
  # So the old answer is already in hand — it is the newest `limit - t`
  # entries of `desc` — and the only missing fact is `t` itself. Walking
  # from head *just far enough to reach the target* costs `t` fetches and
  # stops there, instead of the full `limit` the old walk always paid.
  #
  # `t` not found within `limit` steps is the old `:none`: the target is
  # not reachable from `:latest` inside the cap.
  #
  # `trim_to_latest_snapshot/1` is applied for exactness even though this
  # branch is snapshot-free by construction — the invariant lives in one
  # place, not in a comment.
  defp cap_fallback(store, uuid, target_commit_id, desc, limit) do
    case distance_from_head(store, uuid, target_commit_id, limit) do
      nil ->
        :none

      t ->
        window = desc |> Enum.take(limit - t) |> Enum.reverse()
        emit_walk(uuid, desc, :cap_fallback)
        {:ok, window |> trim_to_latest_snapshot() |> Enum.reject(&genesis?/1)}
    end
  end

  # Steps from `:latest` down to `target_commit_id`, or nil if the target
  # is not reachable within `limit`. Pages the walk so the common (short)
  # answer does not fetch the whole cap's worth of rows.
  defp distance_from_head(store, uuid, target_commit_id, limit) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, head} -> scan_for(store, head.id, target_commit_id, 0, limit)
      _ -> nil
    end
  end

  @scan_page 256

  defp scan_for(_store, _from_id, _target, walked, limit) when walked >= limit, do: nil
  defp scan_for(_store, nil, _target, _walked, _limit), do: nil

  defp scan_for(store, from_id, target, walked, limit) do
    page = CommitStoreClient.commit_log_from(store, from_id, limit: min(@scan_page, limit - walked))

    case Enum.find_index(page, &(&1.id == target)) do
      nil ->
        case List.last(page) do
          nil -> nil
          %{parent_id: nil} -> nil
          %{parent_id: parent} -> scan_for(store, parent, target, walked + length(page), limit)
        end

      idx ->
        walked + idx
    end
  end

  # The pre-CX-ggdv implementation, verbatim in behaviour: walk from
  # `:latest` (head-anchored window), scan forward for the target, trim.
  # Retained as the exact-fidelity fallback and as the
  # `require_head_reachable: true` contract.
  defp head_anchored_chain_to(store, uuid, target_commit_id) do
    commits =
      CommitStoreClient.commit_log(store, uuid, limit: CommitStore.max_commit_log_limit())
      |> Enum.reverse()

    result =
      Enum.reduce_while(commits, {:not_found, []}, fn commit, {_status, acc} ->
        if commit.id == target_commit_id do
          {:halt, {:found, Enum.reverse([commit | acc])}}
        else
          {:cont, {:not_found, [commit | acc]}}
        end
      end)

    case result do
      {:found, to_apply} ->
        emit_walk(uuid, commits, :head_anchored)
        {:ok, to_apply |> trim_to_latest_snapshot() |> Enum.reject(&genesis?/1)}

      {:not_found, _} ->
        :none
    end
  end

  # Observability for the bound itself. `walked` is the number of commit
  # rows the store actually fetched and deserialized — the term CX-ggdv
  # exists to shrink — so a regression that quietly restores the head walk
  # shows up as a number, not as a slow test.
  defp emit_walk(uuid, walked, mode) do
    :telemetry.execute(
      [:commonplace, :doc_builder, :chain_to],
      %{walked: length(walked)},
      %{uuid: uuid, mode: mode}
    )
  end
end
