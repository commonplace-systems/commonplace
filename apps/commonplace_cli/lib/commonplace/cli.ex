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
    who [--type exe|usr|bot|who] [--all]  List actors
    ln <source> <target>          Link target to same doc as source
    signal <topic> <type> [json]  Send a magenta message
  """

  @workspace_dir ".commonplace"

  def main(args) do
    {opts, args, _} =
      OptionParser.parse(args,
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
      "who" -> Commonplace.CLI.Who.run(data_dir, relative_path, rest)
      "ln" -> Commonplace.CLI.Ln.run(data_dir, relative_path, rest)
      "signal" -> Commonplace.CLI.Signal.run(data_dir, relative_path, rest)
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
    do_discover(start_dir, start_dir)
  end

  defp do_discover(current_dir, original_dir) do
    candidate = Path.join(current_dir, @workspace_dir)

    cond do
      File.dir?(candidate) ->
        relative =
          if original_dir == current_dir do
            ""
          else
            Path.relative_to(original_dir, current_dir)
          end

        {candidate, relative}

      current_dir == "/" ->
        nil

      true ->
        do_discover(Path.dirname(current_dir), original_dir)
    end
  end

  @doc "Start the application services needed for CLI commands."
  def ensure_started(data_dir) do
    File.mkdir_p!(data_dir)
    Application.put_env(:commonplace, :data_dir, data_dir)
    {:ok, _} = Application.ensure_all_started(:commonplace)
    :ok
  end

  @doc "Load a schema doc from the commit store."
  def load_schema(uuid) do
    alias Commonplace.Store.CommitStore
    alias Commonplace.Tree.Schema

    case CommitStore.latest_commit(uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
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
