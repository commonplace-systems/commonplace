defmodule Commonplace.Store.CommitStoreClient do
  @moduledoc """
  Dispatches CommitStore calls to either a remote serve node or the local GenServer.

  When `commonplace serve` is running, CLI commands connect to its BEAM node
  and call CommitStore remotely. When serve is not running, calls go to the
  local CommitStore (which must have been started by the CLI).
  """

  alias Commonplace.Store.CommitStore

  def create_commit(doc_uuid, update, parent_id) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:create_commit, doc_uuid, update, parent_id})

      :local ->
        CommitStore.create_commit(doc_uuid, update, parent_id)
    end
  end

  def get_commit(commit_id) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:get_commit, commit_id})

      :local ->
        CommitStore.get_commit(commit_id)
    end
  end

  def latest_commit(doc_uuid) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:latest_commit, doc_uuid})

      :local ->
        CommitStore.latest_commit(doc_uuid)
    end
  end

  def commit_log(doc_uuid, opts \\ []) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:commit_log, doc_uuid, opts})

      :local ->
        CommitStore.commit_log(doc_uuid, opts)
    end
  end

  def is_ancestor?(ancestor_id, descendant_id) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:is_ancestor, ancestor_id, descendant_id})

      :local ->
        CommitStore.is_ancestor?(ancestor_id, descendant_id)
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
