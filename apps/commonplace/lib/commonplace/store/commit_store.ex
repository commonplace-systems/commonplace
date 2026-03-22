defmodule Commonplace.Store.CommitStore do
  @moduledoc """
  CubDB-backed persistent storage for the commit Merkle DAG.
  """

  use GenServer

  alias Commonplace.Store.Commit

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def create_commit(server \\ __MODULE__, doc_uuid, update, parent_id) do
    GenServer.call(server, {:create_commit, doc_uuid, update, parent_id})
  end

  def get_commit(server \\ __MODULE__, commit_id) do
    GenServer.call(server, {:get_commit, commit_id})
  end

  def latest_commit(server \\ __MODULE__, doc_uuid) do
    GenServer.call(server, {:latest_commit, doc_uuid})
  end

  @doc "Check if `ancestor_id` is an ancestor of `descendant_id` in the commit DAG."
  def is_ancestor?(server \\ __MODULE__, ancestor_id, descendant_id) do
    GenServer.call(server, {:is_ancestor, ancestor_id, descendant_id})
  end

  @impl true
  def init(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    path = Path.join(data_dir, "commits")
    File.mkdir_p!(path)
    {:ok, db} = CubDB.start_link(data_dir: path)
    {:ok, %{db: db}}
  end

  @impl true
  def handle_call({:create_commit, doc_uuid, update, parent_id}, _from, state) do
    commit = Commit.new(doc_uuid, update, parent_id)
    CubDB.put(state.db, {:commit, commit.id}, commit)
    CubDB.put(state.db, {:latest, doc_uuid}, commit.id)
    {:reply, commit, state}
  end

  @impl true
  def handle_call({:get_commit, commit_id}, _from, state) do
    case CubDB.get(state.db, {:commit, commit_id}) do
      nil -> {:reply, :none, state}
      commit -> {:reply, {:ok, commit}, state}
    end
  end

  @impl true
  def handle_call({:latest_commit, doc_uuid}, _from, state) do
    case CubDB.get(state.db, {:latest, doc_uuid}) do
      nil ->
        {:reply, :none, state}

      commit_id ->
        commit = CubDB.get(state.db, {:commit, commit_id})
        {:reply, {:ok, commit}, state}
    end
  end

  @impl true
  def handle_call({:is_ancestor, nil, _descendant_id}, _from, state) do
    {:reply, false, state}
  end

  @impl true
  def handle_call({:is_ancestor, ancestor_id, descendant_id}, _from, state) do
    result = walk_ancestors(state.db, ancestor_id, descendant_id)
    {:reply, result, state}
  end

  defp walk_ancestors(_db, _ancestor_id, nil), do: false

  defp walk_ancestors(db, ancestor_id, current_id) do
    case CubDB.get(db, {:commit, current_id}) do
      nil ->
        false

      commit ->
        cond do
          commit.parent_id == ancestor_id -> true
          commit.parent_id == nil -> false
          true -> walk_ancestors(db, ancestor_id, commit.parent_id)
        end
    end
  end
end
