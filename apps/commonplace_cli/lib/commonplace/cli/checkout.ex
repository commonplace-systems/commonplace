defmodule Commonplace.CLI.Checkout do
  @moduledoc """
  Re-root the workspace to a different document UUID.

  Resolves a target (path or UUID) and changes what the workspace
  is syncing. The sync directory is then re-exported from the new root.
  """

  alias Commonplace.CLI
  alias Commonplace.Tree.Walk
  alias Commonplace.Sync.Export

  def run(data_dir, _relative_path, args) do
    CLI.ensure_started(data_dir)
    root = CLI.root_uuid(data_dir)

    unless root do
      IO.puts(:stderr, "Not a commonplace workspace. Run 'commonplace init' first.")
      System.halt(1)
    end

    case args do
      [] ->
        IO.puts("Current root: #{root}")

      [target | _] ->
        case resolve_target(root, target) do
          {:ok, uuid} ->
            CLI.set_root_uuid(data_dir, uuid)
            IO.puts("Re-rooted: #{root} → #{uuid}")

            workspace_dir = Path.dirname(data_dir)
            IO.puts("Exporting from new root...")
            Export.export(uuid, workspace_dir)
            IO.puts("Done.")

          {:error, reason} ->
            IO.puts(:stderr, "Could not resolve: #{inspect(reason)}")
            System.halt(1)
        end
    end
  end

  defp resolve_target(root, target) do
    if uuid?(target) do
      {:ok, target}
    else
      # Resolve as a path from current root
      loader = &CLI.load_schema/1
      Walk.resolve_path(root, target, loader)
    end
  end

  defp uuid?(str) do
    Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, str)
  end
end
