defmodule Commonplace.CLI.Ls do
  @moduledoc "List directory contents at a path."

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

    # Combine workspace-relative path with explicit arg
    arg_path = List.first(args) || ""
    path = join_paths(relative_path, arg_path)
    loader = &CLI.load_schema/1

    case Walk.list_path(root, path, loader) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          suffix = if entry.type == :dir, do: "/", else: ""
          IO.puts("#{entry.name}#{suffix}")
        end)

      {:error, {:not_found, name}} ->
        IO.puts(:stderr, "Not found: #{name}")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{inspect(reason)}")
        System.halt(1)
    end
  end

end
