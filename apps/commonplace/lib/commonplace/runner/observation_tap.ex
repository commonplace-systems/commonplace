defmodule Commonplace.Runner.ObservationTap do
  @moduledoc """
  Host-side, one-way observation of a runner pod checkout.

  The tap polls the host-visible checkout and writes its state into a fresh
  Commonplace tree. It deliberately uses `Commonplace.Sync.Watcher`, whose
  only mutation direction is disk to CRDT. It never starts a `DirAgent` or an
  `EntryAgent`, so no observation-root commit can materialize in the pod.

  Every write uses the runner's explicit signing context and observation
  metadata. Remote-only changes are overwritten or removed from the mirror on
  the next pass and are returned under the named `:ignored` result.
  """

  use GenServer

  require Logger

  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Sync.Watcher
  alias Commonplace.Tree.Schema

  @default_interval_ms 1_000

  @type sync_report :: %{
          inbound: :none | {:ignored, [String.t()]},
          outbound: [String.t()],
          watcher: map()
        }

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Run one poll synchronously. Remote-to-checkout changes are named as ignored."
  @spec sync_now(pid()) :: {:ok, sync_report()} | {:error, term()}
  def sync_now(pid), do: GenServer.call(pid, :sync_now, 60_000)

  @doc "Return the fresh observation tree root UUID."
  @spec root_uuid(pid()) :: String.t()
  def root_uuid(pid), do: GenServer.call(pid, :root_uuid)

  @doc "Stop a tap after one final best-effort poll and apply its retention policy."
  @spec unregister(pid(), keyword()) :: :ok
  def unregister(pid, opts \\ []) do
    retain? = Keyword.get(opts, :retain, false)
    GenServer.call(pid, {:unregister, retain?}, 60_000)
  catch
    :exit, _reason -> :ok
  end

  @doc "The host registry path for `/pods/<deployment-id>/live`."
  @spec descriptor_path(Path.t(), String.t()) :: Path.t()
  def descriptor_path(registry_root, deployment_id) do
    Path.join([registry_root, "pods", deployment_id, "live", "observation.json"])
  end

  @doc "Remove an unretained stale deployment registration when no tap process survived."
  @spec reap_stale(Path.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def reap_stale(registry_root, deployment_id, opts \\ []) do
    if Keyword.get(opts, :retain, false) do
      :ok
    else
      deployment_path = Path.join([registry_root, "pods", deployment_id])

      case File.rm_rf(deployment_path) do
        {:ok, _removed} -> :ok
        {:error, reason, path} -> {:error, {:observation_reap_failed, path, reason}}
      end
    end
  end

  @impl true
  def init(opts) do
    checkout_dir = Keyword.fetch!(opts, :checkout_dir)
    deployment_id = Keyword.fetch!(opts, :deployment_id)
    sha = Keyword.fetch!(opts, :sha)
    store = Keyword.get(opts, :store, CommitStoreClient)
    signing_context = Keyword.fetch!(opts, :signing_context)
    registry_root = Keyword.fetch!(opts, :registry_root)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    exclude_names = Keyword.get(opts, :exclude_names, [".git", ".commonplace"])
    root_uuid = UUID.uuid4()
    path = "/pods/#{deployment_id}/live"
    metadata = observation_metadata(deployment_id, sha, path)
    root_update = Schema.new_schema() |> Yelixer.Encoding.encode_update()

    with %Commonplace.Store.Commit{} <-
           CommitStoreClient.create_commit(
             store,
             root_uuid,
             root_update,
             nil,
             metadata,
             signing_context: signing_context
           ),
         :ok <-
           write_descriptor(registry_root, deployment_id, %{
             "deployment-id" => deployment_id,
             "harvest" => "not-yet-harvested",
             "path" => path,
             "root-uuid" => root_uuid,
             "sha" => sha,
             "verification" => "UNVERIFIED WORKING STATE",
             "witness" => "runner-witnessed"
           }) do
      state = %{
        checkout_dir: checkout_dir,
        deployment_id: deployment_id,
        exclude_names: exclude_names,
        interval_ms: interval_ms,
        metadata: metadata,
        registry_root: registry_root,
        root_uuid: root_uuid,
        signing_context: signing_context,
        snapshot: %{},
        store: store
      }

      schedule_poll(interval_ms)
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
      other -> {:stop, {:observation_root_create_failed, other}}
    end
  end

  @impl true
  def handle_call(:root_uuid, _from, state), do: {:reply, state.root_uuid, state}

  def handle_call(:sync_now, _from, state) do
    {reply, state} = safe_sync(state)
    {:reply, reply, state}
  end

  def handle_call({:unregister, retain?}, _from, state) do
    {_reply, state} = safe_sync(state)
    result = reap_stale(state.registry_root, state.deployment_id, retain: retain?)
    {:stop, :normal, result, state}
  end

  @impl true
  def handle_info(:poll, state) do
    {_reply, state} = safe_sync(state)
    schedule_poll(state.interval_ms)
    {:noreply, state}
  end

  defp safe_sync(state) do
    do_sync(state)
  rescue
    error ->
      Logger.warning(
        "observation tap poll failed without affecting pod " <>
          "(deployment_id=#{state.deployment_id}): #{Exception.message(error)}"
      )

      {{:error, {:observation_tap_failed, Exception.message(error)}}, state}
  catch
    kind, reason ->
      Logger.warning(
        "observation tap poll failed without affecting pod " <>
          "(deployment_id=#{state.deployment_id}): #{inspect({kind, reason})}"
      )

      {{:error, {:observation_tap_failed, {kind, reason}}}, state}
  end

  defp do_sync(state) do
    current_snapshot = disk_snapshot(state.checkout_dir, state.exclude_names)

    changes =
      detect_tree_changes(
        state.root_uuid,
        state.checkout_dir,
        state.store,
        state.exclude_names
      )

    {inbound, outbound} =
      Enum.reduce(changes, {[], []}, fn {relative_path, change}, {ignored, outgoing} ->
        if outgoing_change?(relative_path, change, state.snapshot, current_snapshot) do
          {ignored, [relative_path | outgoing]}
        else
          {[relative_path | ignored], outgoing}
        end
      end)

    watcher =
      Watcher.sync_recursive(state.root_uuid, state.checkout_dir, state.store,
        signing_context: state.signing_context,
        commit_metadata: state.metadata,
        exclude_names: state.exclude_names
      )

    ignored = Enum.sort(Enum.uniq(inbound))
    outgoing = Enum.sort(Enum.uniq(outbound))

    report = %{
      inbound: if(ignored == [], do: :none, else: {:ignored, ignored}),
      outbound: outgoing,
      watcher: watcher
    }

    {{:ok, report}, %{state | snapshot: current_snapshot}}
  end

  defp outgoing_change?(path, %{type: type}, previous, current)
       when type in [:created, :modified] do
    Map.get(previous, path) != Map.get(current, path)
  end

  defp outgoing_change?(path, %{type: :deleted}, previous, _current),
    do: Map.has_key?(previous, path)

  defp outgoing_change?(_path, %{type: :renamed}, _previous, _current), do: true

  defp detect_tree_changes(root_uuid, dir, store, exclude_names),
    do: detect_tree_changes(root_uuid, dir, store, exclude_names, "")

  defp detect_tree_changes(root_uuid, dir, store, exclude_names, prefix) do
    changes =
      root_uuid
      |> Watcher.detect_changes(dir, store, exclude_names: exclude_names)
      |> Enum.map(fn change -> {join_relative(prefix, change.name), change} end)

    child_changes =
      case Commonplace.Tree.DocBuilder.reconstruct_snapshot(store, root_uuid) do
        {:ok, doc} ->
          doc
          |> Schema.list_entries()
          |> Enum.filter(&(&1.type == :dir))
          |> Enum.flat_map(fn entry ->
            child_dir = Path.join(dir, entry.name)

            if File.dir?(child_dir) do
              detect_tree_changes(
                entry.node_id,
                child_dir,
                store,
                exclude_names,
                join_relative(prefix, entry.name)
              )
            else
              []
            end
          end)

        :none ->
          []
      end

    changes ++ child_changes
  end

  defp disk_snapshot(root, exclude_names) do
    excluded = MapSet.new(exclude_names)

    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&File.dir?/1)
    |> Enum.reject(fn path ->
      path
      |> Path.relative_to(root)
      |> Path.split()
      |> List.first()
      |> then(&MapSet.member?(excluded, &1))
    end)
    |> Map.new(fn path ->
      relative = Path.relative_to(path, root)
      value = if File.regular?(path), do: {:file, file_digest(path)}, else: {:other, nil}
      {relative, value}
    end)
  end

  defp file_digest(path) do
    path
    |> File.stream!([], 64 * 1024)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
  end

  defp join_relative("", name), do: name
  defp join_relative(prefix, name), do: Path.join(prefix, name)

  defp observation_metadata(deployment_id, sha, path) do
    %{
      kind: :observation,
      witness: "runner-witnessed",
      verification: "UNVERIFIED WORKING STATE",
      harvest: "not-yet-harvested",
      deployment_id: deployment_id,
      sha: sha,
      path: path
    }
  end

  defp write_descriptor(registry_root, deployment_id, descriptor) do
    path = descriptor_path(registry_root, deployment_id)
    temp = "#{path}.#{System.unique_integer([:positive, :monotonic])}.tmp"

    try do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(temp, Jason.encode!(descriptor)),
           :ok <- File.rename(temp, path) do
        :ok
      end
    after
      _ = File.rm(temp)
    end
  end

  defp schedule_poll(interval_ms), do: Process.send_after(self(), :poll, interval_ms)
end
