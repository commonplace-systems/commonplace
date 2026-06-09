defmodule Commonplace.Sync.NodeSync do
  @moduledoc """
  Per-document sync between BEAM nodes.

  Handles commit-ID (CID) set diffing and commit exchange for catch-up
  sync. Steady-state sync is handled by Phoenix PubSub broadcasts.

  ## Late-edit auto-translation (CX-7cm1)

  A peer can author an edit against a *stale* version of a document — one
  whose snapshot parent (its *epoch*) the rest of the cluster has already
  moved past by taking a newer snapshot. Imported as-is, such a *late
  edit* references item identities that no longer exist in the current
  epoch, so it would fail to apply cleanly or be silently dropped. The
  fix is to re-express (*translate*) the edit into the current epoch
  first.

  This module performs that translation at the sync boundary — where
  cross-epoch commits arrive from other nodes — by funneling every
  incoming commit through `import_with_translation/3`, which invokes
  `Commonplace.LateEditAutoTranslator.maybe_auto_translate/3` (the
  CX-atk3 primitive that owns the actual translation mechanism) before
  calling `CommitStoreClient.import_commit/2`.

  Branch matrix (per commonplace-plan msg 2282):

  - `:no_translation_needed` → import original as-is.
  - `:translated` / `:fallback` → import the translated replacement;
    the stale cross-epoch original is dropped.
  - `:skipped` → import original AND emit
    `[:commonplace, :late_edit, :auto_skip_stored]` so the divergence
    is observable rather than silent.

  Default `fallback: true` per design — cross-epoch peers should
  auto-recover; the caller can disable with `fallback: false`.

  ## Merge adoption (CX-8k1v)

  After an import succeeds, `MergeAdopter.maybe_adopt/2` opportunistically
  advances `:latest` to the imported commit iff the commit is a merge
  whose ancestor DAG dominates the current local `:latest`. Lets peers
  that only receive merges (never invoke one locally) converge on the
  merge head autonomously. Non-merge imports and non-dominating merges
  are no-ops. See `Commonplace.Sync.MergeAdopter` for the design
  rationale and alternative (c) that was considered and not taken.
  """

  alias Commonplace.LateEditAutoTranslator
  alias Commonplace.Store.Commit
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Store.CommitStore
  alias Commonplace.Sync.MergeAdopter

  require Logger

  @doc """
  Diff two CID sets, returning {missing_local, missing_remote}.

  missing_local: IDs the remote has that we don't (we need to fetch these).
  missing_remote: IDs we have that the remote doesn't (we should send these).
  """
  def diff_commit_ids(local_ids, remote_ids) do
    missing_local = MapSet.difference(remote_ids, local_ids)
    missing_remote = MapSet.difference(local_ids, remote_ids)
    {missing_local, missing_remote}
  end

  @doc """
  Perform catch-up sync for a document with a remote node.

  1. Get local CID set
  2. Get remote CID set (via GenServer.call to remote CommitStore)
  3. Diff
  4. Fetch missing commits from remote, store locally via import_commit
  5. Send missing commits to remote via import_commit
  """
  def catch_up(doc_uuid, remote_node, local_store \\ CommitStore) do
    local_ids = CommitStoreClient.commit_ids_for_doc(local_store, doc_uuid)

    remote_ids =
      GenServer.call({CommitStore, remote_node}, {:commit_ids_for_doc, doc_uuid})

    {missing_local, missing_remote} = diff_commit_ids(local_ids, remote_ids)

    # Fetch commits we're missing from remote
    fetched =
      missing_local
      |> Enum.map(fn id ->
        GenServer.call({CommitStore, remote_node}, {:get_commit, id})
      end)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, commit} -> commit end)

    # Store fetched commits locally (import_commit avoids clobbering :latest).
    # Route through import_with_translation so cross-epoch peers auto-recover
    # instead of silently dropping edits written against stale snapshots.
    Enum.each(fetched, fn commit ->
      import_with_translation(local_store, commit)
    end)

    # Send commits the remote is missing
    missing_commits =
      missing_remote
      |> Enum.map(fn id ->
        CommitStoreClient.get_commit(local_store, id)
      end)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, commit} -> commit end)

    Enum.each(missing_commits, fn commit ->
      GenServer.call({CommitStore, remote_node}, {:import_commit, commit})
    end)

    Logger.debug(
      "NodeSync catch_up #{doc_uuid}: fetched #{length(fetched)}, sent #{length(missing_commits)}"
    )

    {:ok, %{fetched: length(fetched), sent: length(missing_commits)}}
  end

  @doc """
  Import a commit, auto-translating if it was written against a stale
  snapshot parent (CX-7cm1).

  Dispatches to `LateEditAutoTranslator.maybe_auto_translate/3` and
  then imports whichever commit best matches local state:

  - `{:ok, :no_translation_needed}` → import `commit` unchanged.
  - `{:ok, :translated, c}` / `{:ok, :fallback, c}` → import `c`
    instead of `commit` (the cross-epoch original is dropped).
  - `{:ok, :skipped, reason}` → import `commit` AND emit
    `[:commonplace, :late_edit, :auto_skip_stored]` so the divergence
    is observable. Preserves existing pre-primitive behavior (commit
    is still visible downstream) while naming the failure mode.

  Returns the `CommitStoreClient.import_commit/2` result.
  """
  @spec import_with_translation(GenServer.server(), Commit.t(), keyword()) :: term()
  def import_with_translation(store \\ CommitStore, commit, opts \\ []) do
    case LateEditAutoTranslator.maybe_auto_translate(store, commit, opts) do
      {:ok, :no_translation_needed} ->
        result = CommitStoreClient.import_commit(store, commit)
        _ = MergeAdopter.maybe_adopt(store, commit)
        result

      {:ok, kind, translated} when kind in [:translated, :fallback] ->
        result = CommitStoreClient.import_commit(store, translated)
        _ = MergeAdopter.maybe_adopt(store, translated)
        result

      {:ok, :skipped, reason} ->
        emit_auto_skip_stored(commit, reason)
        result = CommitStoreClient.import_commit(store, commit)
        _ = MergeAdopter.maybe_adopt(store, commit)
        result
    end
  end

  defp emit_auto_skip_stored(commit, reason) do
    :telemetry.execute(
      [:commonplace, :late_edit, :auto_skip_stored],
      %{system_time: System.system_time()},
      %{edit_hash: commit.id, reason: reason}
    )
  end
end
