defmodule Commonplace.Process.Orchestrator do
  @moduledoc """
  Watches __processes.json and manages Elixir process lifecycle.

  Periodically reads the __processes.json CRDT doc, diffs against
  the current running state, and starts/stops/restarts processes
  to match the declared configuration.

  Each Elixir process is compiled from a source .exs document in
  the CRDT tree and started as a supervised GenServer.
  """

  use GenServer

  @shutdown_grace_ms 5000

  alias Commonplace.Process.Config
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType
  alias Commonplace.Dataflow.Wiring
  alias Commonplace.Dataflow.GraphRegistry

  require Logger

  @max_propagation_depth 8

  defstruct [:root_uuid, :store, :interval, :processes, :current_config, :source_hashes, :started_at]

  defmodule ProcessInfo do
    @moduledoc "Info about a managed process."
    defstruct [:pid, :mode, :sandbox_dir, :os_pid, :started_at, :scope_uuid, :wiring_info, :resolved_ports]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Get the map of running process names to pids."
  def running_processes(pid) do
    GenServer.call(pid, :running_processes)
  end

  @doc "Get detailed info about all running processes."
  def process_info(pid) do
    GenServer.call(pid, :process_info)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      root_uuid: Keyword.fetch!(opts, :root_uuid),
      store: Keyword.get(opts, :store, CommitStoreClient),
      interval: Keyword.get(opts, :interval, 5000),
      processes: %{},
      current_config: [],
      source_hashes: %{},
      started_at: DateTime.utc_now()
    }

    schedule_reconcile(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:running_processes, _from, state) do
    pids = Map.new(state.processes, fn {name, info} -> {name, info.pid} end)
    {:reply, pids, state}
  end

  @impl true
  def handle_call(:process_info, _from, state) do
    info = Map.new(state.processes, fn {name, proc} ->
      {name, %{
        pid: proc.pid,
        mode: proc.mode,
        sandbox_dir: proc.sandbox_dir,
        os_pid: get_os_pid(proc),
        started_at: proc.started_at,
        alive: Process.alive?(proc.pid)
      }}
    end)

    {:reply, info, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    state =
      try do
        reconcile(state)
      rescue
        e ->
          Logger.error("Orchestrator reconcile failed: #{Exception.message(e)}")
          state
      end

    write_status_file(state)
    schedule_reconcile(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:commit, uuid, commit_id, meta}, state) do
    depth = Map.get(meta, :depth, 0)

    if depth <= @max_propagation_depth do
      dispatch_to_processes(uuid, commit_id, meta, state)
    end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Collect os_pids first, then kill all managed processes
    os_pids =
      state.processes
      |> Enum.map(fn {_name, info} -> get_os_pid(info) end)
      |> Enum.reject(&is_nil/1)

    # SIGTERM the individual process and its children.
    # Avoids process-group kills (kill -- -PID) which could affect
    # the BEAM or unrelated processes sharing the same group.
    Enum.each(os_pids, fn pid ->
      System.cmd("kill", ["-TERM", "#{pid}"], stderr_to_stdout: true)
      System.cmd("pkill", ["-TERM", "-P", "#{pid}"], stderr_to_stdout: true)
    end)

    # Wait for graceful shutdown only when there are OS processes to kill
    if os_pids != [] do
      Process.sleep(@shutdown_grace_ms)
    end

    # SIGKILL any survivors
    Enum.each(os_pids, fn pid ->
      System.cmd("kill", ["-9", "#{pid}"], stderr_to_stdout: true)
      System.cmd("pkill", ["-9", "-P", "#{pid}"], stderr_to_stdout: true)
    end)

    # Stop BEAM wrappers
    Enum.each(state.processes, fn {_name, info} ->
      try do
        if Process.alive?(info.pid), do: GenServer.stop(info.pid, :shutdown, 2000)
      catch
        :exit, _ -> :ok
      end
    end)

    # Clean up PID and status files
    pid_file = pid_file_path(state)
    File.rm(pid_file)
    remove_status_file()

    :ok
  end

  defp reconcile(state) do
    start_time = System.monotonic_time()

    new_config = read_processes_config(state)
    diff = Config.diff(state.current_config, new_config)

    source_changes = detect_source_changes(state, new_config)

    # Source-only changes (no config change) get hot reload;
    # config changes still need cold restart.
    hot_reload_candidates = source_changes -- diff.changed

    config_map = Map.new(new_config, &{&1.name, &1})

    {state, failed_hot} = hot_reload_processes(state, hot_reload_candidates, config_map)

    # Config changes + failed hot reloads get cold restart
    all_cold = Enum.uniq(diff.changed ++ failed_hot)

    state = stop_processes(state, diff.removed ++ all_cold)
    state = start_processes(state, diff.added ++ all_cold, new_config)

    :telemetry.execute(
      [:commonplace, :orchestrator, :reconcile],
      %{duration: System.monotonic_time() - start_time},
      %{
        added: length(diff.added),
        removed: length(diff.removed),
        changed: length(all_cold),
        total: map_size(state.processes)
      }
    )

    %{state | current_config: new_config}
  end

  defp stop_processes(state, names) do
    Enum.reduce(names, state, fn name, acc ->
      case Map.get(acc.processes, name) do
        nil ->
          acc

        %ProcessInfo{pid: pid, wiring_info: wiring_info} ->
          # Unwire PubSub subscriptions and remove graph edges before stopping
          if wiring_info, do: Wiring.unwire(wiring_info)
          GraphRegistry.remove_edges(name)

          if Process.alive?(pid), do: GenServer.stop(pid, :shutdown, 5000)

          :telemetry.execute(
            [:commonplace, :process, :stop],
            %{system_time: System.system_time()},
            %{name: name}
          )

          %{acc | processes: Map.delete(acc.processes, name)}
      end
    end)
  end

  defp start_processes(state, names, config_list) do
    config_map = Map.new(config_list, &{&1.name, &1})

    Enum.reduce(names, state, fn name, acc ->
      case Map.get(config_map, name) do
        nil ->
          acc

        config ->
          case start_process(config, acc) do
            {:ok, pid, source_hash} ->
              {wiring_info, resolved_ports} = wire_ports(name, config, acc)

              info = %ProcessInfo{
                pid: pid,
                mode: config.mode,
                sandbox_dir: get_sandbox_dir(pid, config.mode),
                started_at: DateTime.utc_now(),
                scope_uuid: config.scope_uuid,
                wiring_info: wiring_info,
                resolved_ports: resolved_ports
              }

              :telemetry.execute(
                [:commonplace, :process, :start],
                %{system_time: System.system_time()},
                %{name: name, mode: config.mode}
              )

              %{acc |
                processes: Map.put(acc.processes, name, info),
                source_hashes: Map.put(acc.source_hashes, name, source_hash)
              }

            {:error, _reason} ->
              acc
          end
      end
    end)
  end

  defp hot_reload_processes(state, names, config_map) do
    Enum.reduce(names, {state, []}, fn name, {acc, failed} ->
      config = Map.get(config_map, name)
      proc = Map.get(acc.processes, name)

      if config && config.mode == :elixir && proc && Process.alive?(proc.pid) do
        case hot_reload_module(config, acc) do
          {:ok, source_hash} ->
            {%{acc | source_hashes: Map.put(acc.source_hashes, name, source_hash)}, failed}

          {:error, _reason} ->
            {acc, [name | failed]}
        end
      else
        # Not eligible for hot reload — fall back to cold restart
        {acc, [name | failed]}
      end
    end)
  end

  defp hot_reload_module(config, state) do
    case read_source(config.source, state) do
      {:ok, source_code, source_hash} ->
        module_name = module_for(config.name)

        try do
          # Purge any lingering old version so BEAM can accept a new one.
          # :code.purge/1 removes the "old" version of a module; it's safe
          # here because our running process is on the "current" version.
          :code.purge(module_name)

          # compile_string loads the new version — the current version
          # becomes "old", and the running GenServer will pick up the new
          # callbacks on its next fully-qualified call (which GenServer
          # does for every handle_call/handle_info/etc.).
          Code.compile_string(source_code)
          {:ok, source_hash}
        rescue
          e -> {:error, e}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_process(%Config{mode: :elixir} = config, state) do
    case read_source(config.source, state) do
      {:ok, source_code, source_hash} ->
        try do
          Code.compile_string(source_code)

          module_name = module_for(config.name)

          init_opts = [
            store: state.store,
            root_uuid: state.root_uuid,
            name: config.name,
            config: %{
              "source" => config.source,
              "owns" => config.owns,
              "restart" => Atom.to_string(config.restart),
              "depends_on" => config.depends_on
            }
          ]

          # Use start (not start_link) to avoid linking child to orchestrator
          case GenServer.start(module_name, init_opts) do
            {:ok, pid} -> {:ok, pid, source_hash}
            error -> {:error, error}
          end
        rescue
          e -> {:error, e}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_process(%Config{mode: :sandbox_exec} = config, state) do
    try do
      # Use scope_uuid if set (subdirectory sandbox), otherwise full tree
      sandbox_uuid = config.scope_uuid || state.root_uuid

      {:ok, pid} = Commonplace.Process.SandboxExecRunner.start_link(
        root_uuid: sandbox_uuid,
        store: state.store,
        command: config.command,
        args: config.args,
        name: config.name,
        env: config.env,
        sync_interval: 50
      )

      Process.unlink(pid)
      {:ok, pid, nil}
    rescue
      e -> {:error, e}
    end
  end

  defp detect_source_changes(state, new_config) do
    Enum.flat_map(new_config, fn config ->
      if Map.has_key?(state.processes, config.name) && Map.get(state.processes, config.name) do
        case read_source(config.source, state) do
          {:ok, _code, hash} ->
            old_hash = Map.get(state.source_hashes, config.name)
            if old_hash != nil and old_hash != hash, do: [config.name], else: []

          _ ->
            []
        end
      else
        []
      end
    end)
  end

  defp read_source(filename, state) do
    root_doc = load_schema(state.root_uuid, state.store)

    case Schema.get_entry(root_doc, filename) do
      {:ok, entry} ->
        case CommitStoreClient.latest_commit(state.store, entry.node_id) do
          {:ok, commit} ->
            doc = Yelixer.Doc.new()
            {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
            content = ContentType.get_content(doc) || ""
            hash = :erlang.md5(content)
            {:ok, content, hash}

          :none ->
            {:error, :no_commit}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp read_processes_config(state) do
    collect_processes_recursive(state.root_uuid, state.root_uuid, state.store)
  end

  # Walk the tree recursively, collecting __processes.json from each directory.
  # Processes found at root get scope_uuid=nil (full tree).
  # Processes found in subdirectories get scope_uuid=that directory's UUID.
  defp collect_processes_recursive(dir_uuid, root_uuid, store) do
    dir_doc = load_schema(dir_uuid, store)
    entries = Schema.list_entries(dir_doc)

    # Check for __processes.json in this directory
    local_configs = case Schema.get_entry(dir_doc, "__processes.json") do
      {:ok, entry} -> parse_processes_doc(entry.node_id, dir_uuid, root_uuid, store)
      :error -> []
    end

    # Recurse into subdirectories
    sub_configs = Enum.flat_map(entries, fn entry ->
      if entry.type == :dir do
        collect_processes_recursive(entry.node_id, root_uuid, store)
      else
        []
      end
    end)

    local_configs ++ sub_configs
  end

  defp parse_processes_doc(doc_uuid, dir_uuid, root_uuid, store) do
    case CommitStoreClient.latest_commit(store, doc_uuid) do
      {:ok, commit} ->
        doc = Yelixer.Doc.new()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        content = ContentType.get_content(doc) || "{}"

        # scope_uuid is nil for root (full tree), or the dir UUID for subdirectories
        scope = if dir_uuid == root_uuid, do: nil, else: dir_uuid

        case Jason.decode(content) do
          {:ok, json} -> Config.parse(json, scope)
          {:error, _} -> []
        end

      :none ->
        []
    end
  end

  defp module_for(name) do
    camel = name |> Macro.camelize()
    Module.concat([Commonplace.UserProcess, camel])
  end

  defp load_schema(uuid, store) do
    case CommitStoreClient.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end

  defp get_sandbox_dir(pid, :sandbox_exec) do
    try do
      Commonplace.Process.SandboxExecRunner.sandbox_dir(pid)
    catch
      _, _ -> nil
    end
  end

  defp get_sandbox_dir(_pid, _mode), do: nil

  defp get_os_pid(%ProcessInfo{pid: pid, mode: :sandbox_exec}) do
    try do
      Commonplace.Process.SandboxExecRunner.os_pid(pid)
    catch
      _, _ -> nil
    end
  end

  defp get_os_pid(_), do: nil

  defp pid_file_path(_state) do
    data_dir = Application.get_env(:commonplace, :data_dir, "data")
    Path.join(data_dir, "orchestrator.pid")
  end

  defp write_status_file(state) do
    data_dir = Application.get_env(:commonplace, :data_dir, "data")
    status_file = Path.join(data_dir, "orchestrator_status.json")
    tmp_file = status_file <> ".tmp"

    status = %{
      "pid" => System.pid(),
      "started_at" => DateTime.to_iso8601(state.started_at),
      "updated_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "processes" => Map.new(state.processes, fn {name, proc} ->
        {name, %{
          "mode" => to_string(proc.mode),
          "sandbox_dir" => proc.sandbox_dir,
          "os_pid" => get_os_pid(proc),
          "started_at" => DateTime.to_iso8601(proc.started_at),
          "alive" => Process.alive?(proc.pid)
        }}
      end)
    }

    File.write!(tmp_file, Jason.encode!(status, pretty: true))
    File.rename!(tmp_file, status_file)
  rescue
    _ -> :ok
  end

  defp remove_status_file do
    data_dir = Application.get_env(:commonplace, :data_dir, "data")
    File.rm(Path.join(data_dir, "orchestrator_status.json"))
  end

  # --- Port Wiring ---

  defp wire_ports(name, config, state) do
    module_name = module_for(name)

    if config.mode == :elixir and
         Code.ensure_loaded?(module_name) and
         function_exported?(module_name, :__ports__, 0) do
      ports = module_name.__ports__()
      scope_uuid = config.scope_uuid || state.root_uuid

      context = [
        root_uuid: scope_uuid,
        repo_root_uuid: state.root_uuid,
        tree_root_uuid: state.root_uuid,
        loader: &load_schema(&1, state.store)
      ]

      resolved = Wiring.resolve_ports(ports, context)
      wiring_info = Wiring.wire(ports, resolved)
      edges = Wiring.build_edges(name, ports, resolved)
      GraphRegistry.add_edges(name, edges)

      {wiring_info, resolved}
    else
      {nil, %{}}
    end
  end

  defp dispatch_to_processes(uuid, commit_id, _meta, state) do
    Enum.each(state.processes, fn {name, %ProcessInfo{pid: pid, resolved_ports: resolved_ports, wiring_info: wiring_info}} ->
      if Process.alive?(pid) && resolved_ports && wiring_info do
        # Check if this uuid matches any blue input (including cyan-implied blue)
        blue_uuids = Map.get(wiring_info, :blue_uuids, MapSet.new())

        if MapSet.member?(blue_uuids, uuid) do
          # Find which docref(s) map to this uuid
          refs =
            Enum.flat_map(resolved_ports, fn {ref, resolved_uuid} ->
              if resolved_uuid == uuid, do: [ref], else: []
            end)

          Enum.each(refs, fn ref ->
            try do
              # Reconstruct the doc from the latest commit
              case CommitStoreClient.get_commit(state.store, commit_id) do
                {:ok, commit} ->
                  doc = Yelixer.Doc.new()
                  {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
                  module_name = module_for(name)

                  if function_exported?(module_name, :handle_blue, 2) do
                    module_name.handle_blue(ref, doc)
                  end

                _ ->
                  :ok
              end
            rescue
              e ->
                Logger.warning("Error dispatching commit to #{name}/#{ref}: #{inspect(e)}")
            end
          end)
        end
      end
    end)
  end

  defp schedule_reconcile(state) do
    Process.send_after(self(), :reconcile, state.interval)
  end
end
