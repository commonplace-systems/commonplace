defmodule Commonplace.CLI.Merge do
  @moduledoc "Merge changes from a source branch into the current branch."

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
        IO.puts(:stderr, "Usage: commonplace merge <source-path> [target-path]")
        IO.puts(:stderr, "  Merges changes from source into target (default: current directory).")
        System.halt(1)

      [source | rest] ->
        {target, _} =
          case rest do
            [t | _] -> {t, rest}
            [] -> {".", []}
          end

        source_path = join_paths(relative_path, source)
        target_path = join_paths(relative_path, target)
        loader = &CLI.load_schema/1

        with {:ok, source_uuid} <- resolve_or_error(root, source_path, loader, "source"),
             {:ok, target_uuid} <- resolve_or_error(root, target_path, loader, "target") do
          IO.puts("Merging #{source_path} → #{target_path}...")

          case CommandRouter.merge(source_uuid, target_uuid) do
            {:ok, summary} ->
              print_summary(summary)

            {:error, reason} ->
              IO.puts(:stderr, "Merge failed: #{inspect(reason)}")
              System.halt(1)
          end
        end
    end
  end

  defp resolve_or_error(root, path, loader, label) do
    case Walk.resolve_path(root, path, loader) do
      {:ok, uuid} ->
        {:ok, uuid}

      {:error, {:not_found, name}} ->
        IO.puts(:stderr, "#{String.capitalize(label)} not found: #{name}")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "Error resolving #{label}: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp print_summary(%{} = summary) do
    merged = summary["merged_count"] || 0
    new_count = summary["new_count"] || 0
    deleted = summary["deleted_count"] || 0
    auto_renamed = summary["auto_renamed"] || []
    conflicts = summary["conflicts"] || []

    if merged == 0 and new_count == 0 and deleted == 0 and
         auto_renamed == [] and conflicts == [] do
      IO.puts("Already up to date.")
    else
      if merged > 0, do: IO.puts("Merged #{merged} document(s)")
      if new_count > 0, do: IO.puts("Added #{new_count} new document(s)")
      if deleted > 0, do: IO.puts("Deleted #{deleted} document(s)")

      Enum.each(auto_renamed, fn %{"original" => original, "renamed" => renamed} ->
        IO.puts("  Renamed collision: #{original} → #{renamed}")
      end)

      if conflicts != [] do
        IO.puts("\nConflicts (#{length(conflicts)}):")
        Enum.each(conflicts, fn conflict_str -> IO.puts("  #{conflict_str}") end)
      end

      IO.puts("Done.")
    end
  end
end
