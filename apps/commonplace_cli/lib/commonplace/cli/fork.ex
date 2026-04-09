defmodule Commonplace.CLI.Fork do
  @moduledoc "Fork a directory subtree with new UUIDs."

  alias Commonplace.CLI
  alias Commonplace.CommandRouter
  alias Commonplace.Tree.Walk

  import Commonplace.CLI.Helpers, only: [join_paths: 2]

  def run(data_dir, relative_path, args) do
    CLI.ensure_started(data_dir)
    root = CLI.root_uuid(data_dir)

    unless root do
      IO.puts(:stderr, "Not a commonplace workspace. Run 'commonplace init' first.")
      System.halt(1)
    end

    case args do
      [] ->
        IO.puts(:stderr, "Usage: commonplace fork <path>")
        System.halt(1)

      [target | _] ->
        path = join_paths(relative_path, target)
        loader = &CLI.load_schema/1

        case Walk.resolve_path(root, path, loader) do
          {:ok, source_uuid} ->
            IO.puts("Forking #{path} (#{source_uuid})...")

            case CommandRouter.fork(source_uuid) do
              {:ok, new_uuid} ->
                IO.puts("Created fork: #{new_uuid}")

              {:error, reason} ->
                IO.puts(:stderr, "Fork failed: #{inspect(reason)}")
                System.halt(1)
            end

          {:error, {:not_found, name}} ->
            IO.puts(:stderr, "Not found: #{name}")
            System.halt(1)

          {:error, reason} ->
            IO.puts(:stderr, "Error: #{inspect(reason)}")
            System.halt(1)
        end
    end
  end
end
