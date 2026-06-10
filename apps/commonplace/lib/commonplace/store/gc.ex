defmodule Commonplace.Store.GC do
  @moduledoc """
  Garbage collection — **detection only**. Finds orphaned documents:
  those present in the CommitStore but not reachable from a given root.

  It walks the schema tree from the root, collects every reachable UUID,
  and subtracts that from the set of all document UUIDs in the store; the
  remainder are orphans. `find_orphans/2` returns the `{reachable,
  orphaned}` MapSets; `report/2` wraps them with counts.

  **Nothing is ever deleted.** The CommitStore is append-only (data is
  never removed), so "GC" here means *identifying* unreferenced docs —
  for auditing, debugging dangling references, or a future external
  archival step — not reclaiming their space. And an orphan is only
  orphaned relative to the root you pass: a doc reachable from a
  *different* root that wasn't supplied still shows up as an orphan here.
  """

  alias Commonplace.Tree.Walk
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStoreClient

  @doc """
  Find orphaned document UUIDs — documents in the store that are not
  reachable from the given root UUID.

  Returns `{reachable, orphaned}` where both are MapSets.
  """
  def find_orphans(root_uuid, store \\ CommitStoreClient) do
    loader = fn uuid ->
      case CommitStoreClient.latest_commit(store, uuid) do
        {:ok, commit} ->
          doc = Schema.new_schema()
          {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
          doc

        :none ->
          Schema.new_schema()
      end
    end

    reachable = Walk.reachable_uuids(root_uuid, loader)
    all_uuids = CommitStoreClient.all_doc_uuids(store)
    orphaned = MapSet.difference(all_uuids, reachable)

    {reachable, orphaned}
  end

  @doc """
  Report orphaned documents without deleting anything.
  Returns a map with stats and the orphan UUIDs.
  """
  def report(root_uuid, store \\ CommitStoreClient) do
    {reachable, orphaned} = find_orphans(root_uuid, store)

    %{
      reachable_count: MapSet.size(reachable),
      orphaned_count: MapSet.size(orphaned),
      orphaned_uuids: orphaned
    }
  end
end
