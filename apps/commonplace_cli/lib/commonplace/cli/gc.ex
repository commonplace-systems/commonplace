defmodule Commonplace.CLI.GC do
  @moduledoc "Find orphaned documents not reachable from root."

  alias Commonplace.CLI
  alias Commonplace.CommandRouter

  def run(data_dir, _relative_path, _args) do
    CLI.ensure_started(data_dir)
    root = CLI.root_uuid(data_dir)

    unless root do
      IO.puts(:stderr, "Not a commonplace workspace. Run 'commonplace init' first.")
      System.halt(1)
    end

    IO.puts("Walking document tree from root...")

    case CommandRouter.gc(root) do
      {:ok, report} ->
        IO.puts("Reachable: #{report["reachable_count"]} documents")
        IO.puts("Orphaned:  #{report["orphaned_count"]} documents")

        if report["orphaned_count"] > 0 do
          IO.puts("")
          IO.puts("Orphaned UUIDs:")

          Enum.each(report["orphaned_uuids"], fn uuid ->
            IO.puts("  #{uuid}")
          end)
        end

      {:error, reason} ->
        IO.puts(:stderr, "GC failed: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
