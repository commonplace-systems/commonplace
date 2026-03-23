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

  @doc "Walk the commit chain for a doc, returning commits newest-first."
  def commit_log(server \\ __MODULE__, doc_uuid, opts \\ []) do
    GenServer.call(server, {:commit_log, doc_uuid, opts})
  end

  @doc "Return a MapSet of all document UUIDs that have a `:latest` entry."
  def all_doc_uuids(server \\ __MODULE__) do
    GenServer.call(server, :all_doc_uuids)
  end

  @doc "Check if `ancestor_id` is an ancestor of `descendant_id` in the commit DAG."
  def is_ancestor?(server \\ __MODULE__, ancestor_id, descendant_id) do
    GenServer.call(server, {:is_ancestor, ancestor_id, descendant_id})
  end

  @doc "Point a UUID at an existing commit without creating a new one."
  def set_latest(server \\ __MODULE__, doc_uuid, commit_id) do
    GenServer.call(server, {:set_latest, doc_uuid, commit_id})
  end

  @doc "Find the most recent common ancestor between two UUID chains."
  def find_common_ancestor(server \\ __MODULE__, uuid_a, uuid_b) do
    GenServer.call(server, {:find_common_ancestor, uuid_a, uuid_b})
  end

  @doc "Store the commit ID of the source at the time of a merge, for incremental merging."
  def set_merge_point(server \\ __MODULE__, target_uuid, source_uuid, commit_id) do
    GenServer.call(server, {:set_merge_point, target_uuid, source_uuid, commit_id})
  end

  @doc "Retrieve the stored merge point commit ID for a (target, source) pair."
  def get_merge_point(server \\ __MODULE__, target_uuid, source_uuid) do
    GenServer.call(server, {:get_merge_point, target_uuid, source_uuid})
  end

  @doc "Record the commit ID of the last merge-created commit on a target UUID."
  def set_last_merge_commit(server \\ __MODULE__, target_uuid, commit_id) do
    GenServer.call(server, {:set_last_merge_commit, target_uuid, commit_id})
  end

  @doc "Get the commit ID of the last merge-created commit on a target UUID."
  def get_last_merge_commit(server \\ __MODULE__, target_uuid) do
    GenServer.call(server, {:get_last_merge_commit, target_uuid})
  end

  @impl true
  def init(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    path = Path.join(data_dir, "commits")
    File.mkdir_p!(path)

    case open_cubdb(path) do
      {:ok, db} ->
        case probe_integrity(db) do
          :ok ->
            {:ok, %{db: db}}

          {:error, reason} ->
            require Logger
            Logger.warning("CubDB corrupt on probe (#{inspect(reason)}). Archiving and starting fresh.")
            CubDB.stop(db)
            recover_cubdb(path)
        end

      {:error, reason} ->
        require Logger
        Logger.warning("CubDB failed to open (#{inspect(reason)}). Archiving and starting fresh.")
        recover_cubdb(path)
    end
  end

  defp open_cubdb(path) do
    # Trap exits so CubDB init crashes don't kill us
    old_trap = Process.flag(:trap_exit, true)

    result =
      try do
        CubDB.start_link(
          data_dir: path,
          auto_file_sync: true,
          auto_compact: true
        )
      rescue
        e -> {:error, e}
      catch
        :exit, reason -> {:error, reason}
        kind, reason -> {:error, {kind, reason}}
      end

    # Drain any EXIT message from the failed CubDB process
    receive do
      {:EXIT, _pid, _reason} -> :ok
    after
      0 -> :ok
    end

    Process.flag(:trap_exit, old_trap)
    result
  end

  defp recover_cubdb(path) do
    archive_corrupt_db(path)

    {:ok, db} =
      CubDB.start_link(
        data_dir: path,
        auto_file_sync: true,
        auto_compact: true
      )

    {:ok, %{db: db}}
  end

  @impl true
  def handle_call({:create_commit, doc_uuid, update, parent_id}, _from, state) do
    commit = Commit.new(doc_uuid, update, parent_id)

    CubDB.put_multi(state.db, [
      {{:commit, commit.id}, commit},
      {{:latest, doc_uuid}, commit.id}
    ])

    :telemetry.execute(
      [:commonplace, :commit, :create],
      %{system_time: System.system_time()},
      %{doc_uuid: doc_uuid}
    )

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
  def handle_call({:commit_log, doc_uuid, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)

    case CubDB.get(state.db, {:latest, doc_uuid}) do
      nil ->
        {:reply, [], state}

      commit_id ->
        log = collect_log(state.db, commit_id, limit, [])
        {:reply, log, state}
    end
  end

  @impl true
  def handle_call(:all_doc_uuids, _from, state) do
    uuids =
      CubDB.select(state.db,
        min_key: {:latest, ""},
        max_key: {:latest, <<255>>}
      )
      |> Enum.map(fn {{:latest, uuid}, _commit_id} -> uuid end)

    {:reply, MapSet.new(uuids), state}
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

  @impl true
  def handle_call({:set_latest, doc_uuid, commit_id}, _from, state) do
    CubDB.put(state.db, {:latest, doc_uuid}, commit_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:find_common_ancestor, uuid_a, uuid_b}, _from, state) do
    ids_a = collect_commit_ids(state.db, uuid_a)
    result = walk_to_ancestor(state.db, uuid_b, ids_a)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:set_merge_point, target_uuid, source_uuid, commit_id}, _from, state) do
    CubDB.put(state.db, {:merge_point, target_uuid, source_uuid}, commit_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_merge_point, target_uuid, source_uuid}, _from, state) do
    result = CubDB.get(state.db, {:merge_point, target_uuid, source_uuid})
    {:reply, result, state}
  end

  @impl true
  def handle_call({:set_last_merge_commit, target_uuid, commit_id}, _from, state) do
    CubDB.put(state.db, {:last_merge_commit, target_uuid}, commit_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_last_merge_commit, target_uuid}, _from, state) do
    result = CubDB.get(state.db, {:last_merge_commit, target_uuid})
    {:reply, result, state}
  end

  defp collect_commit_ids(db, doc_uuid) do
    case CubDB.get(db, {:latest, doc_uuid}) do
      nil -> MapSet.new()
      commit_id -> collect_ids(db, commit_id, MapSet.new())
    end
  end

  defp collect_ids(_db, nil, acc), do: acc

  defp collect_ids(db, commit_id, acc) do
    acc = MapSet.put(acc, commit_id)

    case CubDB.get(db, {:commit, commit_id}) do
      nil -> acc
      commit -> collect_ids(db, commit.parent_id, acc)
    end
  end

  defp walk_to_ancestor(db, doc_uuid, ancestor_ids) do
    case CubDB.get(db, {:latest, doc_uuid}) do
      nil -> :none
      commit_id -> find_in_chain(db, commit_id, ancestor_ids)
    end
  end

  defp find_in_chain(_db, nil, _ids), do: :none

  defp find_in_chain(db, commit_id, ancestor_ids) do
    if MapSet.member?(ancestor_ids, commit_id) do
      {:ok, CubDB.get(db, {:commit, commit_id})}
    else
      case CubDB.get(db, {:commit, commit_id}) do
        nil -> :none
        commit -> find_in_chain(db, commit.parent_id, ancestor_ids)
      end
    end
  end

  defp collect_log(_db, nil, _limit, acc), do: Enum.reverse(acc)
  defp collect_log(_db, _id, 0, acc), do: Enum.reverse(acc)

  defp collect_log(db, commit_id, limit, acc) do
    case CubDB.get(db, {:commit, commit_id}) do
      nil -> Enum.reverse(acc)
      commit -> collect_log(db, commit.parent_id, limit - 1, [commit | acc])
    end
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

  defp probe_integrity(db) do
    try do
      # Read a small slice — forces CubDB to touch the data file
      CubDB.select(db, min_key: :_, max_key: :_, pipe: [take: 1])
      :ok
    rescue
      e -> {:error, e}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp archive_corrupt_db(path) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    archive_path = "#{path}.corrupt.#{timestamp}"
    File.rename!(path, archive_path)
    File.mkdir_p!(path)
  end
end
