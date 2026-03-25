defmodule Commonplace.CLI.Merge do
  @moduledoc "Merge changes from a source branch into the current branch."

  alias Commonplace.CLI
  alias Commonplace.Tree.{Walk, Merge}
  alias Commonplace.Store.CommitStore

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
        {target, _} = case rest do
          [t | _] -> {t, rest}
          [] -> {".", []}
        end

        source_path = join_paths(relative_path, source)
        target_path = join_paths(relative_path, target)
        loader = &CLI.load_schema/1

        with {:ok, source_uuid} <- resolve_or_error(root, source_path, loader, "source"),
             {:ok, target_uuid} <- resolve_or_error(root, target_path, loader, "target") do
          IO.puts("Merging #{source_path} → #{target_path}...")

          case Merge.merge(source_uuid, target_uuid, CommitStore) do
            {:ok, report} ->
              print_report(report)

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

  defp print_report(%Merge.MergeReport{} = report) do
    if report.merged_docs == [] and report.new_docs == [] and
         report.deleted_docs == [] and report.auto_renamed == [] and
         report.conflicts == [] do
      IO.puts("Already up to date.")
    else
      if report.merged_docs != [] do
        IO.puts("Merged #{length(report.merged_docs)} document(s)")
      end

      if report.new_docs != [] do
        IO.puts("Added #{length(report.new_docs)} new document(s)")
      end

      if report.deleted_docs != [] do
        IO.puts("Deleted #{length(report.deleted_docs)} document(s)")
      end

      Enum.each(report.auto_renamed, fn {:auto_renamed, original, renamed, _src, _new} ->
        IO.puts("  Renamed collision: #{original} → #{renamed}")
      end)

      if report.conflicts != [] do
        IO.puts("\nConflicts (#{length(report.conflicts)}):")
        Enum.each(report.conflicts, fn
          {:delete_vs_modify, name, _uuid} ->
            IO.puts("  #{name}: deleted on source, modified on target")
          other ->
            IO.puts("  #{inspect(other)}")
        end)
      end

      IO.puts("Done.")
    end
  end

end
