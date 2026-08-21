defmodule Commonplace.Store.CommitReader do
  @moduledoc """
  The cell-scoped read seam over commit history (BUILD-2a).

  Every read names its **cell**, and `cell_id` **is the existing doc-UUID**
  in shadow — no new identity type, no rewritten keys (pitch Phase 1 exit:
  *no stored commit or document identity is rewritten*). The physical CubDB
  layout is unchanged; the point of this module is that "which cell owns this
  read?" is always answerable at the call, so a later multi-database phase can
  route a read to the database that holds its cell.

  ## Why a reader, and why a guard

  This module is the *easy* half. It routes through
  `Commonplace.Store.CommitStoreClient` (the mandated dispatch seam) — it
  never touches CubDB directly. The half that makes the seam real is the
  source guard, `scripts/check_commonplace_cubdb_reads.exs`: it fails CI when
  product code reaches CubDB (or the `CommitStore.db_handle/1` escape hatch)
  outside the storage adapter. A chokepoint product code can bypass is
  decoration; the guard is what turns "we have a reader" into "reads *must*
  go through the reader."

  ## Cell scoping is load-bearing, not decorative

  `at/3` does not merely fetch a commit and label the call with a cell — it
  *enforces* that the named cell owns the commit, deciding ownership by the
  authoritative `{:doc_commit}` index (`CommitStore.doc_has_commit?/3`), NOT
  by the commit struct's `.doc_uuid` field. That field is a debug trace of
  the first writer, excluded from the content address and stale after forks /
  shared across convergent-genesis or imported ids (`commit.ex`). A commit
  addressed through the wrong cell is `:none`, not another cell's data.

  ## The functions (brief §3.1)

    * `history(cell_id, opts)`   — the cell's commit history (walks from :latest)
    * `heads(cell_id)`           — the durable accepted-head set for the cell
    * `at(cell_id, commit_id)`   — one addressed read, scoped to the cell
    * `inventory(cell_id, frontier)` — what this store has for the cell,
      WITHOUT enumerating the workspace (acceptance §5.3): a bounded per-cell
      `{:doc_commit}` range read, not a whole-store scan.

  Each takes an optional leading `store` (default `CommitStoreClient`) so
  tests can inject a named store instance; production omits it.
  """

  alias Commonplace.Store.CommitStoreClient

  @default_store CommitStoreClient

  @doc """
  The cell's commit history, newest first, walking back from `:latest`.
  `opts` are passed through to `CommitStoreClient.commit_log/3` (e.g.
  `:limit`). Delegates to the mandated dispatch seam; local/remote routing
  is handled there.
  """
  def history(cell_id, opts \\ []) when is_binary(cell_id) and is_list(opts),
    do: history(@default_store, cell_id, opts)

  def history(store, cell_id, opts) when is_binary(cell_id) and is_list(opts),
    do: CommitStoreClient.commit_log(store, cell_id, opts)

  @doc """
  The cell's durable accepted-head set (`{:ok, MapSet}` or `:none`) — a
  point-read of the incrementally maintained frontier
  (`CommitStore.accepted_heads_indexed/2`), no DAG walk.
  """
  def heads(store \\ @default_store, cell_id) when is_binary(cell_id),
    do: CommitStoreClient.accepted_heads_indexed(store, cell_id)

  @doc """
  One addressed read, scoped to `cell_id`: `{:ok, commit}` only if the cell
  authoritatively owns `commit_id` (by the `{:doc_commit}` index), otherwise
  `:none`. The cell is enforced, not merely recorded — see the module doc's
  "Cell scoping is load-bearing".
  """
  def at(store \\ @default_store, cell_id, commit_id)
      when is_binary(cell_id) and is_binary(commit_id) do
    if CommitStoreClient.doc_has_commit?(store, cell_id, commit_id) do
      CommitStoreClient.get_commit(store, commit_id)
    else
      :none
    end
  end

  @doc """
  What this store holds for `cell_id`, computed WITHOUT enumerating the
  workspace — a bounded per-cell `{:doc_commit}` range read
  (`CommitStore.all_commit_ids_for_doc/2`), never a whole-store scan
  (acceptance §5.3, the seam the later multi-database phases stand on).

  Returns `%{cell_id: cell_id, commit_ids: MapSet, delta: MapSet}` where
  `delta` is `commit_ids` minus `frontier` — "what I have that you don't."
  `frontier` (a MapSet or list of commit ids the requester already holds)
  defaults to empty, so `delta == commit_ids` reports the whole cell.
  """
  def inventory(cell_id, frontier \\ MapSet.new()) when is_binary(cell_id),
    do: inventory(@default_store, cell_id, frontier)

  def inventory(store, cell_id, frontier) when is_binary(cell_id) do
    frontier = to_set(frontier)
    commit_ids = CommitStoreClient.all_commit_ids_for_doc(store, cell_id)

    %{
      cell_id: cell_id,
      commit_ids: commit_ids,
      delta: MapSet.difference(commit_ids, frontier)
    }
  end

  defp to_set(%MapSet{} = set), do: set
  defp to_set(list) when is_list(list), do: MapSet.new(list)
end
