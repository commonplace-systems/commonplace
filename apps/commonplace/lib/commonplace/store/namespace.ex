defmodule Commonplace.Store.Namespace do
  @moduledoc """
  Namespace toolkit: which clientIDs belong to a trust root, which trust
  root a new commit should declare, and how to translate references across
  snapshot epochs.

  A **namespace** is the set of Yjs clientIDs witnessed in the commit
  chain rooted at a given **trust root** — a `:genesis` or `:snapshot`
  commit. Walking back from a commit's `snapshot_parent` to that root and
  unioning each commit's clientIDs answers "which participants has this
  lineage's trust root already seen?"

  Namespaces exist because snapshots **re-identify** items: a snapshot
  can rewrite the `{clientID, clock}` ids of the state it captures into
  a fresh namespace, so the same logical text carries different ids on
  either side of a snapshot boundary. That power needs two guardrails,
  and this module is both:

    1. A **membership check** that prevents cross-namespace forgery
       (`validate_commit/2` and friends).
    2. A **translation algebra** (`inverse_derivation_map/1`,
       `compose_dms/1`) that rewrites references across snapshot epochs
       so cross-epoch merges and late edits still resolve.

  `current_namespace/1` is the write-side helper: given the commit you
  are chaining onto, it returns the `snapshot_parent` the new commit
  should declare.

  ## The anti-forgery invariant (the membership half)

  `validate_commit/2` is the trust boundary on the import path. A
  `:regular` commit must declare the `snapshot_parent` it descends from;
  the validator walks from the commit's `parent_id` back to that trust
  root, aggregating clientIDs into the namespace, then checks the
  commit's update against it.

  The check is **role-split** (CX-fbs6):

    - **Reference clientIDs** — the ids an op points *at*: `origin`,
      `right_origin`, an `{:id, _}` parent, delete-set targets. These
      must already be members of the namespace.
    - **Authorship clientIDs** — the ids of the *new* items this commit
      inserts. These are exempt; they *extend* the namespace when the
      commit lands.

  Without the split, a legitimately translated cross-epoch commit (whose
  new items carry fresh authorship ids) would be rejected for
  "introducing" unseen ids. With it, only dangling *references* are
  rejected — the exact forgery prevented: a peer cannot craft a commit
  whose ops point at clientIDs this lineage never witnessed (e.g. by
  grafting another doc's snapshot as a trust-root "shortcut" to make
  foreign references look valid). See docs/namespace-model.md in
  commonplace-plan.

  ## Walk rules

  `walk/3` aggregates clientIDs by commit kind:

  - `:genesis` — terminates; contributes nothing (empty namespace).
  - `:snapshot` — terminates AND contributes its full state-vector
    clientIDs (a snapshot is a trust root carrying complete membership).
  - `:regular` — contributes its update's clientIDs, continues to
    `parent_id`.
  - `:merge` — contributes clientIDs, continues (a merge carries deltas,
    not a trust boundary).
  - legacy (`metadata == %{}`) — contributes, continues.

  Because regular commits between the trust root and the new commit also
  extend the namespace, the walk starts at the new commit's `parent_id`,
  not at `snapshot_parent` — the validator must see those intermediate
  commits too.

  ## Bootstrap

  A regular commit whose `snapshot_parent` is a fresh genesis sees an
  **empty** namespace and is accepted unconditionally
  (`MapSet.size(namespace) == 0` arm). This is how the first edit after
  doc creation binds the first clientID — there is nothing yet to be a
  member of.

  ## Trust-root computation

  `current_namespace/1` is the write-side counterpart of the walk. A
  `:snapshot` or `:genesis` is its own trust root (returns `commit.id`);
  `:regular` and `:merge` inherit `commit.metadata.snapshot_parent`;
  legacy `%{}` returns `nil` — pre-umbrella commits carry no trust root,
  so callers chaining off them are not auto-stamped.

  ## Derivation-map algebra (the translation half)

  A snapshot's **derivation map** (DM) records how it re-identified
  items: `%{source_snapshot_hash => %{new_id => old_id}}`, where ids are
  `{clientID, clock}` tuples. Two operations turn it into a reference
  translator:

  - `inverse_derivation_map/1` flips each inner `new_id => old_id` to
    `old_id => new_id`, so a reference minted in a post-snapshot
    namespace can be rewritten back into the source namespace. The
    late-edit translator (Build 6.3) and cross-epoch merge (Build 7.3)
    rely on this.
  - `compose_dms/1` chains a list of per-epoch maps `[DM1..DMn]` into a
    single map from the newest namespace to the oldest. A reference
    whose mid-chain lookup misses is dropped — the composed map only
    claims ids that trace all the way back. This lets a ref be translated
    across an arbitrary number of snapshot epochs using only
    derivation-map bytes, never snapshot contents (load-bearing for
    Build 7.3 / 7.4).

  ## Invariants

  - A `:regular` commit's reference clientIDs must be a subset of its
    namespace, or it is rejected with `{:error, {:unknown_reference, _}}`.
  - A post-umbrella `:regular` commit MUST carry a `snapshot_parent`; a
    missing one is `{:error, :missing_snapshot_parent}` (legacy `%{}` is
    the only read-side hatch, handled before this check).
  - The empty namespace accepts unconditionally (bootstrap).
  - `compose_dms([])` is identity (`%{}`); `compose_dms([dm])` is `dm`.

  ## What this module is NOT

  - **Not the validator's caller.** `CommitStore.import_commit/3` invokes
    `validate_commit_from_db/2`; this module only computes the verdict.
  - **Not the id-integrity check.** `Commonplace.Store.Commit.verify_id/1`
    proves a commit's bytes match its hash and runs *first*; namespace
    validation assumes a hash-verified commit and asks the separate
    question of whether its references are in-namespace (the CX-gwz
    ordering: id gate, then namespace validator).
  - **Not the snapshotter.** It consumes derivation maps that
    `Commonplace.Store.Snapshotter` produces; it does not build them.
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
  # entry `{new_in_Sc, mid_in_Sb}` in `later`, look `mid_in_Sb` up as a
  # key in `earlier`'s inner maps. If it resolves to a value `old_in_Sa`,
  # emit `{new_in_Sc => old_in_Sa}` under that same earlier outer hash —
  # chaining the two hops `new_in_Sc -> mid_in_Sb -> old_in_Sa` into one.
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

    # CX-fbs6: role-split. Only reference clientIDs (origin, right_origin,
    # {:id, _} parent, delete_set targets) must resolve in the current
    # namespace. Authorship clientIDs (owners of NEW items inserted by
    # this commit) extend the namespace when the commit lands — they
    # are not subject to the subset check. This lets translated cross-
    # epoch commits (CX-fefz / CX-fdjh / CX-dx22) import cleanly while
    # still rejecting commits whose refs would dangle.
    case Yelixer.Encoding.update_client_ids_by_role(commit.update) do
      {:ok, %{reference: reference_ids}} ->
        cond do
          MapSet.size(namespace) == 0 ->
            :ok

          MapSet.subset?(reference_ids, namespace) ->
            :ok

          true ->
            outside = MapSet.difference(reference_ids, namespace) |> MapSet.to_list()
            {:error, {:unknown_reference, outside}}
        end

      {:error, reason} ->
        {:error, {:malformed_update, reason}}
    end
  end

  # CX-hqko: validation judges CLAIMS, not ABSENCES. The old CX-a04 comment
  # asserted that auto-stamp (CommitBuilder.stamp_snapshot_parent) guarantees
  # every locally-produced :regular commit carries snapshot_parent. That
  # premise does not hold: stamp_snapshot_parent derives snapshot_parent from
  # the PARENT commit's Namespace.current_namespace/1, which returns nil for
  # legacy `%{}`-metadata parents — so it silently skips, and an honest,
  # locally-produced :regular commit on a legacy-headed chain lands with NO
  # snapshot_parent key at all.
  #
  # Rejecting that absence bought zero security: a dishonest author can
  # already bypass all epoch validation by writing `%{}` metadata, which
  # `do_validate/2` short-circuits straight to `:ok`. So the strict clause
  # only ever punished the population that authored MORE truthfully (kinded
  # metadata on a legacy chain) while a `%{}` author sailed through
  # unchecked — a category error that pushes authors toward saying less.
  # The `MapSet.size(namespace) == 0 -> :ok` branch above already embodies
  # the same rule two lines up: "unvalidatable therefore accept."
  #
  # So: a commit that claims nothing about epochs (no snapshot_parent key)
  # gets no epoch validation here — it remains fully subject to the
  # separate WHO/trust gates. A commit that DOES claim an epoch is held to
  # that claim completely: present-but-unusable (nil, wrong type, etc.) is
  # a malformed claim, not an absence, and still rejects below.
  defp validate_regular(_fetcher, _commit, meta) when not is_map_key(meta, :snapshot_parent),
    do: :ok

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
