defmodule Commonplace.Store.CommitStoreClient do
  @moduledoc """
  Dispatches CommitStore calls to either a remote serve node or the local GenServer.

  When `commonplace serve` is running, CLI commands connect to its BEAM node
  and call CommitStore remotely. When serve is not running, calls go to the
  local CommitStore (which must have been started by the CLI).

  Provides the same API as CommitStore so it can be used as a drop-in
  replacement. The `server` argument is normalized: if it's this module
  (from CLI alias), it's mapped to the real CommitStore. Otherwise it's
  passed through (for tests with custom store instances).
  """

  alias Commonplace.Store.CommitStore

  defp normalize_server(__MODULE__), do: CommitStore
  defp normalize_server(server), do: server

  def create_commit(server \\ CommitStore, doc_uuid, update, parent_id) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:create_commit, doc_uuid, update, parent_id})

      :local ->
        CommitStore.create_commit(normalize_server(server), doc_uuid, update, parent_id)
    end
  end

  def create_chained_commit(server \\ CommitStore, doc_uuid, update) do
    case remote_node() do
      {:ok, node} ->
        parent_id = case GenServer.call({CommitStore, node}, {:latest_commit, doc_uuid}) do
          {:ok, commit} -> commit.id
          :none -> nil
        end
        GenServer.call({CommitStore, node}, {:create_commit, doc_uuid, update, parent_id})

      :local ->
        CommitStore.create_chained_commit(normalize_server(server), doc_uuid, update)
    end
  end

  def get_commit(server \\ CommitStore, commit_id) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:get_commit, commit_id})

      :local ->
        CommitStore.get_commit(normalize_server(server), commit_id)
    end
  end

  def latest_commit(server \\ CommitStore, doc_uuid) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:latest_commit, doc_uuid})

      :local ->
        CommitStore.latest_commit(normalize_server(server), doc_uuid)
    end
  end

  def commit_log(server \\ CommitStore, doc_uuid, opts \\ []) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:commit_log, doc_uuid, opts})

      :local ->
        CommitStore.commit_log(normalize_server(server), doc_uuid, opts)
    end
  end

  def all_doc_uuids(server \\ CommitStore) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, :all_doc_uuids)

      :local ->
        CommitStore.all_doc_uuids(normalize_server(server))
    end
  end

  def is_ancestor?(server \\ CommitStore, ancestor_id, descendant_id) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:is_ancestor, ancestor_id, descendant_id})

      :local ->
        CommitStore.is_ancestor?(normalize_server(server), ancestor_id, descendant_id)
    end
  end

  @doc """
  Check if we're connected to a remote serve node.
  Returns `{:ok, node}` if connected, `:local` otherwise.
  """
  def remote_node do
    case Process.get(:commonplace_remote_node) do
      nil -> :local
      node -> {:ok, node}
    end
  end

  @doc """
  Set the remote node for the current process.
  Called by CLI.ensure_started when it connects to a running serve.
  """
  def set_remote_node(node) do
    Process.put(:commonplace_remote_node, node)
  end
end
