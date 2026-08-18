defmodule Commonplace.CLI.Serve do
  @moduledoc """
  Start the commonplace workspace daemon.

  Starts the orchestrator, which watches __processes.json and
  manages process lifecycle. Runs until interrupted (Ctrl+C).
  """

  alias Commonplace.CLI
  alias Commonplace.Store.CommitStoreClient, as: CommitStore
  alias Commonplace.Tree.{Schema, DocBuilder}
  alias Commonplace.Document.ContentType
  alias Commonplace.Process.Orchestrator

  @serve_formatter_config %{
    template: [:time, " [", :level, "] ", :msg, "\n"],
    time_offset: 0,
    time_designator: "T",
    single_line: true
  }

  def run(data_dir, _relative_path, _args) do
    :ok = configure_logger_sink()
    start_named_node(data_dir)

    topology = Commonplace.Cluster.topology()

    if topology != [] do
      IO.puts("  Cluster peers: #{inspect(topology)}")
    else
      IO.puts("  Cluster: standalone (set COMMONPLACE_NODES to enable clustering)")
    end

    # CX-qida: serve declares itself the workspace owner before booting
    # the :commonplace app, so Commonplace.Application starts the
    # single-owner flock (Commonplace.Workspace.Lock) alongside the
    # orchestrator/bursar. A second serve on the same data_dir fails
    # fast here (CLI.ensure_started halts nonzero with the lock's error
    # message) instead of both processes racing CubDB writes.
    Application.put_env(:commonplace, :workspace_lock_on_boot, true)

    # CX-0t2r (recording-half revival, CX-nyvm parity): Mode A must set
    # the SAME serve-role flag Mode B's runtime.exs sets, before the
    # :commonplace app boots, so Commonplace.Application.reflog_children/0
    # starts a CheckpointTimer here too. Without this, only a Phoenix-as-serve
    # Mode-B boot would drive checkpoints and a CLI-launched serve would
    # silently go dormant again — the exact CX-nyvm drift class (bursar_on_boot
    # was Mode-B-only once and broke every move on that boot path).
    # CX-0t2r deploy lesson (2026-08-03): reads the SAME env var as the
    # Mode-B block in config/runtime.exs (CX-nyvm parity holds — both boot
    # paths agree), but defaults OFF: enabling checkpointing writes into
    # the live store and must be a deliberate act, separable from
    # deploying the code. Set COMMONPLACE_REFLOG_ON_BOOT=true to enable.
    Application.put_env(
      :commonplace,
      :reflog_on_boot,
      System.get_env("COMMONPLACE_REFLOG_ON_BOOT") in ["1", "true"]
    )

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

    # Start the orchestrator SUPERVISED (CX-tdkq.12): under
    # Commonplace.Supervisor a crash restarts it (sweeping its prior
    # generation first) instead of being unrecoverable. whereis-guarded:
    # if the app already booted with :orchestrator_on_boot, reuse it.
    orch = start_supervised_orchestrator()

    IO.puts("  Orchestrator: #{inspect(orch)} (supervised)")

    # Start the green-token Bursar SUPERVISED (move #4, CX-tdkq.7):
    # serve is the cluster's single-owner node (it owns the CommitStore),
    # so the lock authority lives here and nowhere else. Other nodes
    # reach it via BursarClient ({Bursar, node} over distribution) or
    # fail closed. whereis-guarded like the orchestrator: if the app
    # already booted with :bursar_on_boot, reuse it.
    bursar = start_supervised_bursar(root)

    IO.puts("  Bursar: #{inspect(bursar)} (supervised, green-token lock authority)")

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

    # Block while the orchestrator runs. A :DOWN no longer ends serve —
    # the supervisor restarts the orchestrator; we re-attach and keep
    # going. Only a restart that doesn't happen (supervisor gave up)
    # ends the daemon.
    wait_on_orchestrator(Process.monitor(orch), orch, data_dir, pid_file)
  end

  @doc false
  def configure_logger_sink do
    :logger.update_handler_config(
      :default,
      :formatter,
      {:logger_formatter, @serve_formatter_config}
    )
  end

  @doc false
  def format_log_event(event) do
    :logger_formatter.format(event, @serve_formatter_config)
  end

  defp start_supervised_orchestrator do
    case Process.whereis(Orchestrator) do
      nil ->
        spec = %{
          id: Orchestrator,
          start:
            {Orchestrator, :start_link,
             [[root_uuid: :workspace, name: Orchestrator, store: CommitStore, interval: 2000]]},
          restart: :permanent
        }

        {:ok, pid} = Supervisor.start_child(Commonplace.Supervisor, spec)
        pid

      pid ->
        pid
    end
  end

  defp start_supervised_bursar(root) do
    alias Commonplace.Green.Bursar

    case Process.whereis(Bursar) do
      nil ->
        spec = %{
          id: Bursar,
          start: {Bursar, :start_link, [[root_uuid: root, name: Bursar]]},
          restart: :permanent
        }

        {:ok, pid} = Supervisor.start_child(Commonplace.Supervisor, spec)
        pid

      pid ->
        pid
    end
  end

  defp wait_on_orchestrator(ref, orch, data_dir, pid_file) do
    receive do
      {:DOWN, ^ref, :process, ^orch, reason} ->
        IO.puts("\nOrchestrator down (#{inspect(reason)}) — supervisor restarting…")

        case await_orchestrator_restart(40) do
          {:ok, new_pid} ->
            IO.puts("  Orchestrator restarted: #{inspect(new_pid)} (prior generation swept)")
            wait_on_orchestrator(Process.monitor(new_pid), new_pid, data_dir, pid_file)

          :gone ->
            IO.puts("  Orchestrator did not come back — shutting down serve.")
            File.rm(pid_file)
            cleanup_node_name(data_dir)
        end
    end
  end

  defp await_orchestrator_restart(0), do: :gone

  defp await_orchestrator_restart(n) do
    case Process.whereis(Orchestrator) do
      nil ->
        Process.sleep(250)
        await_orchestrator_restart(n - 1)

      pid ->
        {:ok, pid}
    end
  end

  @shutdown_grace_ms 5000

  @doc """
  Kill a prior serve's own OS process (via its pid file). Managed-process
  cleanup moved to `Commonplace.Process.Sweep` (CX-tdkq.12): the
  orchestrator sweeps its prior generation on EVERY (re)start, not just
  at serve boot — serve only reaps the previous serve itself.
  """
  def kill_orphans(data_dir) do
    kill_orchestrator_orphan(data_dir)
  end

  defp kill_orchestrator_orphan(data_dir) do
    pid_file = Path.join(data_dir, "orchestrator.pid")

    case File.read(pid_file) do
      {:ok, content} ->
        os_pid = String.trim(content)
        kill_process_tree(os_pid)
        File.rm(pid_file)

      {:error, _} ->
        :ok
    end
  end

  defp kill_process_tree(pid_str) do
    # Ported to core (CX-tdkq.12) so the orchestrator's sweep and serve
    # share one implementation.
    Commonplace.Process.Sweep.kill_process_tree(pid_str, grace_ms: @shutdown_grace_ms)
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
        CommitStore.create_chained_commit(entry.node_id, update)

      :error ->
        # Create new
        uuid = UUID.uuid4()
        doc = Yelixer.Doc.new()
        doc = ContentType.create(doc, :text, "__processes.json")
        doc = ContentType.insert_text(doc, 0, content)
        update = Yelixer.Encoding.encode_update(doc)
        CommitStore.create_chained_commit(uuid, update)

        root_doc = load_schema(root)
        root_doc = Schema.add_file(root_doc, "__processes.json", uuid)
        update = Yelixer.Encoding.encode_update(root_doc)
        CommitStore.create_chained_commit(root, update)
    end
  end

  defp load_schema(uuid) do
    case DocBuilder.reconstruct_snapshot(CommitStore, uuid) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end

  # Start the BEAM as a named node for distributed Erlang CLI access.
  defp start_named_node(data_dir) do
    # Ensure epmd is running — escripts don't start it automatically
    ensure_epmd()

    # CX-y6uc: disable :global's overlapping-partition protection
    # (default-on since OTP 25). Each MCP escript invocation is a
    # short-lived node joining + leaving; the heuristic mistakes that
    # for a partition and forcibly disconnects subsequent escripts.
    # Must be set before Node.start.
    :application.set_env(:kernel, :prevent_overlapping_partitions, false)

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
      {_, 0} ->
        :ok

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
