defmodule Commonplace.CLI.Reroot do
  @moduledoc """
  Change what a checkout points at.

  Usage: commonplace reroot /path new-docref
  """

  alias Commonplace.CLI
  alias Commonplace.Tree.Docref
  alias Commonplace.Sync.CheckoutRegistry

  def run(data_dir, _relative_path, args) do
    CLI.ensure_started(data_dir)
    root = CLI.root_uuid(data_dir)

    unless root do
      IO.puts(:stderr, "Not a commonplace workspace. Run 'commonplace init' first.")
      System.halt(1)
    end

    case args do
      [path, docref | _] ->
        sync_dir = Path.expand(path)
        loader = &CLI.load_schema/1

        case Docref.resolve(docref, root_uuid: root, loader: loader) do
          {:ok, new_uuid} ->
            registry = start_registry(data_dir)

            case CheckoutRegistry.reroot(registry, sync_dir, new_uuid) do
              {:ok, _checkout} ->
                IO.puts("Rerooted: #{sync_dir} → #{new_uuid}")

              {:error, :not_found} ->
                IO.puts(:stderr, "No checkout found for: #{sync_dir}")
                System.halt(1)

              {:error, reason} ->
                IO.puts(:stderr, "Failed to reroot: #{inspect(reason)}")
                System.halt(1)
            end

          {:error, reason} ->
            IO.puts(:stderr, "Could not resolve docref '#{docref}': #{inspect(reason)}")
            System.halt(1)
        end

      _ ->
        IO.puts(:stderr, "Usage: commonplace reroot /path new-docref")
        System.halt(1)
    end
  end

  defp start_registry(data_dir) do
    config_path = Path.join(data_dir, "checkouts.json")

    {:ok, pid} =
      CheckoutRegistry.start_link(
        config_path: config_path,
        store: Commonplace.Store.CommitStore
      )

    pid
  end
end
