defmodule Commonplace.Store.SnapshotAncestry do
  @moduledoc """
  Snapshot-DAG walker (CX-ntz5 / Build 7.1).

  ## Why this exists

  Snapshots re-identify a document's items into a fresh namespace (a new
  *epoch* — see `Commonplace.Store.Namespace`), so two commits that
  diverged across a snapshot boundary speak different identity dialects.
  To merge them you first need the most recent epoch they *both* descend
  from — the shared vocabulary to translate through. This module finds
  it: the lowest common ancestor (LCA) in the DAG of snapshots, not the
  DAG of regular commits.

  That LCA is the pivot `C` in `Commonplace.Store.CrossEpochMerge`'s
  R→C→L two-pass translation. The two chains returned alongside it are
  the translation paths: `L_chain` / `R_chain` are the snapshots crossed
  going from `C` back up to each side's current epoch, so a consumer can
  compose the per-step derivation maps along each chain. In other words,
  this walker answers "where did these two heads last share an epoch, and
  what epoch hops separate each of them from it?" — everything
  `CrossEpochMerge` needs to line the two namespaces up.

  ## What it returns

  Given commits L and R it returns `{C, L_chain, R_chain}` where `C` is
  the LCA snapshot/genesis id and each chain is the ordered list of
  snapshots traversed from just-after-`C` up to and including that side's
  current namespace. If the two histories share no root at all (e.g.
  unrelated genesis ids), there is no pivot to translate through and the
  call returns `{:error, :no_common_ancestor}`.

  ## How the walk works

  Every commit carries a `metadata.kind` tag. Four kinds matter here:
  `:regular` and `:merge` are ordinary edits; `:snapshot` and `:genesis`
  are the *epoch boundaries*. A `:snapshot` commit additionally carries
  `metadata.snapshot_parents` — the list of ids of the snapshot/genesis
  commits it descends from, i.e. its edges in the snapshot DAG (how that
  list is built is `Commonplace.Store.Snapshotter`'s concern; here we
  only follow it). A `:genesis` commit is the document's root epoch — it
  has no snapshot parents and so terminates every walk.

  The snapshot DAG is the sub-graph over just those `:snapshot`/`:genesis`
  commits, edged by `snapshot_parents`. Regular and merge commits are
  never part of the chain — the walker always starts from a commit's
  *namespace* (`Namespace.current_namespace/1`), which is itself a
  snapshot or genesis id, then steps backward through the snapshot DAG:

    :snapshot → first entry of `metadata.snapshot_parents`
    :genesis → terminal (appears as last element of the down-chain)

  Each side's "down chain" is ordered most-recent-first (namespace →
  … → root), so the LCA is found by taking the *first* element of L's
  down-chain that also appears in R's — first match = lowest (most
  recent) common ancestor, which is exactly the epoch closest to both
  heads and therefore the cheapest to translate through.

  MVP assumption: snapshot chains are linear — each snapshot has
  exactly one entry in its `snapshot_parents` list. Multi-parent
  snapshots are introduced by Build 7.4 (merge-snapshot construction);
  extending this walker to handle them is scoped as a follow-up when
  cross-merge-snapshot LCA becomes load-bearing.
  """

  alias Commonplace.Store.{CommitStore, Namespace}

  @typedoc "Returned chain: snapshots from just-after-C up to the input's namespace."
  @type chain :: [binary()]

  @spec common_ancestor(GenServer.server(), binary(), binary()) ::
          {:ok, {binary(), chain(), chain()}}
          | {:error, :unknown_commit | :no_common_ancestor}
  def common_ancestor(store, l_id, r_id) do
    common_ancestor_with_fetcher(fetcher_for(store), l_id, r_id)
  end

  @doc """
  Return the ordered snapshot chain of `commit_id`'s namespace (CX-e31).

  The chain is `[genesis_id, s1, s2, ..., current_namespace]` — i.e.
  every snapshot (and the terminal genesis) reachable by following
  `metadata.snapshot_parents` back from the input's namespace. This
  exposes the snapshot-DAG as a first-class read API: callers can
  traverse history at snapshot granularity instead of scanning every
  regular commit, implement branch/merge UX over the snapshot tree, or
  detect concurrent snapshots that share a parent.

  MVP limitation (inherited from `common_ancestor/3`): on encountering
  a merge-snapshot with `snapshot_parents` ≥ 2, the walker takes the
  first parent. Full-DAG traversal lands as a follow-up when cross-
  merge-snapshot history becomes load-bearing.
  """
  @spec snapshot_chain(GenServer.server(), binary()) ::
          {:ok, chain()} | {:error, :unknown_commit}
  def snapshot_chain(store, commit_id) do
    snapshot_chain_with_fetcher(fetcher_for(store), commit_id)
  end

  @doc """
  `snapshot_chain/2` core — takes a fetcher closure `id -> commit | nil`.
  Exposed for testing against synthetic DAGs and for callers that
  already hold a CubDB handle.
  """
  @spec snapshot_chain_with_fetcher((binary() -> map() | nil), binary()) ::
          {:ok, chain()} | {:error, :unknown_commit}
  def snapshot_chain_with_fetcher(fetcher, commit_id) do
    case fetcher.(commit_id) do
      nil ->
        {:error, :unknown_commit}

      commit ->
        ns = Namespace.current_namespace(commit)
        {:ok, Enum.reverse(walk_down(fetcher, ns, []))}
    end
  end

  @doc """
  Walker core — takes a fetcher closure `id -> commit | nil`. Exposed for
  testing against synthetic DAGs and for callers that already hold a
  CubDB handle (see `Namespace.validate_commit_from_db/2` for the same
  pattern).
  """
  @spec common_ancestor_with_fetcher(
          (binary() -> map() | nil),
          binary(),
          binary()
        ) :: {:ok, {binary(), chain(), chain()}} | {:error, term()}
  def common_ancestor_with_fetcher(fetcher, l_id, r_id) do
    with %{} = l <- fetcher.(l_id) || :unknown,
         %{} = r <- fetcher.(r_id) || :unknown do
      l_ns = Namespace.current_namespace(l)
      r_ns = Namespace.current_namespace(r)

      l_down = walk_down(fetcher, l_ns, [])
      r_down = walk_down(fetcher, r_ns, [])

      case find_lca(l_down, r_down) do
        nil -> {:error, :no_common_ancestor}
        c -> {:ok, {c, chain_between(l_down, c), chain_between(r_down, c)}}
      end
    else
      :unknown -> {:error, :unknown_commit}
    end
  end

  # Walk from the given snapshot/genesis id backwards through
  # snapshot_parents until we hit a genesis or a nil id. Returns the
  # "down chain" [ns, parent, grandparent, ..., root].
  defp walk_down(_fetcher, nil, acc), do: Enum.reverse(acc)

  defp walk_down(fetcher, id, acc) do
    case fetcher.(id) do
      %{metadata: %{kind: :snapshot, snapshot_parents: [parent_id | _]}} ->
        # MVP linear: take first parent. Multi-parent (Build 7.4) will
        # require a full-DAG walk, not a single-path chase.
        walk_down(fetcher, parent_id, [id | acc])

      %{metadata: %{kind: :genesis}} ->
        Enum.reverse([id | acc])

      nil ->
        # Terminate cleanly — missing commit at the tail.
        Enum.reverse(acc)

      _ ->
        # Unexpected shape (e.g. regular commit landed in the chain).
        # Treat as terminal — no further walk possible.
        Enum.reverse([id | acc])
    end
  end

  defp find_lca(l_down, r_down) do
    r_set = MapSet.new(r_down)
    Enum.find(l_down, &MapSet.member?(r_set, &1))
  end

  defp chain_between(down_chain, c) do
    down_chain
    |> Enum.take_while(&(&1 != c))
    |> Enum.reverse()
  end

  defp fetcher_for(store) do
    fn id ->
      case CommitStore.get_commit(store, id) do
        {:ok, c} -> c
        _ -> nil
      end
    end
  end
end
