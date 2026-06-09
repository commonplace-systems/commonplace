defmodule Commonplace.Process.Orchestrator do
  @moduledoc """
  Runs live processes whose declarations *and* source code both live in
  the CRDT document tree.

  This is the substrate's "malleable software" engine. A running program
  is not deployed from outside; it is described by data inside the store.
  A `__processes.json` document declares *which* processes should be
  running and how they are wired, and (for in-BEAM processes) each one's
  *source code* is itself a `.exs` document in the same tree. Editing
  those documents — the same way you'd edit any other CRDT doc — changes
  what is actually running. This module is what makes that true: it
  watches those documents and bends the live system to match them.

  ## The reconcile loop (declarative convergence)

  Like a Kubernetes controller, the orchestrator does not apply changes
  imperatively. On a fixed interval (crash-isolated: a failed reconcile
  logs and retries next tick rather than taking the GenServer down) it:

  1. reads the *declared* config by collecting every `__processes.json`
     in the tree,
  2. diffs it against the *currently running* config (`Process.Config.diff`),
  3. and starts / stops / reloads processes until the two agree.

  The running system is therefore eventually-consistent with the
  documents, with no separate "deploy" step.

  ## Two kinds of process

  - `:elixir` — the source `.exs` document is compiled (via
    `Commonplace.Code.SourceDoc`) into a module and started as a
    GenServer *inside* this BEAM node.
  - `:sandbox_exec` — an external OS command run in a sandbox directory
    by `Process.SandboxExecRunner`, with `$secret:KEY` references in its
    env resolved from the node-local `Store.SecretStore` first.

  ## Hot reload vs cold restart

  Not every change requires a restart:

  - A change to a process's **config** (its declaration in
    `__processes.json`) requires a **cold restart** — stop the old
    instance, start a new one.
  - A change to *only* a process's **source code** (same declaration,
    edited `.exs`) triggers a **hot reload** for `:elixir` processes:
    recompile and replace the module in place, leaving the GenServer and
    its state intact. If a hot reload fails, the process falls back to
    a cold restart, so a bad edit never leaves stale code running.

  ## Where declarations come from (scoping)

  `read_processes_config/1` walks the whole tree recursively, gathering a
  `__processes.json` from *every* directory, not just the root. A
  process's `scope_uuid` records where it was found: `nil` for the root
  (it sees the full tree) or the directory's UUID for one declared in a
  subdirectory (it is scoped to that subtree). This lets a subdirectory
  carry its own self-contained set of processes.

  ## Ports and dataflow

  Processes are not islands: an `:elixir` process can declare `__ports__`
  — named inputs/outputs bound to documents in the tree. At start the
  orchestrator resolves those ports to concrete UUIDs, wires the
  corresponding PubSub subscriptions (`Dataflow.Wiring`), and registers
  the resulting edges in the `Dataflow.GraphRegistry` so the live wiring
  graph is observable. When a commit arrives on the *blue* channel
  (Commonplace's color-named convention for live document edits — the
  color vocabulary is owned by `Dataflow.Channel`) for a UUID that some
  process has bound as an input, `dispatch_to_processes/4` reconstructs
  the new document and hands it to that process's `handle_blue/2`.
  Because a process can react to a commit by writing one — which is
  itself a commit — propagation is depth-limited (`@max_propagation_depth`)
  to break runaway feedback loops.

  ## Lifecycle and isolation

  Managed processes are started with `GenServer.start` (not
  `start_link`): the orchestrator deliberately does *not* link to its
  children, so a crashing user process cannot cascade and take the
  orchestrator (and with it, all reconciliation) down. On shutdown,
  `terminate/2` walks each managed OS process and its children with
  SIGTERM, waits a grace period, then SIGKILLs survivors — targeting
  individual pids rather than process-group kills (`kill -- -PID`), which
  could reach the BEAM itself or unrelated processes sharing the group.

  Mechanism deferred: compile/purge to `Commonplace.Code.SourceDoc`,
  config parsing/diffing to `Commonplace.Process.Config`, port resolution
  and wiring to `Commonplace.Dataflow.Wiring`.
  """

  use GenServer

  @shutdown_grace_ms 5000

  alias Commonplace.Code.SourceDoc
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
          Logger.error(
            "Orchestrator reconcile failed:\n" <>
              Exception.format(:error, e, __STACKTRACE__)
          )

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

  # CX-uffl (M6 sub-bead i.5): compile-and-purge logic delegated to
  # substrate Commonplace.Code.SourceDoc. Orchestrator keeps its own
  # source_hash tracking for change-detection in detect_source_changes
  # (read_source still returns the hash); the actual Code.compile_string
  # + :code.purge mechanic moves to SourceDoc, including the two-ETS-
  # table cache (round-1 audit (A) — no stale-entry leak).
  defp hot_reload_module(config, state) do
    with {:ok, _source_code, source_hash, source_uuid} <- read_source_with_uuid(config.source, state),
         {:ok, _module} <- SourceDoc.compile(source_uuid, state.store) do
      {:ok, source_hash}
    end
  end

  defp start_process(%Config{mode: :elixir} = config, state) do
    with {:ok, _source_code, source_hash, source_uuid} <- read_source_with_uuid(config.source, state),
         {:ok, _module} <- SourceDoc.compile(source_uuid, state.store) do
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

      # Use start (not start_link) to avoid linking child to orchestrator.
      # module_name is the convention-derived name; SourceDoc.compile
      # returned the source's actual self-named module — they should
      # match if source author follows Commonplace.UserProcess.<Name>
      # convention. If not, GenServer.start surfaces the mismatch.
      case GenServer.start(module_name, init_opts) do
        {:ok, pid} -> {:ok, pid, source_hash}
        error -> {:error, error}
      end
    end
  end

  defp start_process(%Config{mode: :sandbox_exec} = config, state) do
    try do
      # Use scope_uuid if set (subdirectory sandbox), otherwise full tree
      sandbox_uuid = config.scope_uuid || state.root_uuid

      # Resolve $secret:KEY references in env before passing to runner
      resolved_env = case Commonplace.Store.SecretStore.resolve_env(config.env) do
        {:ok, env} -> env
        {:error, {:missing_secrets, names}} ->
          Logger.warning("Process #{config.name}: missing secrets: #{inspect(names)}")
          config.env
      end

      {:ok, pid} = Commonplace.Process.SandboxExecRunner.start_link(
        root_uuid: sandbox_uuid,
        store: state.store,
        command: config.command,
        args: config.args,
        name: config.name,
        env: resolved_env,
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
      cond do
        # Process has no source file (e.g. sandbox-exec or external
        # command). Source-change detection doesn't apply.
        is_nil(config.source) ->
          []

        Map.has_key?(state.processes, config.name) && Map.get(state.processes, config.name) ->
          case read_source(config.source, state) do
            {:ok, _code, hash} ->
              old_hash = Map.get(state.source_hashes, config.name)
              if old_hash != nil and old_hash != hash, do: [config.name], else: []

            _ ->
              []
          end

        true ->
          []
      end
    end)
  end

  defp read_source(filename, state) when is_binary(filename) do
    case read_source_with_uuid(filename, state) do
      {:ok, content, hash, _uuid} -> {:ok, content, hash}
      {:error, _} = err -> err
    end
  end

  # CX-uffl (M6 sub-bead i.5): variant exposing the source doc's UUID
  # so callers can hand off to SourceDoc.compile/2. Schema-resolution
  # layer stays in Orchestrator (which has user-process-name → doc-uuid
  # mapping); SourceDoc operates one layer down.
  defp read_source_with_uuid(filename, state) when is_binary(filename) do
    root_doc = load_schema(state.root_uuid, state.store)

    case Schema.get_entry(root_doc, filename) do
      {:ok, entry} ->
        case CommitStoreClient.latest_commit(state.store, entry.node_id) do
          {:ok, commit} ->
            doc = Yelixer.Doc.new()
            {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
            content = ContentType.get_content(doc) || ""
            hash = :erlang.md5(content)
            {:ok, content, hash, entry.node_id}

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
