defmodule Commonplace.CLI.Serve do
  @moduledoc """
  Start the commonplace workspace daemon.

  Starts the orchestrator, which watches __processes.json and
  manages process lifecycle. Runs until interrupted (Ctrl+C).
  """

  alias Commonplace.CLI
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType
  alias Commonplace.Process.Orchestrator

  def run(data_dir, _relative_path, _args) do
    start_named_node(data_dir)
    CLI.ensure_started(data_dir)
    root = CLI.root_uuid(data_dir)

    unless root do
      IO.puts(:stderr, "Not a commonplace workspace. Run 'commonplace init' first.")
      System.halt(1)
    end

    # Import __processes.json from disk if it exists in the workspace
    workspace_dir = Path.dirname(data_dir)
    proc_file = Path.join(workspace_dir, "__processes.json")

    if File.exists?(proc_file) do
      ensure_processes_json(root, proc_file)
    end

    # Kill any orphan processes from a previous serve
    kill_orphans(data_dir)

    IO.puts("Starting commonplace workspace daemon...")
    IO.puts("  Root UUID: #{root}")
    IO.puts("  Data dir: #{data_dir}")

    # Write PID file
    pid_file = Path.join(data_dir, "orchestrator.pid")
    File.write!(pid_file, "#{System.pid()}\n")

    # Start the orchestrator
    {:ok, orch} = Orchestrator.start_link(
      root_uuid: root,
      store: CommitStore,
      interval: 2000
    )

    IO.puts("  Orchestrator: #{inspect(orch)}")

    # Wait a moment for processes to start
    Process.sleep(2000)

    procs = Orchestrator.running_processes(orch)
    IO.puts("\nRunning processes (#{map_size(procs)}):")

    Enum.each(procs, fn {name, pid} ->
      IO.puts("  #{name} => #{inspect(pid)}")
    end)

    if map_size(procs) == 0 do
      IO.puts("  (none — add entries to __processes.json)")
    end

    IO.puts("\nPress Ctrl+C to stop.")

    # Block forever — the orchestrator runs in the background
    ref = Process.monitor(orch)

    receive do
      {:DOWN, ^ref, :process, ^orch, reason} ->
        IO.puts("\nOrchestrator stopped: #{inspect(reason)}")
        File.rm(pid_file)
        cleanup_node_name(data_dir)
    end
  end

  @shutdown_grace_ms 5000

  @doc "Kill orphaned processes from a previous serve instance."
  def kill_orphans(data_dir) do
    kill_orchestrator_orphan(data_dir)
    sandbox_dirs = kill_managed_orphans(data_dir)
    cleanup_sandbox_dirs(sandbox_dirs)
  end

  defp kill_orchestrator_orphan(data_dir) do
    pid_file = Path.join(data_dir, "orchestrator.pid")

    case File.read(pid_file) do
      {:ok, content} ->
        os_pid = String.trim(content)
        kill_process_group(os_pid)
        File.rm(pid_file)

      {:error, _} ->
        :ok
    end
  end

  defp kill_managed_orphans(data_dir) do
    status_file = Path.join(data_dir, "orchestrator_status.json")

    case File.read(status_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"processes" => processes}} when is_map(processes) ->
            sandbox_dirs =
              processes
              |> Enum.flat_map(fn {name, info} ->
                os_pid = info["os_pid"]

                if os_pid do
                  IO.puts("Killing orphaned process: #{name} (PGID #{os_pid})")
                  kill_process_group("#{os_pid}")
                end

                # Collect sandbox dirs for cleanup
                case info["sandbox_dir"] do
                  dir when is_binary(dir) -> [dir]
                  _ -> []
                end
              end)

            File.rm(status_file)
            sandbox_dirs

          _ ->
            File.rm(status_file)
            []
        end

      {:error, _} ->
        []
    end
  end

  defp kill_process_group(pid_str) do
    # Check if any process in the group is alive
    case System.cmd("kill", ["-0", "--", "-#{pid_str}"], stderr_to_stdout: true) do
      {_, 0} ->
        # SIGTERM the process group
        System.cmd("kill", ["-TERM", "--", "-#{pid_str}"], stderr_to_stdout: true)
        Process.sleep(@shutdown_grace_ms)
        # SIGKILL survivors
        System.cmd("kill", ["-9", "--", "-#{pid_str}"], stderr_to_stdout: true)
        Process.sleep(500)

      _ ->
        :ok
    end
  end

  # Only clean up sandbox dirs that were tracked in the old status file.
  # Previously this deleted ALL /tmp/cp_sandbox_* which could destroy
  # sandboxes belonging to other workspaces or still-running processes.
  defp cleanup_sandbox_dirs(sandbox_dirs) do
    Enum.each(sandbox_dirs, fn dir ->
      if File.dir?(dir) do
        IO.puts("Cleaning up sandbox: #{dir}")
        File.rm_rf(dir)
      end
    end)
  end

  defp ensure_processes_json(root, proc_file) do
    content = File.read!(proc_file)
    root_doc = load_schema(root)

    case Schema.get_entry(root_doc, "__processes.json") do
      {:ok, entry} ->
        # Update existing
        doc = Yelixer.Doc.new()
        doc = ContentType.create(doc, :text, "__processes.json")
        doc = ContentType.insert_text(doc, 0, content)
        update = Yelixer.Encoding.encode_update(doc)
        CommitStore.create_commit(entry.node_id, update, nil)

      :error ->
        # Create new
        uuid = UUID.uuid4()
        doc = Yelixer.Doc.new()
        doc = ContentType.create(doc, :text, "__processes.json")
        doc = ContentType.insert_text(doc, 0, content)
        update = Yelixer.Encoding.encode_update(doc)
        CommitStore.create_commit(uuid, update, nil)

        root_doc = load_schema(root)
        root_doc = Schema.add_file(root_doc, "__processes.json", uuid)
        update = Yelixer.Encoding.encode_update(root_doc)
        CommitStore.create_commit(root, update, nil)
    end
  end

  defp load_schema(uuid) do
    case CommitStore.latest_commit(uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end

  # Start the BEAM as a named node for distributed Erlang CLI access.
  defp start_named_node(data_dir) do
    # Ensure epmd is running — escripts don't start it automatically
    ensure_epmd()

    node_name = workspace_node_name(data_dir)

    case Node.start(node_name, :shortnames) do
      {:ok, _} ->
        # Write node name file so CLI can discover us
        node_name_file = Path.join(data_dir, "node_name")
        File.write!(node_name_file, "#{Node.self()}")
        IO.puts("  Node: #{Node.self()}")

      {:error, reason} ->
        IO.puts(:stderr, "Warning: could not start named node: #{inspect(reason)}")
        IO.puts(:stderr, "  CLI commands will use direct CubDB access (file-locked).")
    end
  end

  defp ensure_epmd do
    case System.cmd("epmd", ["-names"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ ->
        # Start epmd as a daemon
        System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)
        # Give it a moment to start
        Process.sleep(500)
    end
  end

  defp cleanup_node_name(data_dir) do
    node_name_file = Path.join(data_dir, "node_name")
    File.rm(node_name_file)
  end

  defp workspace_node_name(data_dir) do
    hash =
      :crypto.hash(:sha256, data_dir)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 6)

    :"commonplace_#{hash}"
  end
end
