defmodule Commonplace.CLI.Sync do
  @moduledoc """
  One-shot sync between disk and CRDT documents.

  Detects changes on disk (new/modified/deleted files) and syncs
  them into the document tree. Then exports the current tree back
  to disk so any CRDT-side changes are reflected.
  """

  alias Commonplace.CLI
  alias Commonplace.Sync.{Watcher, Export}
  alias Commonplace.Tree.Walk

  def run(data_dir, relative_path, args) do
    CLI.ensure_started(data_dir)
    root = CLI.root_uuid(data_dir)

    unless root do
      IO.puts(:stderr, "Not a commonplace workspace. Run 'commonplace init' first.")
      System.halt(1)
    end

    # Determine the sync directory — either explicit arg or workspace root
    {sync_dir, sync_uuid} = resolve_sync_target(root, relative_path, args, data_dir)

    unless File.dir?(sync_dir) do
      IO.puts(:stderr, "Not a directory: #{sync_dir}")
      System.halt(1)
    end

    # Inbound: disk → CRDT (recursive)
    IO.puts("Scanning #{sync_dir}...")
    Watcher.sync_recursive(sync_uuid, sync_dir)
    IO.puts("Synced disk → CRDT.")

    # Outbound: CRDT → disk
    IO.puts("Exporting CRDT → disk...")
    Export.export(sync_uuid, sync_dir)
    IO.puts("Done.")
  end

  defp resolve_sync_target(root, relative_path, args, data_dir) do
    case args do
      [dir | _] ->
        # Explicit directory argument
        {Path.expand(dir), root}

      [] when relative_path != "" ->
        # Inside a subdirectory — sync that subtree
        loader = &CLI.load_schema/1

        case Walk.resolve_path(root, relative_path, loader) do
          {:ok, uuid} -> {File.cwd!(), uuid}
          {:error, _} -> {workspace_root(data_dir), root}
        end

      [] ->
        # At workspace root
        {workspace_root(data_dir), root}
    end
  end

  defp workspace_root(data_dir) do
    Path.dirname(data_dir)
  end
end
