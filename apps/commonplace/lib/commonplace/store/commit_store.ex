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

  def create_commit(server \\ __MODULE__, doc_uuid, update, parent_id, metadata \\ %{}) do
    GenServer.call(server, {:create_commit, doc_uuid, update, parent_id, metadata})
  end

  @doc "Create a commit that automatically chains to the latest commit on this UUID."
  def create_chained_commit(server \\ __MODULE__, doc_uuid, update, metadata \\ %{}) do
    parent_id = case latest_commit(server, doc_uuid) do
      {:ok, commit} -> commit.id
      :none -> nil
    end
    create_commit(server, doc_uuid, update, parent_id, metadata)
  end

  @doc """
  Create a snapshot commit (CX-u7p compaction primitive).

  Chains normally to the latest commit so replication walks back through
  history as usual, but tags the commit metadata with `kind: :snapshot`.
  Readers that know about snapshots (see `DocBuilder.reconstruct_doc/2`)
  short-circuit the backward walk on hitting one and apply only the
  snapshot plus any newer commits chained on top.

  The snapshot's `update` payload should be a self-contained Yjs update
  encoding the full materialized observable state under a single
  client_id (see `Yelixer.Doc.snapshot_update/1`). Applied to a fresh
  `Doc.new()`, it must reproduce the source doc's observable content.
  """
  def create_snapshot_commit(server \\ __MODULE__, doc_uuid, update, metadata \\ %{}) do
    metadata = Map.put(metadata, :kind, :snapshot)

    parent_id = case latest_commit(server, doc_uuid) do
      {:ok, commit} -> commit.id
      :none -> nil
    end

    create_commit(server, doc_uuid, update, parent_id, metadata)
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

  @doc "Return a MapSet of all commit IDs for a document (walks the chain)."
  def commit_ids_for_doc(server \\ __MODULE__, doc_uuid) do
    GenServer.call(server, {:commit_ids_for_doc, doc_uuid})
  end

  @doc """
  Idempotently stamp the deterministic genesis commit for `doc_uuid`
  (CX-fzi). Returns `{:ok, genesis}`.

  Genesis is a pure function of `doc_uuid` (see `Commit.genesis/1`), so
  two calls for the same uuid return the same commit and store to the
  same id. `:latest` is NOT touched — callers wire genesis in as the
  parent of the first real commit themselves (deferred to the bead that
  flips on namespace validation). This is the primitive; auto-wiring
  into `create_commit` is explicitly out of scope for CX-fzi.
  """
  def ensure_genesis(server \\ __MODULE__, doc_uuid) do
    GenServer.call(server, {:ensure_genesis, doc_uuid})
  end

  @doc """
  Store a commit without updating :latest. Used for catch-up sync.

  Accepts an optional `:validator` keyword function of arity 1 that
  receives the incoming commit and returns `:ok | {:error, reason}`.
  When rejected, the commit is NOT persisted and `:latest` is NOT
  modified (CX-bv3). The default validator is a no-op stub that
  accepts every commit; CX-ch5 replaces the default with the real
  Yelixer namespace-membership check once the primitive lands.
  """
  def import_commit(server \\ __MODULE__, commit, opts \\ []) do
    GenServer.call(server, {:import_commit, commit, opts})
  end

  @doc """
  Legacy pass-through — retained for back-compat.

  Prior to CX-ch5 this was the default validator; the real default is
  now `Commonplace.Store.Namespace.validate_commit_from_db/2`, invoked
  directly from `handle_call({:import_commit, ...})` with the state's
  CubDB handle. Callers that still pass this function explicitly via
  `validator:` get stub pass-through behavior, matching the pre-swap
  contract.
  """
  def default_namespace_validator(_commit), do: :ok

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

  @doc "Record the target's head commit after any merge (keyed by target+source and target-only)."
  def set_last_merge_commit(server \\ __MODULE__, target_uuid, source_uuid, commit_id) do
    GenServer.call(server, {:set_last_merge_commit, target_uuid, source_uuid, commit_id})
  end

  @doc "Get the target's head commit after the most recent merge from any source."
  def get_latest_merge_head(server \\ __MODULE__, target_uuid) do
    GenServer.call(server, {:get_latest_merge_head, target_uuid})
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
  def handle_call({:create_commit, doc_uuid, update, parent_id, metadata}, _from, state) do
    parent_id = maybe_stamp_genesis(state.db, doc_uuid, parent_id)
    commit = Commit.new(doc_uuid, update, parent_id, metadata) |> maybe_sign_commit()

    CubDB.put_multi(state.db, [
      {{:commit, commit.id}, commit},
      {{:latest, doc_uuid}, commit.id}
    ])

    :telemetry.execute(
      [:commonplace, :commit, :create],
      %{system_time: System.system_time()},
      %{doc_uuid: doc_uuid}
    )

    Phoenix.PubSub.broadcast(Commonplace.PubSub, "commits:#{doc_uuid}", {:commit, doc_uuid, commit.id, metadata})

    # Also broadcast on the blue:UUID topic so UI subscribers (WikiLive,
    # TreeLive) see live updates from CommandRouter-initiated writes (MCP,
    # CLI) — not just edits that already flow through Document.Server.
    # CX-4im. Eventually the blue/commits topic duality should be unified;
    # see the CX-4im notes for the refactor plan.
    Phoenix.PubSub.broadcast(Commonplace.PubSub, "blue:#{doc_uuid}", {:commit, doc_uuid, commit.id, metadata})

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
  def handle_call({:commit_ids_for_doc, doc_uuid}, _from, state) do
    ids = collect_commit_ids(state.db, doc_uuid)
    {:reply, ids, state}
  end

  @impl true
  def handle_call({:ensure_genesis, doc_uuid}, _from, state) do
    genesis = Commit.genesis(doc_uuid)
    CubDB.put(state.db, {:commit, genesis.id}, genesis)
    {:reply, {:ok, genesis}, state}
  end

  @impl true
  def handle_call({:import_commit, commit}, from, state) do
    handle_call({:import_commit, commit, []}, from, state)
  end

  @impl true
  def handle_call({:import_commit, commit, opts}, _from, state) do
    validator =
      Keyword.get(opts, :validator) ||
        fn c -> Commonplace.Store.Namespace.validate_commit_from_db(state.db, c) end

    case validator.(commit) do
      :ok ->
        case CubDB.get(state.db, {:commit, commit.id}) do
          nil ->
            # Store the commit. If no :latest exists for this doc, set it —
            # otherwise leave :latest alone (avoids clobbering a newer local head).
            case CubDB.get(state.db, {:latest, commit.doc_uuid}) do
              nil ->
                CubDB.put_multi(state.db, [
                  {{:commit, commit.id}, commit},
                  {{:latest, commit.doc_uuid}, commit.id}
                ])

              _existing_latest ->
                CubDB.put(state.db, {:commit, commit.id}, commit)
            end

            {:reply, :ok, state}

          _existing ->
            {:reply, :already_exists, state}
        end

      {:error, reason} ->
        :telemetry.execute(
          [:commonplace, :commit, :rejected, :namespace_mismatch],
          %{system_time: System.system_time()},
          %{
            commit_id: commit.id,
            doc_uuid: commit.doc_uuid,
            reason: reason
          }
        )

        {:reply, {:error, {:namespace_rejected, reason}}, state}
    end
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
  def handle_call({:set_last_merge_commit, target_uuid, source_uuid, commit_id}, _from, state) do
    CubDB.put(state.db, {:last_merge_commit, target_uuid, source_uuid}, commit_id)
    # Also store a target-only key so we can check "was this target merged from any source?"
    CubDB.put(state.db, {:latest_merge_head, target_uuid}, commit_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_latest_merge_head, target_uuid}, _from, state) do
    result = CubDB.get(state.db, {:latest_merge_head, target_uuid})
    {:reply, result, state}
  end

  @impl true
  def handle_call({:store_attestation, doc_uuid, attestation}, _from, state) do
    CubDB.put_multi(state.db, [
      {{:attestation, attestation.id}, attestation},
      {{:latest_attestation, doc_uuid}, attestation.id}
    ])

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:latest_attestation, doc_uuid}, _from, state) do
    case CubDB.get(state.db, {:latest_attestation, doc_uuid}) do
      nil ->
        {:reply, :none, state}

      att_id ->
        case CubDB.get(state.db, {:attestation, att_id}) do
          nil -> {:reply, :none, state}
          att -> {:reply, {:ok, att}, state}
        end
    end
  end

  @impl true
  def handle_call({:attestation_chain, doc_uuid, limit}, _from, state) do
    case CubDB.get(state.db, {:latest_attestation, doc_uuid}) do
      nil -> {:reply, [], state}
      att_id ->
        chain = collect_attestation_chain(state.db, att_id, limit, [])
        {:reply, chain, state}
    end
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

  defp collect_attestation_chain(_db, nil, _limit, acc), do: Enum.reverse(acc)
  defp collect_attestation_chain(_db, _id, 0, acc), do: Enum.reverse(acc)

  defp collect_attestation_chain(db, att_id, limit, acc) do
    case CubDB.get(db, {:attestation, att_id}) do
      nil -> Enum.reverse(acc)
      att -> collect_attestation_chain(db, att.prev_attestation_id, limit - 1, [att | acc])
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

  # CX-m3x: if a caller hands us `parent_id=nil` for a doc_uuid that
  # has never been written before, stamp the deterministic genesis and
  # use its id as the parent. Pre-umbrella docs with an existing :latest
  # retain legacy behavior (parent_id stays nil) — the write-side rule
  # so the read-side legacy hatch (empty metadata, no :kind) keeps
  # working without retroactive genesis insertions.
  defp maybe_stamp_genesis(_db, _doc_uuid, parent_id) when parent_id != nil, do: parent_id

  defp maybe_stamp_genesis(db, doc_uuid, nil) do
    case CubDB.get(db, {:latest, doc_uuid}) do
      nil ->
        genesis = Commit.genesis(doc_uuid)
        CubDB.put(db, {:commit, genesis.id}, genesis)
        genesis.id

      _existing ->
        nil
    end
  end

  defp maybe_sign_commit(commit) do
    case Process.whereis(Commonplace.Store.SecretStore) do
      nil ->
        commit

      _pid ->
        with {:ok, encoded_key} <- Commonplace.Store.SecretStore.get("signing_key:default"),
             {:ok, private_key} <- Base.decode64(encoded_key),
             {:ok, encoded_pub} <- Commonplace.Store.SecretStore.get("signing_pub:default"),
             {:ok, public_key} <- Base.decode64(encoded_pub) do
          # Get identity UUID if configured
          identity_uuid =
            case Commonplace.Store.SecretStore.get("signing_identity") do
              {:ok, uuid} -> uuid
              :not_found -> "anonymous"
            end

          signer_id = Commonplace.Crypto.Signing.signer_id(identity_uuid, public_key)
          Commonplace.Crypto.Signing.sign_commit(commit, private_key, signer_id)
        else
          _ -> commit
        end
    end
  end
end
