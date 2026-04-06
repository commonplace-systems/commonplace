defmodule Commonplace.CLI.Checkpoint do
  @moduledoc """
  Create a reflog checkpoint — snapshot the entire tree state.
  """

  alias Commonplace.CLI
  alias Commonplace.Reflog.Snapshot

  def run(data_dir, _relative_path, args) do
    CLI.ensure_started(data_dir)
    root = CLI.root_uuid(data_dir)

    unless root do
      IO.puts(:stderr, "Not a commonplace workspace.")
      System.halt(1)
    end

    owner =
      case args do
        ["--owner", name | _] -> name
        _ -> "server"
      end

    IO.puts("Creating checkpoint...")

    {:ok, commit_id} = Snapshot.checkpoint(root, Commonplace.Store.CommitStoreClient, owner)
    fp = Base.encode16(commit_id, case: :lower) |> binary_part(0, 16)
    IO.puts("Checkpoint: #{fp}...")
    IO.puts("Owner: #{owner}")
  end
end
