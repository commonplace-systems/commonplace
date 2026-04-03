defmodule Commonplace.Sync.NodeSync do
  @moduledoc """
  Per-document sync between BEAM nodes.

  Handles CID set diffing and commit exchange for catch-up sync.
  Steady-state sync is handled by Phoenix PubSub broadcasts.
  """

  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Store.CommitStore

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

    # Store fetched commits locally (import_commit avoids clobbering :latest)
    Enum.each(fetched, fn commit ->
      CommitStoreClient.import_commit(local_store, commit)
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
end
