defmodule Commonplace.Store.CommitStore do
  @moduledoc """
  CubDB-backed persistent storage for the commit Merkle DAG.
  """

  use GenServer

  alias Commonplace.Store.Commit

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def create_commit(doc_uuid, update, parent_id) do
    GenServer.call(__MODULE__, {:create_commit, doc_uuid, update, parent_id})
  end

  def get_commit(commit_id) do
    GenServer.call(__MODULE__, {:get_commit, commit_id})
  end

  def latest_commit(doc_uuid) do
    GenServer.call(__MODULE__, {:latest_commit, doc_uuid})
  end

  @impl true
  def init(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    path = Path.join(data_dir, "commits")
    File.mkdir_p!(Path.dirname(path))
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
end
