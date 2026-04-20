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

  def create_commit(server \\ CommitStore, doc_uuid, update, parent_id, metadata \\ %{}) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:create_commit, doc_uuid, update, parent_id, metadata})

      :local ->
        CommitStore.create_commit(normalize_server(server), doc_uuid, update, parent_id, metadata)
    end
  end

  def create_chained_commit(server \\ CommitStore, doc_uuid, update, metadata \\ %{}) do
    case remote_node() do
      {:ok, node} ->
        parent_id = case GenServer.call({CommitStore, node}, {:latest_commit, doc_uuid}) do
          {:ok, commit} -> commit.id
          :none -> nil
        end
        GenServer.call({CommitStore, node}, {:create_commit, doc_uuid, update, parent_id, metadata})

      :local ->
        CommitStore.create_chained_commit(normalize_server(server), doc_uuid, update, metadata)
    end
  end

  @doc """
  Pass-through for `CommitStore.snapshot/2` (CX-u7p / CX-2ok0).

  Forces an umbrella-shaped snapshot commit for `doc_uuid` regardless
  of the chain-length / size threshold. Routed via the local CommitStore
  GenServer; remote-serve dispatch is not yet wired (snapshot construction
  requires a multi-step build that's awkward to round-trip through a
  single GenServer call), so callers in remote mode currently need to
  invoke `CommitStore.snapshot/2` directly on the serve node.
  """
  def snapshot(server \\ CommitStore, doc_uuid) do
    CommitStore.snapshot(normalize_server(server), doc_uuid)
  end

  @doc """
  Pass-through for `CommitStore.create_snapshot_commit/4` (CX-u7p).
  Mirrors the local/remote dispatch pattern used for every other write.
  """
  def create_snapshot_commit(server \\ CommitStore, doc_uuid, update, metadata \\ %{}) do
    metadata = Map.put(metadata, :kind, :snapshot)

    case remote_node() do
      {:ok, node} ->
        parent_id =
          case GenServer.call({CommitStore, node}, {:latest_commit, doc_uuid}) do
            {:ok, commit} -> commit.id
            :none -> nil
          end

        GenServer.call(
          {CommitStore, node},
          {:create_commit, doc_uuid, update, parent_id, metadata}
        )

      :local ->
        CommitStore.create_snapshot_commit(normalize_server(server), doc_uuid, update, metadata)
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

  def set_latest(server \\ CommitStore, doc_uuid, commit_id) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:set_latest, doc_uuid, commit_id})

      :local ->
        CommitStore.set_latest(normalize_server(server), doc_uuid, commit_id)
    end
  end

  def commit_ids_for_doc(server \\ CommitStore, doc_uuid) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:commit_ids_for_doc, doc_uuid})

      :local ->
        CommitStore.commit_ids_for_doc(normalize_server(server), doc_uuid)
    end
  end

  def import_commit(server \\ CommitStore, commit) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:import_commit, commit})

      :local ->
        CommitStore.import_commit(normalize_server(server), commit)
    end
  end

  def find_common_ancestor(server \\ CommitStore, uuid_a, uuid_b) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:find_common_ancestor, uuid_a, uuid_b})

      :local ->
        CommitStore.find_common_ancestor(normalize_server(server), uuid_a, uuid_b)
    end
  end

  def set_merge_point(server \\ CommitStore, target_uuid, source_uuid, commit_id) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:set_merge_point, target_uuid, source_uuid, commit_id})

      :local ->
        CommitStore.set_merge_point(normalize_server(server), target_uuid, source_uuid, commit_id)
    end
  end

  def get_merge_point(server \\ CommitStore, target_uuid, source_uuid) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:get_merge_point, target_uuid, source_uuid})

      :local ->
        CommitStore.get_merge_point(normalize_server(server), target_uuid, source_uuid)
    end
  end

  def set_last_merge_commit(server \\ CommitStore, target_uuid, source_uuid, commit_id) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:set_last_merge_commit, target_uuid, source_uuid, commit_id})

      :local ->
        CommitStore.set_last_merge_commit(normalize_server(server), target_uuid, source_uuid, commit_id)
    end
  end

  def get_latest_merge_head(server \\ CommitStore, target_uuid) do
    case remote_node() do
      {:ok, node} ->
        GenServer.call({CommitStore, node}, {:get_latest_merge_head, target_uuid})

      :local ->
        CommitStore.get_latest_merge_head(normalize_server(server), target_uuid)
    end
  end

  @doc """
  Check if we're connected to a remote serve node.
  Returns `{:ok, node}` if connected, `:local` otherwise.

  Routing is stored in `:persistent_term` so it is visible from every
  process on the BEAM (not just the one that called `set_remote_node/1`).
  This matters for the MCP server, which spawns helper GenServers
  (e.g. `Presence.Server`) that need to see the same routing the
  escript main process configured.
  """
  def remote_node do
    case :persistent_term.get(:commonplace_remote_node, nil) do
      nil -> :local
      node -> {:ok, node}
    end
  end

  @doc """
  Set the remote node node-wide. Called by CLI.ensure_started and the
  MCP escript bootstrap when they connect to a running serve.
  """
  def set_remote_node(node) do
    :persistent_term.put(:commonplace_remote_node, node)
  end

  @doc """
  Clear the remote node setting node-wide. Primarily for tests; in
  production the escript exits and persistent_term goes away with the
  BEAM.
  """
  def clear_remote_node do
    _ = :persistent_term.erase(:commonplace_remote_node)
    :ok
  end
end
