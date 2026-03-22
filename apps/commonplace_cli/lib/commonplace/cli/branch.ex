defmodule Commonplace.CLI.Branch do
  @moduledoc """
  Branch management: list, activate, deactivate.

  Checkout is just cd — branches are materialized as directories.
  Activate/deactivate toggles the sync:true/false flag on a branch's
  schema entry, controlling whether the sync agent syncs that subtree.
  """

  alias Commonplace.CLI
  alias Commonplace.Tree.{Schema, Walk}
  alias Commonplace.Store.CommitStore

  def run(data_dir, relative_path, args) do
    CLI.ensure_started(data_dir)
    root = CLI.root_uuid(data_dir)

    unless root do
      IO.puts(:stderr, "Not a commonplace workspace. Run 'commonplace init' first.")
      System.halt(1)
    end

    case args do
      [] ->
        list_branches(root, relative_path)

      ["list" | _] ->
        list_branches(root, relative_path)

      ["activate", name | _] ->
        set_branch_sync(root, relative_path, name, true)

      ["deactivate", name | _] ->
        set_branch_sync(root, relative_path, name, false)

      [subcmd | _] ->
        IO.puts(:stderr, "Unknown branch subcommand: #{subcmd}")
        IO.puts(:stderr, "Usage: commonplace branch [list|activate|deactivate] [name]")
        System.halt(1)
    end
  end

  defp list_branches(root, relative_path) do
    loader = &CLI.load_schema/1

    {uuid, _} = resolve_current(root, relative_path, loader)
    doc = loader.(uuid)
    entries = Schema.list_entries(doc)

    dirs = Enum.filter(entries, &(&1.type == :dir))

    if dirs == [] do
      IO.puts("No branches (subdirectories) here.")
    else
      Enum.each(dirs, fn entry ->
        sync_marker = if entry.sync, do: "", else: " (inactive)"
        IO.puts("  #{entry.name}#{sync_marker}")
      end)
    end
  end

  defp set_branch_sync(root, relative_path, name, sync) do
    loader = &CLI.load_schema/1
    {uuid, _} = resolve_current(root, relative_path, loader)
    doc = loader.(uuid)

    case Schema.get_entry(doc, name) do
      {:ok, _entry} ->
        doc = Schema.set_sync(doc, name, sync)
        update = Yelixer.Encoding.encode_update(doc)
        CommitStore.create_commit(uuid, update, nil)

        action = if sync, do: "Activated", else: "Deactivated"
        IO.puts("#{action} branch: #{name}")

      :error ->
        IO.puts(:stderr, "Branch not found: #{name}")
        System.halt(1)
    end
  end

  defp resolve_current(root, "", _loader), do: {root, ""}

  defp resolve_current(root, relative_path, loader) do
    case Walk.resolve_path(root, relative_path, loader) do
      {:ok, uuid} -> {uuid, relative_path}
      {:error, _} -> {root, ""}
    end
  end
end
