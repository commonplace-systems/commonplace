defmodule Commonplace.Store.Namespace do
  @moduledoc """
  Namespace-membership walker for the Merkle-tracked Yjs umbrella.

  A "namespace" is the set of clientIDs observed in the commit chain
  rooted at a given snapshot_parent. Walking from a regular commit's
  `snapshot_parent` back to the namespace root (a `:genesis` or
  `:snapshot`) and aggregating clientIDs tells us which Yjs participants
  the trust root has already witnessed.

  The validator uses this set to reject regular commits whose update
  ops reference clientIDs outside the namespace — the mechanism that
  stops a peer from reusing someone else's snapshot as a signing
  shortcut (see docs/namespace-model.md in commonplace-plan).

  ## Walk rules

  - `:genesis` — the walk terminates; no clientIDs contributed.
  - `:snapshot` — the walk terminates here, and the snapshot's own
    update contributes its full state-vector clientIDs (snapshots are
    trust roots that carry complete namespace membership).
  - `:regular` — contributes its update's clientIDs and continues to
    its `parent_id`.
  - `:merge` — contributes clientIDs and continues (a merge commit
    carries deltas, not a trust boundary).
  - legacy (`metadata == %{}`) — contributes clientIDs and continues.

  ## Bootstrap

  A regular commit whose `snapshot_parent` is a fresh genesis sees an
  empty namespace. The validator accepts such commits unconditionally —
  this is how the first real edit after doc creation binds the first
  clientID into the namespace.
  """

  alias Commonplace.Store.CommitStore

  @doc """
  Aggregate clientIDs in the namespace rooted at `commit_id`.

  `store` may be a running `CommitStore` server name/pid — commits are
  fetched via the public `get_commit/2` API.
  """
  @spec namespace_client_ids(GenServer.server(), binary()) :: {:ok, MapSet.t()}
  def namespace_client_ids(store, commit_id) do
    walk(fetcher_for(store), commit_id, MapSet.new())
  end

  @doc """
  Aggregate clientIDs using a raw CubDB handle. Used from inside
  CommitStore's own `handle_call` where a GenServer callback can't
  call back into itself.
  """
  @spec namespace_client_ids_from_db(pid(), binary()) :: {:ok, MapSet.t()}
  def namespace_client_ids_from_db(db, commit_id) do
    walk(fetcher_for_db(db), commit_id, MapSet.new())
  end

  @doc """
  Is `client_id` a member of the namespace rooted at `commit_id`?
  """
  @spec clientID_in_namespace?(GenServer.server(), binary(), non_neg_integer()) :: boolean()
  def clientID_in_namespace?(store, commit_id, client_id) do
    {:ok, set} = namespace_client_ids(store, commit_id)
    MapSet.member?(set, client_id)
  end

  @doc """
  Compute the trust-root id a new commit chained on top of `commit`
  should carry as its `snapshot_parent` (CX-a04).

  - `:snapshot` → `commit.id` (the snapshot itself is the new trust root).
  - `:genesis` → `commit.id` (genesis is the trust root for a fresh doc).
  - `:regular` / `:merge` → inherit `commit.metadata.snapshot_parent`.
  - legacy (`metadata == %{}`) → `nil`. Pre-umbrella commits don't carry
    a trust root; callers chaining off legacy state should not be
    auto-stamped.
  """
  @spec current_namespace(map()) :: binary() | nil
  def current_namespace(%{metadata: %{kind: :snapshot}} = commit), do: commit.id
  def current_namespace(%{metadata: %{kind: :genesis}} = commit), do: commit.id
  def current_namespace(%{metadata: %{kind: :regular, snapshot_parent: sp}}), do: sp
  def current_namespace(%{metadata: %{kind: :merge, snapshot_parent: sp}}), do: sp
  def current_namespace(%{metadata: m}) when m == %{}, do: nil
  def current_namespace(_commit), do: nil

  @doc """
  Invert a derivation map (CX-2rd / Build 6.2).

  A derivation map has shape `%{source_snapshot_hash => %{new_id => old_id}}`
  where ids are `{client_id, clock}` tuples. The inverse flips every inner
  `{new_id => old_id}` to `{old_id => new_id}`, leaving the outer
  keyed-by-source_snapshot_hash structure untouched. Used by the late-edit
  translator (Build 6.3) to rewrite op references from a post-snapshot
  namespace back to the source namespace, and by cross-epoch merge
  (Build 7.3) to commute edits through common ancestors.

  ## Examples

      iex> Commonplace.Store.Namespace.inverse_derivation_map(%{})
      %{}

      iex> Commonplace.Store.Namespace.inverse_derivation_map(%{<<1>> => %{}})
      %{<<1>> => %{}}

      iex> Commonplace.Store.Namespace.inverse_derivation_map(
      ...>   %{<<1>> => %{{1, 0} => {100, 0}, {1, 1} => {100, 1}}}
      ...> )
      %{<<1>> => %{{100, 0} => {1, 0}, {100, 1} => {1, 1}}}
  """
  @spec inverse_derivation_map(%{optional(binary()) => %{optional(tuple()) => tuple()}}) ::
          %{optional(binary()) => %{optional(tuple()) => tuple()}}
  def inverse_derivation_map(dm) when is_map(dm) do
    Map.new(dm, fn {src, inner} ->
      {src, Map.new(inner, fn {new_id, old_id} -> {old_id, new_id} end)}
    end)
  end

  @doc """
  Compose a chain of derivation maps (CX-i6xt / Build 7.2).

  Given `[DM1, DM2, ..., DMn]` where `DMi` maps items in snapshot `Si`
  back to items in `Si-1`, produce a single composed map that maps
  items in `Sn` directly back to items in `S0` — the chained lookup

      composed[hash(S0)][new_in_Sn]
        = DM1[hash(S0)][DM2[hash(S1)][...DMn[hash(Sn-1)][new_in_Sn]]]

  Entries whose mid-chain lookup misses (the intermediate id is not
  a key in the next DM's inner map) are dropped from `composed` — the
  composed DM only claims to know ids that trace all the way back.

  This is load-bearing for Build 7.3 (translate-into-primary merge) and
  Build 7.4 (merge-snapshot construction): both need to translate a
  ref across an arbitrary number of snapshot epochs without touching
  snapshot contents — just DM bytes.

  Base cases:
  - `compose_dms([])` returns `%{}` (identity; nothing to translate).
  - `compose_dms([dm])` returns `dm` unchanged.

  ## Examples

      iex> Commonplace.Store.Namespace.compose_dms([])
      %{}

      iex> dm = %{<<0>> => %{{2, 0} => {1, 0}}}
      iex> Commonplace.Store.Namespace.compose_dms([dm]) == dm
      true
  """
  @spec compose_dms([%{optional(binary()) => %{optional(tuple()) => tuple()}}]) ::
          %{optional(binary()) => %{optional(tuple()) => tuple()}}
  def compose_dms([]), do: %{}
  def compose_dms([dm]) when is_map(dm), do: dm

  def compose_dms([first | rest]) when is_map(first) do
    Enum.reduce(rest, first, &compose_pair(&2, &1))
  end

  # compose_pair(earlier, later): combine two DMs where `earlier` is
  # closer to S0 in the chain and `later` is closer to Sn. For each
  # entry `{new_in_Sc, mid_in_Sb}` in `later`, find `mid_in_Sb` as a
  # KEY in some inner map of `earlier`. If found, that earlier inner
  # map's value `old_in_Sa` becomes the composed entry under the same
  # earlier outer hash.
  defp compose_pair(earlier, later) do
    Enum.reduce(later, %{}, fn {_later_hash, later_inner}, acc ->
      Enum.reduce(later_inner, acc, fn {new_in_Sc, mid_in_Sb}, acc2 ->
        Enum.reduce(earlier, acc2, fn {earlier_hash, earlier_inner}, acc3 ->
          case Map.get(earlier_inner, mid_in_Sb) do
            nil ->
              acc3

            old_in_Sa ->
              Map.update(acc3, earlier_hash, %{new_in_Sc => old_in_Sa}, fn existing ->
                Map.put(existing, new_in_Sc, old_in_Sa)
              end)
          end
        end)
      end)
    end)
  end

  @doc """
  Validate a commit against its declared namespace.

  Returns `:ok` if the commit is acceptable, `{:error, reason}` if its
  update references clientIDs outside the namespace rooted at
  `snapshot_parent`. See the module doc for rule details.
  """
  @spec validate_commit(GenServer.server(), map()) :: :ok | {:error, term()}
  def validate_commit(store, commit) do
    do_validate(fetcher_for(store), commit)
  end

  @doc """
  Validate a commit using a raw CubDB handle. Used from the CommitStore
  GenServer. See `validate_commit/2`.
  """
  @spec validate_commit_from_db(pid(), map()) :: :ok | {:error, term()}
  def validate_commit_from_db(db, commit) do
    do_validate(fetcher_for_db(db), commit)
  end

  defp do_validate(fetcher, %{metadata: m} = commit) do
    cond do
      m == %{} -> :ok
      Map.get(m, :kind) == :genesis -> :ok
      Map.get(m, :kind) == :snapshot -> :ok
      Map.get(m, :kind) == :merge -> :ok
      Map.get(m, :kind) == :regular -> validate_regular(fetcher, commit, m)
      true -> :ok
    end
  end

  defp validate_regular(fetcher, commit, %{snapshot_parent: sp_id}) when is_binary(sp_id) do
    # The commit declares it descends from `snapshot_parent` (its trust
    # root). The namespace is the set of clientIDs observed in the chain
    # from the commit's direct `parent_id` back to that trust root,
    # inclusive of the trust root's own state vector (for snapshots).
    #
    # Walking from `parent_id` (not `sp_id`) is what makes the
    # accumulation meaningful — regular commits between the trust root
    # and this new commit extend the namespace, and the validator must
    # see them.
    {:ok, namespace} = walk(fetcher, commit.parent_id, MapSet.new())

    case Yelixer.Encoding.update_client_ids(commit.update) do
      {:ok, update_ids} ->
        cond do
          MapSet.size(namespace) == 0 -> :ok
          MapSet.subset?(update_ids, namespace) -> :ok
          true ->
            outside = MapSet.difference(update_ids, namespace) |> MapSet.to_list()
            {:error, {:client_ids_outside_namespace, outside}}
        end

      {:error, reason} ->
        {:error, {:malformed_update, reason}}
    end
  end

  # CX-a04: post-umbrella, every :regular commit MUST carry
  # snapshot_parent. Auto-stamp (in CommitStore.create_commit) guarantees
  # this for locally-produced commits; this clause rejects malformed
  # incoming imports. Legacy `%{}` metadata keeps the read-side hatch
  # and is handled earlier in `do_validate/2`.
  defp validate_regular(_fetcher, _commit, _meta), do: {:error, :missing_snapshot_parent}

  defp fetcher_for(store) do
    fn id ->
      case CommitStore.get_commit(store, id) do
        {:ok, c} -> c
        _ -> nil
      end
    end
  end

  defp fetcher_for_db(db) do
    fn id -> CubDB.get(db, {:commit, id}) end
  end

  defp walk(_fetcher, nil, acc), do: {:ok, acc}

  defp walk(fetcher, commit_id, acc) do
    case fetcher.(commit_id) do
      nil ->
        {:ok, acc}

      %{metadata: %{kind: :genesis}} ->
        {:ok, acc}

      %{metadata: %{kind: :snapshot}} = commit ->
        {:ok, accumulate(acc, commit.update)}

      %{metadata: %{kind: :regular}} = commit ->
        walk(fetcher, commit.parent_id, accumulate(acc, commit.update))

      %{metadata: %{kind: :merge}} = commit ->
        walk(fetcher, commit.parent_id, accumulate(acc, commit.update))

      %{metadata: m} = commit when m == %{} ->
        walk(fetcher, commit.parent_id, accumulate(acc, commit.update))

      _ ->
        {:ok, acc}
    end
  end

  defp accumulate(acc, update) do
    case Yelixer.Encoding.update_client_ids(update) do
      {:ok, ids} -> MapSet.union(acc, ids)
      {:error, _} -> acc
    end
  end
end
