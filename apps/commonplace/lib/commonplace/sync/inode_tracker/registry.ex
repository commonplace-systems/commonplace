defmodule Commonplace.Sync.InodeTracker.Registry do
  @moduledoc """
  GenServer mapping inode keys to commit IDs.

  Each entry tracks: which commit's content is at this inode,
  which doc UUID it belongs to, the file path, and whether
  it's been shadowed (old inode preserved via hardlink).
  """

  use GenServer

  defmodule Entry do
    @moduledoc false
    defstruct [:commit_id, :doc_uuid, :path, :shadow_path, :fingerprint, shadowed: false]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Register an inode → commit_id mapping."
  def track(server, inode_key, commit_id, doc_uuid, path) do
    GenServer.call(server, {:track, inode_key, commit_id, doc_uuid, path})
  end

  @doc "Look up the mapping for an inode."
  def lookup(server, inode_key) do
    GenServer.call(server, {:lookup, inode_key})
  end

  @doc "Mark an inode as shadowed (old inode preserved via hardlink)."
  def shadow(server, inode_key, shadow_path, fingerprint \\ nil) do
    GenServer.call(server, {:shadow, inode_key, shadow_path, fingerprint})
  end

  @doc "List all shadowed entries."
  def list_shadows(server) do
    GenServer.call(server, :list_shadows)
  end

  @doc "Remove a shadow entry."
  def remove_shadow(server, inode_key) do
    GenServer.call(server, {:remove_shadow, inode_key})
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:track, inode_key, commit_id, doc_uuid, path}, _from, state) do
    entry = %Entry{commit_id: commit_id, doc_uuid: doc_uuid, path: path}
    {:reply, :ok, Map.put(state, inode_key, entry)}
  end

  @impl true
  def handle_call({:lookup, inode_key}, _from, state) do
    case Map.get(state, inode_key) do
      nil -> {:reply, :error, state}
      entry -> {:reply, {:ok, entry}, state}
    end
  end

  @impl true
  def handle_call({:shadow, inode_key, shadow_path, fingerprint}, _from, state) do
    case Map.get(state, inode_key) do
      nil ->
        {:reply, :error, state}

      entry ->
        entry = %{entry | shadowed: true, shadow_path: shadow_path, fingerprint: fingerprint}
        {:reply, :ok, Map.put(state, inode_key, entry)}
    end
  end

  @impl true
  def handle_call(:list_shadows, _from, state) do
    shadows =
      state
      |> Enum.filter(fn {_key, entry} -> entry.shadowed end)
      |> Enum.map(fn {_key, entry} -> entry end)

    {:reply, shadows, state}
  end

  @impl true
  def handle_call({:remove_shadow, inode_key}, _from, state) do
    {:reply, :ok, Map.delete(state, inode_key)}
  end
end
