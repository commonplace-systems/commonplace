defmodule Commonplace.CLI.Snapshot do
  @moduledoc """
  Force a snapshot commit for the doc at `<path>` (CX-2ok0).

  Calls `Commonplace.Store.CommitStore.snapshot/2` directly so the
  resulting commit lands regardless of the chain-length / size-of-bytes
  threshold that drives the automatic snapshot trigger (CX-tvyb).

  Useful for ops, debugging, and manual compaction runs. Concurrent
  snapshots at the same parent dedup via the deterministic-anyone
  property (CX-umz), so safe to invoke alongside automatic triggers.

  Usage:
      commonplace snapshot                # snapshot the workspace root
      commonplace snapshot <path>         # snapshot the doc at <path>
  """

  alias Commonplace.CLI
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Walk

  import Commonplace.CLI.Helpers, only: [join_paths: 2]

  def run(data_dir, relative_path, args) do
    CLI.ensure_started(data_dir)
    root = CLI.root_uuid(data_dir)

    unless root do
      IO.puts(:stderr, "Not a commonplace workspace. Run 'commonplace init' first.")
      System.halt(1)
    end

    target_uuid =
      case args do
        [] ->
          root

        [arg_path | _] ->
          path = join_paths(relative_path, arg_path)
          loader = &CLI.load_schema/1

          case Walk.resolve_path(root, path, loader) do
            {:ok, uuid} ->
              uuid

            {:error, {:not_found, name}} ->
              IO.puts(:stderr, "Not found: #{name}")
              System.halt(1)

            {:error, reason} ->
              IO.puts(:stderr, "Error: #{inspect(reason)}")
              System.halt(1)
          end
      end

    case CommitStoreClient.snapshot(target_uuid) do
      {:ok, commit} ->
        fp = Base.encode16(commit.id, case: :lower) |> binary_part(0, 16)
        IO.puts("Snapshot: #{fp}...")
        IO.puts("Doc:      #{target_uuid}")

      {:error, :not_found} ->
        IO.puts(:stderr, "Doc has no commits yet — nothing to snapshot.")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "Snapshot failed: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
