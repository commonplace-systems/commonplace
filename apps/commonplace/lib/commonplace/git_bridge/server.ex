defmodule Commonplace.GitBridge.Server do
  @moduledoc """
  One GenServer per mount-uuid -> repo_dir mapping. Owns the periodic
  export/commit/push cycle described in GitBridge G1.

  Every tick (`:tick` from a real timer, or synchronously via
  `sync_now/1`):

    1. If paused, no-op.
    2. Check reachability: is `mount_uuid` still resolvable from the
       workspace root (`Commonplace.Workspace.root_uuid/0`)? If not,
       halt — never export/commit an orphaned mount — and broadcast a
       red `:halted` event. Reachability is re-checked every tick so a
       schema re-link clears the halt automatically.
    3. `Exporter.export/4` the tree, `Sidecar.write/4` +
       `Sidecar.ensure_gitattributes/1`.
    4. If the working tree is dirty, `Git.commit_all/2`; if a remote is
       configured, `Git.push/3` too. Push failures are swallowed (with
       a broadcast) — the server stays alive and retries next cycle.

  Never crashes on git or push failure; `Logger.warning` and continue.
  """

  use GenServer
  require Logger

  alias Commonplace.GitBridge.{Exporter, Sidecar, Git, Archive}
  alias Commonplace.Tree.{Schema, DocBuilder}
  alias Commonplace.Dataflow.PubSub
  alias Commonplace.{Presence, Workspace}

  @default_branch "main"
  @default_interval_ms 30_000
  @max_reachability_depth 20
  @remote_name "origin"

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Pause the bridge: ticks become no-ops until `resume/1`."
  def pause(server), do: GenServer.call(server, :pause)

  @doc "Resume a paused bridge."
  def resume(server), do: GenServer.call(server, :resume)

  @doc "Run one export/commit/push cycle synchronously. Returns `{:ok, result} | {:error, reason}`."
  def sync_now(server), do: GenServer.call(server, :sync_now, 60_000)

  @doc "Return `%{paused:, halted:, last_manifest_size:, mount_uuid:, repo_dir:}`."
  def status(server), do: GenServer.call(server, :status)

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    mount_uuid = Keyword.fetch!(opts, :mount_uuid)
    repo_dir = Keyword.fetch!(opts, :repo_dir)
    store = Keyword.fetch!(opts, :store)
    remote = Keyword.get(opts, :remote)
    branch = Keyword.get(opts, :branch, @default_branch)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    :ok = ensure_repo!(repo_dir, branch, remote)

    presence_uuid = safe_create_presence(mount_uuid, store)

    state = %{
      mount_uuid: mount_uuid,
      repo_dir: repo_dir,
      store: store,
      remote: remote,
      branch: branch,
      interval_ms: interval_ms,
      paused: false,
      halted: false,
      presence_uuid: presence_uuid,
      last_manifest: nil
    }

    schedule_tick(interval_ms)

    PubSub.broadcast_red(mount_uuid, {:git_bridge, :started, %{repo_dir: repo_dir}})

    {:ok, state}
  end

  @impl true
  def handle_call(:pause, _from, state) do
    PubSub.broadcast_red(state.mount_uuid, {:git_bridge, :paused, %{repo_dir: state.repo_dir}})
    {:reply, :ok, %{state | paused: true}}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    PubSub.broadcast_red(state.mount_uuid, {:git_bridge, :resumed, %{repo_dir: state.repo_dir}})
    {:reply, :ok, %{state | paused: false}}
  end

  @impl true
  def handle_call(:sync_now, _from, state) do
    {result, new_state} = do_tick(state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      paused: state.paused,
      halted: state.halted,
      last_manifest_size: manifest_size(state.last_manifest),
      mount_uuid: state.mount_uuid,
      repo_dir: state.repo_dir,
      presence_uuid: state.presence_uuid
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {_result, new_state} = do_tick(state)
    schedule_tick(new_state.interval_ms)
    {:noreply, new_state}
  end

  # --- Tick logic ---

  defp do_tick(%{paused: true} = state), do: {{:ok, :paused}, state}

  defp do_tick(state) do
    if reachable?(state.mount_uuid, state.store) do
      state = %{state | halted: false}
      run_cycle(state)
    else
      state = %{state | halted: true}
      PubSub.broadcast_red(state.mount_uuid, {:git_bridge, :halted, %{reason: :unreachable}})
      {{:ok, :halted}, state}
    end
  end

  defp run_cycle(state) do
    previous_manifest = state.last_manifest || Sidecar.read_previous_manifest(state.repo_dir)

    case Exporter.export(state.mount_uuid, state.repo_dir, state.store, previous_manifest) do
      {:ok, %{manifest: manifest, authors: authors, warnings: warnings, schema_uuids: schema_uuids}} ->
        Sidecar.write(state.repo_dir, state.mount_uuid, manifest, previous_manifest)
        Sidecar.ensure_gitattributes(state.repo_dir)

        # G1.5 (CX-b0ow.4): archive rows land in the SAME git commit as
        # the content they back, so this runs after Sidecar.write and
        # before the commit step below.
        doc_uuids =
          manifest
          |> Map.values()
          |> Enum.map(& &1.uuid)
          |> MapSet.new()
          |> MapSet.union(schema_uuids)

        %{archived_count: archived_count} = Archive.archive(state.store, state.repo_dir, doc_uuids)

        result = commit_and_push(state, manifest, authors, warnings, archived_count)

        {result, %{state | last_manifest: manifest}}

      {:error, reason} ->
        Logger.warning("GitBridge.Server: export failed for #{state.mount_uuid}: #{inspect(reason)}")
        {{:error, reason}, state}
    end
  end

  defp commit_and_push(state, manifest, authors, warnings, archived_count) do
    case Git.dirty?(state.repo_dir) do
      {:ok, true} ->
        case Git.commit_all(state.repo_dir, authors: authors) do
          {:ok, sha} ->
            meta = %{
              sha: sha,
              warnings: warnings,
              manifest_size: map_size(manifest),
              archived_count: archived_count
            }

            PubSub.broadcast_red(state.mount_uuid, {:git_bridge, :committed, meta})
            maybe_push(state, meta)
            {:ok, Map.put(meta, :committed, true)}

          {:error, reason} ->
            Logger.warning("GitBridge.Server: commit failed for #{state.mount_uuid}: #{inspect(reason)}")
            {:error, reason}
        end

      {:ok, false} ->
        {:ok,
         %{
           committed: false,
           manifest_size: map_size(manifest),
           warnings: warnings,
           archived_count: archived_count
         }}

      {:error, reason} ->
        Logger.warning("GitBridge.Server: git status failed for #{state.mount_uuid}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp maybe_push(%{remote: nil}, _meta), do: :ok

  defp maybe_push(%{remote: remote, branch: branch, repo_dir: repo_dir, mount_uuid: mount_uuid}, meta)
       when is_binary(remote) do
    case Git.push(repo_dir, @remote_name, branch) do
      {:ok, _} ->
        PubSub.broadcast_red(mount_uuid, {:git_bridge, :pushed, meta})

      {:error, reason} ->
        Logger.warning("GitBridge.Server: push failed for #{mount_uuid}: #{inspect(reason)}")
        PubSub.broadcast_red(mount_uuid, {:git_bridge, :push_failed, Map.put(meta, :reason, reason)})
    end

    :ok
  end

  # --- Setup helpers ---

  defp ensure_repo!(repo_dir, branch, remote) do
    :ok = Git.ensure_repo(repo_dir, branch)

    if is_binary(remote) do
      # Idempotent: ignore "remote already exists" style errors.
      _ = Git.add_remote(repo_dir, @remote_name, remote)
    end

    :ok
  end

  defp safe_create_presence(mount_uuid, store) do
    case Presence.create("git-bridge", :bot, mount_uuid, store) do
      {:ok, uuid} ->
        _ = Presence.set_activity(uuid, "idle", store)
        uuid

      other ->
        Logger.warning("GitBridge.Server: could not create presence doc for #{mount_uuid}: #{inspect(other)}")
        nil
    end
  rescue
    error ->
      Logger.warning("GitBridge.Server: presence creation raised for #{mount_uuid}: #{inspect(error)}")
      nil
  end

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp manifest_size(nil), do: 0
  defp manifest_size(manifest), do: map_size(manifest)

  # --- Reachability ---

  defp reachable?(mount_uuid, store) do
    case Workspace.root_uuid() do
      {:ok, ^mount_uuid} -> true
      {:ok, root_uuid} -> bfs_reachable?(root_uuid, mount_uuid, store, @max_reachability_depth)
      {:error, _} -> false
    end
  end

  defp bfs_reachable?(_current_uuid, _target, _store, 0), do: false

  defp bfs_reachable?(current_uuid, target, store, depth) do
    current_uuid
    |> load_schema(store)
    |> Schema.list_entries()
    |> Enum.filter(&(&1.type == :dir))
    |> Enum.any?(fn entry ->
      entry.node_id == target or bfs_reachable?(entry.node_id, target, store, depth - 1)
    end)
  end

  defp load_schema(uuid, store) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end
end
