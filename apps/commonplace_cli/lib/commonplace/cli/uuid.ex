defmodule Commonplace.CLI.Uuid do
  @moduledoc "Resolve a path to its document UUID."

  alias Commonplace.CLI
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
        # No path — show root UUID
        IO.puts(root)

      [arg_path | _] ->
        path = join_paths(relative_path, arg_path)
        loader = &CLI.load_schema/1

        case Walk.resolve_path(root, path, loader) do
          {:ok, uuid} ->
            IO.puts(uuid)

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
