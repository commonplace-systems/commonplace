defmodule Commonplace.CLI do
  @moduledoc """
  Git-style CLI for commonplace.

  Usage: commonplace <command> [args]

  Commands:
    init                          Initialize a new commonplace workspace
    ls [path]                     List directory contents
    cat <path>                    Show document content
    import <dir>                  Import files from disk into the document tree
    export <dir>                  Export document tree to disk
    sync [dir]                    Sync disk changes to/from CRDT
    branch [list|activate|deactivate] [name]  Manage branches
    checkout [path docref] [--file|--remove]  Manage checkouts
    checkouts                     List active checkouts
    reroot <path> <docref>        Change what a checkout points at
    who [--type exe|usr|bot|who] [--all]  List actors
    ln <source> <target>          Link target to same doc as source
    log <path> [--limit N]        Show commit history for a document
    replay <path> [--list|--at ID] View document content at any commit
    uuid [path]                     Show document UUID for a path
    inspect <path|uuid>             Inspect raw CRDT document state
    event [uuid] [--last N] [--json] Read event logs
    gc                              Find orphaned documents
    fork <path>                     Fork a directory subtree
    merge <source> [target]       Merge source branch into target (default: cwd)
    serve                         Start the workspace daemon
    ps                            List managed processes
    process remove <name>         Remove a process entry from root __processes.json
    signal <topic> <type> [json]  Send a magenta message
    secret <command>              Manage local secrets (set/get/list/delete)
    keygen [name]                 Generate Ed25519 signing keypair
    attest [path]                 Sign the head of a document (gold chain)
    cap <issue|delegate|show>     Issue/attenuate capability certs (phase 3)
    checkpoint [--owner name]     Create a reflog checkpoint
    snapshot [path]               Force a snapshot commit for the doc at path (or workspace root)
    mud connect <name>            Connect to the workspace MUD world (shares the serve daemon)
    bd <subcommand>               Beads issue tracker on commonplace (create/show/update/close/list/ready/…)
  """

  @workspace_dir ".commonplace"

  def main(args) do
    {opts, args, _} =
      OptionParser.parse_head(args,
        strict: [data_dir: :string, help: :boolean],
        aliases: [d: :data_dir, h: :help]
      )

    if opts[:help] do
      IO.puts(@moduledoc)
      System.halt(0)
    end

    case args do
      ["init" | rest] ->
        # init creates .commonplace in cwd (or -d override)
        data_dir = opts[:data_dir] || Path.join(File.cwd!(), @workspace_dir)
        Commonplace.CLI.Init.run(data_dir, rest)

      [] ->
        IO.puts(@moduledoc)

      [cmd | rest] ->
        # All other commands discover the workspace by walking up
        case opts[:data_dir] || discover_workspace() do
          nil ->
            IO.puts(:stderr, "Not in a commonplace workspace. Run 'commonplace init' first.")
            System.halt(1)

          {data_dir, relative_path} ->
            run_command(cmd, data_dir, relative_path, rest)

          data_dir when is_binary(data_dir) ->
            # -d override: no relative path context
            run_command(cmd, data_dir, "", rest)
        end
    end
  end

  defp run_command(cmd, data_dir, relative_path, rest) do
    case cmd do
      "ls" -> Commonplace.CLI.Ls.run(data_dir, relative_path, rest)
      "cat" -> Commonplace.CLI.Cat.run(data_dir, relative_path, rest)
      "import" -> Commonplace.CLI.Import.run(data_dir, rest)
      "export" -> Commonplace.CLI.Export.run(data_dir, relative_path, rest)
      "sync" -> Commonplace.CLI.Sync.run(data_dir, relative_path, rest)
      "branch" -> Commonplace.CLI.Branch.run(data_dir, relative_path, rest)
      "checkout" -> Commonplace.CLI.Checkout.run(data_dir, relative_path, rest)
      "checkouts" -> Commonplace.CLI.Checkouts.run(data_dir, relative_path, rest)
      "reroot" -> Commonplace.CLI.Reroot.run(data_dir, relative_path, rest)
      "who" -> Commonplace.CLI.Who.run(data_dir, relative_path, rest)
      "ln" -> Commonplace.CLI.Ln.run(data_dir, relative_path, rest)
      "log" -> Commonplace.CLI.Log.run(data_dir, relative_path, rest)
      "replay" -> Commonplace.CLI.Replay.run(data_dir, relative_path, rest)
      "serve" -> Commonplace.CLI.Serve.run(data_dir, relative_path, rest)
      "ps" -> Commonplace.CLI.Ps.run(data_dir, relative_path, rest)
      "process" ->
        case Commonplace.CLI.Process.run(data_dir, relative_path, rest) do
          0 -> :ok
          code -> System.halt(code)
        end
      "uuid" -> Commonplace.CLI.Uuid.run(data_dir, relative_path, rest)
      "inspect" -> Commonplace.CLI.InspectCmd.run(data_dir, relative_path, rest)
      "event" -> Commonplace.CLI.Event.run(data_dir, relative_path, rest)
      "gc" -> Commonplace.CLI.GC.run(data_dir, relative_path, rest)
      "fork" -> Commonplace.CLI.Fork.run(data_dir, relative_path, rest)
      "merge" -> Commonplace.CLI.Merge.run(data_dir, relative_path, rest)
      "signal" -> Commonplace.CLI.Signal.run(data_dir, relative_path, rest)
      "secret" -> Commonplace.CLI.Secret.run(data_dir, relative_path, rest)
      "keygen" -> Commonplace.CLI.Keygen.run(data_dir, relative_path, rest)
      "attest" -> Commonplace.CLI.Attest.run(data_dir, relative_path, rest)
      "cap" -> Commonplace.CLI.Cap.run(data_dir, relative_path, rest)
      "checkpoint" -> Commonplace.CLI.Checkpoint.run(data_dir, relative_path, rest)
      "snapshot" -> Commonplace.CLI.Snapshot.run(data_dir, relative_path, rest)
      "mud" -> Commonplace.CLI.Mud.run(data_dir, relative_path, rest)
      "bd" -> Commonplace.CLI.Bd.run(data_dir, relative_path, rest)
      _ ->
        IO.puts(:stderr, "Unknown command: #{cmd}")
        IO.puts(:stderr, "Run 'commonplace --help' for usage.")
        System.halt(1)
    end
  end

  @doc """
  Discover the workspace by walking up from cwd.

  Returns `{data_dir, relative_path}` where relative_path is the
  path from the workspace root to cwd (for context-aware commands).
  Returns nil if no workspace found.
  """
  def discover_workspace do
    discover_workspace(File.cwd!())
  end

  def discover_workspace(start_dir) do
    Commonplace.Workspace.discover(start_dir)
  end

  @doc """
  Start the application services needed for CLI commands.

  Tries to connect to a running `commonplace serve` node first. If connected,
  routes CommitStore calls remotely (no local CubDB). If not, acquires a file
  lock and starts CubDB locally.
  """
  def ensure_started(data_dir) do
    File.mkdir_p!(data_dir)

    case try_connect_to_serve(data_dir) do
      {:ok, node} ->
        # Connected to serve — use remote CommitStore, don't start local app
        Commonplace.Store.CommitStoreClient.set_remote_node(node)
        :ok

      :not_running ->
        # No serve running — acquire lock and start locally
        case acquire_db_lock(data_dir) do
          {:ok, _fd} ->
            # Stop if already running with wrong data_dir (escript auto-start)
            if Application.get_env(:commonplace, :data_dir) != data_dir do
              Application.stop(:commonplace)
            end

            Application.put_env(:commonplace, :data_dir, data_dir)
            {:ok, _} = Application.ensure_all_started(:commonplace)
            :ok

          {:error, :locked} ->
            IO.puts(:stderr,
              "Cannot access database — another process holds the lock.\n" <>
                "If commonplace serve is running, distributed Erlang connection failed.\n" <>
                "Stop the other process first."
            )

            System.halt(1)
        end
    end
  end

  defp try_connect_to_serve(data_dir) do
    node_name_file = Path.join(data_dir, "node_name")

    case File.read(node_name_file) do
      {:ok, content} ->
        serve_node = content |> String.trim() |> String.to_atom()

        # Start a temporary CLI node so we can connect.
        # CX-y6uc: disable :global's overlapping-partition protection
        # (default-on since OTP 25). Each CLI invocation is short-lived;
        # without this, repeated CLI calls trip serve's :global into
        # disconnecting them. Must be set before Node.start.
        :application.set_env(:kernel, :prevent_overlapping_partitions, false)

        cli_name = :"commonplace_cli_#{:rand.uniform(999_999)}"

        case Node.start(cli_name, :shortnames) do
          {:ok, _} ->
            if Node.connect(serve_node) do
              {:ok, serve_node}
            else
              Node.stop()
              :not_running
            end

          {:error, _} ->
            :not_running
        end

      {:error, _} ->
        :not_running
    end
  end

  defp acquire_db_lock(data_dir) do
    lock_path = Path.join(data_dir, "commits.lock")
    my_pid = System.pid()

    case File.read(lock_path) do
      {:ok, content} ->
        pid_str = String.trim(content)

        cond do
          # Same process already holds the lock — re-entrant
          pid_str == my_pid ->
            {:ok, lock_path}

          # Check if the locking process is still alive
          process_alive?(pid_str) ->
            {:error, :locked}

          # Stale lock file — process is dead, take over
          true ->
            write_lock(lock_path, my_pid)
        end

      {:error, _} ->
        write_lock(lock_path, my_pid)
    end
  end

  defp process_alive?(pid_str) do
    case System.cmd("kill", ["-0", pid_str], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp write_lock(lock_path, pid) do
    File.write!(lock_path, pid)
    {:ok, lock_path}
  end

  @doc "Load a schema doc from the commit store."
  def load_schema(uuid) do
    alias Commonplace.Tree.{Schema, DocBuilder}
    alias Commonplace.Store.CommitStoreClient

    case DocBuilder.reconstruct_snapshot(CommitStoreClient, uuid) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end

  @doc "Get the root UUID for this workspace."
  def root_uuid(data_dir) do
    meta_path = Path.join(data_dir, "root")

    case File.read(meta_path) do
      {:ok, uuid} -> String.trim(uuid)
      {:error, _} -> nil
    end
  end

  @doc "Set the root UUID for this workspace."
  def set_root_uuid(data_dir, uuid) do
    File.write!(Path.join(data_dir, "root"), uuid)
  end
end
