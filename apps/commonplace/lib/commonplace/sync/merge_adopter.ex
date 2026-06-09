defmodule Commonplace.Sync.MergeAdopter do
  @moduledoc """
  CX-8k1v: autonomous B-side convergence via import-hook adoption.

  When a peer imports a merge commit it did not invoke locally, the
  commit lands in the store via `import_commit` but `:latest` is
  intentionally not touched (CX-m3x preserves local heads from being
  clobbered by background sync). That leaves a convergence gap: a peer
  that only receives merges — never invokes one — never advances
  `:latest` to the merge, even though the merge is a strictly newer
  and valid head.

  This module fills the gap with a conservative rule:

    If the imported commit is a merge whose ancestor DAG (via
    `parent_id` + `merge_parents`, transitively) reaches the local
    `:latest`, then the merge dominates the local head and it is safe
    to advance `:latest` to the merge.

  Note the direction: the walk follows *ancestor* edges from the merge,
  so "the merge reaches local `:latest`" means local `:latest` is an
  ancestor of the merge — the merge descends from the local head, not
  the other way around. That is exactly why domination guarantees no
  local work is lost: since the local head is an ancestor of the merge,
  every local commit is already in the merge's ancestral closure and so
  its content is folded into the merge's product. When the merge does
  NOT dominate local `:latest` (a sibling case — neither head is an
  ancestor of the other), this module is a no-op and some other
  mechanism (SiblingMerger sweep, explicit merge invocation) is
  responsible for converging.

  Wired into `Commonplace.Sync.NodeSync.import_with_translation/3`.

  Option (b) from CX-8k1v's design matrix — the import-hook adoption
  implemented here. Option (c) — push-based set_latest via the
  merge-command reply — was considered and not taken because (b) works
  under offline/catch-up sync without requiring the peer to be
  subscribed at merge time.
  """

  alias Commonplace.Store.{Commit, CommitStoreClient}

  @type outcome :: :adopted | :skipped

  @doc """
  Advance `:latest` to `commit` iff `commit` is a merge dominating the
  current local `:latest` for its `doc_uuid`. Returns `:adopted` when
  it fired, `:skipped` otherwise.
  """
  @spec maybe_adopt(GenServer.server(), Commit.t()) :: outcome()
  def maybe_adopt(store, %Commit{metadata: %{kind: :merge}} = commit) do
    case CommitStoreClient.latest_commit(store, commit.doc_uuid) do
      {:ok, %Commit{id: same_id}} when same_id == commit.id ->
        :skipped

      {:ok, %Commit{id: local_latest_id}} ->
        if dominates?(store, commit, local_latest_id) do
          :ok = CommitStoreClient.set_latest(store, commit.doc_uuid, commit.id)
          emit_adopted(commit, local_latest_id)
          :adopted
        else
          :skipped
        end

      :none ->
        :skipped
    end
  end

  def maybe_adopt(_store, %Commit{}), do: :skipped

  @doc """
  True iff `target_id` is reachable from `commit` by walking
  `parent_id` and `merge_parents` edges transitively. Visited IDs are
  memoized so diamond-shaped DAGs don't cause repeated work.
  """
  @spec dominates?(GenServer.server(), Commit.t(), binary()) :: boolean()
  def dominates?(store, %Commit{} = commit, target_id) when is_binary(target_id) do
    initial = [commit.parent_id | commit.merge_parents] |> Enum.reject(&is_nil/1)
    walk(store, initial, target_id, MapSet.new())
  end

  defp walk(_store, [], _target, _visited), do: false

  defp walk(store, [id | rest], target, visited) do
    cond do
      id == target ->
        true

      MapSet.member?(visited, id) ->
        walk(store, rest, target, visited)

      true ->
        visited = MapSet.put(visited, id)

        case CommitStoreClient.get_commit(store, id) do
          {:ok, %Commit{} = c} ->
            next =
              [c.parent_id | c.merge_parents]
              |> Enum.reject(&is_nil/1)
              |> Enum.reject(&MapSet.member?(visited, &1))

            walk(store, next ++ rest, target, visited)

          _ ->
            walk(store, rest, target, visited)
        end
    end
  end

  defp emit_adopted(commit, prev_latest) do
    :telemetry.execute(
      [:commonplace, :sync, :merge_adopted],
      %{system_time: System.system_time()},
      %{
        commit_id: commit.id,
        doc_uuid: commit.doc_uuid,
        prev_latest: prev_latest
      }
    )
  end
end
