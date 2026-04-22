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
    case do_run(data_dir, relative_path, args) do
      {:ok, commit, target_uuid} ->
        fp = Base.encode16(commit.id, case: :lower) |> binary_part(0, 16)
        IO.puts("Snapshot: #{fp}...")
        IO.puts("Doc:      #{target_uuid}")

      {:error, :not_a_workspace} ->
        IO.puts(:stderr, "Not a commonplace workspace. Run 'commonplace init' first.")
        System.halt(1)

      {:error, {:path_not_found, name}} ->
        IO.puts(:stderr, "Not found: #{name}")
        System.halt(1)

      {:error, {:path_error, reason}} ->
        IO.puts(:stderr, "Error: #{inspect(reason)}")
        System.halt(1)

      {:error, :doc_has_no_commits} ->
        IO.puts(:stderr, "Doc has no commits yet — nothing to snapshot.")
        System.halt(1)

      {:error, {:snapshot_failed, reason}} ->
        IO.puts(:stderr, "Snapshot failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  @doc """
  Core snapshot logic — returns `{:ok, commit, target_uuid}` or a
  structured error tuple. Extracted from `run/3` so tests exercise
  the snapshot command without going through `System.halt/1`, which
  terminates the BEAM and breaks ExUnit's isolation (causing CI
  flakes where a stale workspace root file would halt the entire
  test suite mid-run).
  """
  def do_run(data_dir, relative_path, args) do
    CLI.ensure_started(data_dir)
    root = CLI.root_uuid(data_dir)

    cond do
      is_nil(root) ->
        {:error, :not_a_workspace}

      true ->
        with {:ok, target_uuid} <- resolve_target(root, relative_path, args),
             {:ok, commit} <- do_snapshot(target_uuid) do
          {:ok, commit, target_uuid}
        end
    end
  end

  defp resolve_target(root, _relative_path, []), do: {:ok, root}

  defp resolve_target(root, relative_path, [arg_path | _]) do
    path = join_paths(relative_path, arg_path)
    loader = &CLI.load_schema/1

    case Walk.resolve_path(root, path, loader) do
      {:ok, uuid} -> {:ok, uuid}
      {:error, {:not_found, name}} -> {:error, {:path_not_found, name}}
      {:error, reason} -> {:error, {:path_error, reason}}
    end
  end

  defp do_snapshot(target_uuid) do
    case CommitStoreClient.snapshot(target_uuid) do
      {:ok, commit} -> {:ok, commit}
      {:error, :not_found} -> {:error, :doc_has_no_commits}
      {:error, reason} -> {:error, {:snapshot_failed, reason}}
    end
  end
end
