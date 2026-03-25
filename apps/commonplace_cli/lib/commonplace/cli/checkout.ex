defmodule Commonplace.CLI.Checkout do
  @moduledoc """
  Manage workspace checkouts.

  Subcommands:
  - `commonplace checkout` — show current root
  - `commonplace checkout /path/to/dir docref` — register directory checkout
  - `commonplace checkout /path/to/file docref --file` — register file checkout
  - `commonplace checkout --remove /path` — unregister a checkout
  """

  alias Commonplace.CLI
  alias Commonplace.Tree.{Docref, Walk}
  alias Commonplace.Sync.{CheckoutRegistry, Export}

  import Commonplace.CLI.Helpers, only: [uuid?: 1]

  def run(data_dir, _relative_path, args) do
    CLI.ensure_started(data_dir)
    root = CLI.root_uuid(data_dir)

    unless root do
      IO.puts(:stderr, "Not a commonplace workspace. Run 'commonplace init' first.")
      System.halt(1)
    end

    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [file: :boolean, remove: :boolean],
        aliases: [f: :file, r: :remove]
      )

    cond do
      opts[:remove] ->
        handle_remove(data_dir, positional)

      positional == [] ->
        IO.puts("Current root: #{root}")

      length(positional) >= 2 ->
        [path, docref | _] = positional
        type = if opts[:file], do: :file, else: :dir
        handle_register(data_dir, root, path, docref, type)

      length(positional) == 1 ->
        # Legacy behavior: single arg re-roots the workspace
        [target] = positional
        handle_reroot_workspace(data_dir, root, target)
    end
  end

  defp handle_register(data_dir, root, path, docref, type) do
    sync_dir = Path.expand(path)
    loader = &CLI.load_schema/1

    case Docref.resolve(docref, root_uuid: root, loader: loader) do
      {:ok, uuid} ->
        registry = start_registry(data_dir)

        case CheckoutRegistry.register(registry, sync_dir, uuid, type) do
          {:ok, _checkout} ->
            IO.puts("Registered #{type} checkout: #{sync_dir} → #{uuid}")

          {:error, :already_registered} ->
            IO.puts(:stderr, "Already registered: #{sync_dir}")
            System.halt(1)

          {:error, reason} ->
            IO.puts(:stderr, "Failed to register: #{inspect(reason)}")
            System.halt(1)
        end

      {:error, reason} ->
        IO.puts(:stderr, "Could not resolve docref '#{docref}': #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp handle_remove(data_dir, positional) do
    case positional do
      [path | _] ->
        sync_dir = Path.expand(path)
        registry = start_registry(data_dir)

        case CheckoutRegistry.unregister(registry, sync_dir) do
          :ok ->
            IO.puts("Removed checkout: #{sync_dir}")

          {:error, :not_found} ->
            IO.puts(:stderr, "No checkout found for: #{sync_dir}")
            System.halt(1)
        end

      [] ->
        IO.puts(:stderr, "Usage: commonplace checkout --remove /path")
        System.halt(1)
    end
  end

  defp handle_reroot_workspace(data_dir, root, target) do
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

  defp resolve_target(root, target) do
    if uuid?(target) do
      {:ok, target}
    else
      loader = &CLI.load_schema/1
      Walk.resolve_path(root, target, loader)
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
