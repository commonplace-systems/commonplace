defmodule Commonplace.CLI.Fork do
  @moduledoc "Fork a directory subtree with new UUIDs."

  alias Commonplace.CLI
  alias Commonplace.Tree.{Walk, Fork}
  alias Commonplace.Store.CommitStoreClient, as: CommitStore

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
            new_uuid = Fork.fork_directory(source_uuid, CommitStore)
            IO.puts("Created fork: #{new_uuid}")

          {:error, {:not_found, name}} ->
            IO.puts(:stderr, "Not found: #{name}")
            System.halt(1)

          {:error, reason} ->
            IO.puts(:stderr, "Error: #{inspect(reason)}")
            System.halt(1)
        end
    end
  end

  defp join_paths("", path), do: path
  defp join_paths(base, ""), do: base
  defp join_paths(base, path), do: Path.join(base, path)
end
