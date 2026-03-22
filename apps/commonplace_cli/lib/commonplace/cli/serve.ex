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
    end
  end

  defp kill_orphans(data_dir) do
    pid_file = Path.join(data_dir, "orchestrator.pid")

    case File.read(pid_file) do
      {:ok, content} ->
        os_pid = String.trim(content)

        # Check if the old process is still running
        case System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true) do
          {_, 0} ->
            IO.puts("Killing previous orchestrator (PID #{os_pid})...")
            # Kill the process group to catch children
            System.cmd("kill", ["-TERM", "--", "-#{os_pid}"], stderr_to_stdout: true)
            Process.sleep(2000)
            # Force kill if still alive
            System.cmd("kill", ["-9", "--", "-#{os_pid}"], stderr_to_stdout: true)
            Process.sleep(500)

          _ ->
            :ok
        end

        File.rm(pid_file)

      {:error, _} ->
        :ok
    end

    # Also clean up stale sandbox directories
    case File.ls("/tmp") do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, "cp_sandbox_"))
        |> Enum.each(fn dir ->
          path = Path.join("/tmp", dir)
          File.rm_rf(path)
        end)
      _ -> :ok
    end
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
end
