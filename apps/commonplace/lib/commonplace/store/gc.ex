defmodule Commonplace.Store.GC do
  @moduledoc """
  Garbage collection: find orphaned documents not reachable from any root.

  Walks the schema tree from root, collects all reachable UUIDs, then
  compares against all document UUIDs in the CommitStore to find orphans.
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
