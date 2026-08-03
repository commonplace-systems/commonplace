defmodule Commonplace.CLI.Salvage do
  @moduledoc """
  CX-xrds: salvage commits out of an archived `.corrupt.<ts>` CommitStore
  directory (left behind by `CommitStore.init/1`'s recovery path) and
  re-import them into the current workspace's live store.

  Usage: commonplace salvage <corrupt-dir>
  """

  alias Commonplace.CLI
  alias Commonplace.Store.{CommitStore, CommitStoreClient}

  def run(data_dir, _relative_path, args) do
    case args do
      [corrupt_dir | _] ->
        CLI.ensure_started(data_dir)
        do_salvage(corrupt_dir)

      [] ->
        IO.puts(:stderr, "Usage: commonplace salvage <corrupt-dir>")
        System.halt(1)
    end
  end

  defp do_salvage(corrupt_dir) do
    unless File.dir?(corrupt_dir) do
      IO.puts(:stderr, "Not a directory: #{corrupt_dir}")
      System.halt(1)
    end

    IO.puts("Salvaging commits from #{corrupt_dir}...")

    # `salvage_corrupt_archive/2` re-imports each recovered commit via
    # `CommitStore.import_commit/3` internally, so the target it's given
    # must be something `GenServer.call/2` can dispatch directly — a
    # bare name when running against a local store, or a `{name, node}`
    # tuple when routed to a `commonplace serve` node (same routing
    # `CommitStoreClient.remote_node/0` already tracks).
    target_server =
      case CommitStoreClient.remote_node() do
        {:ok, node} -> {CommitStore, node}
        :local -> CommitStore
      end

    case CommitStore.salvage_corrupt_archive(corrupt_dir, target_server) do
      {:ok, %{salvaged: salvaged, skipped: skipped}} ->
        IO.puts("Salvaged: #{salvaged} commits")
        IO.puts("Skipped:  #{skipped} entries (unreadable or rejected)")

      {:error, reason} ->
        IO.puts(:stderr, "Salvage failed: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
