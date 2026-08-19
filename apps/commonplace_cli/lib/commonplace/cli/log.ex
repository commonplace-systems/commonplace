defmodule Commonplace.CLI.Log do
  @moduledoc """
  Show commit history for a document.

  Usage: commonplace log <path> [--limit N]

  Walks the commit DAG from newest to oldest, showing commit ID,
  timestamp, and parent pointer for each commit.
  """

  alias Commonplace.CLI
  alias Commonplace.Tree.Walk
  alias Commonplace.Store.CommitStoreClient, as: CommitStore

  def run(data_dir, _relative_path, args) do
    CLI.ensure_started(data_dir)
    root = CLI.root_uuid(data_dir)

    unless root do
      IO.puts(:stderr, "Not a commonplace workspace.")
      System.halt(1)
    end

    {opts, rest, _} = OptionParser.parse(args, strict: [limit: :integer])
    limit = Keyword.get(opts, :limit, 20)

    case rest do
      [path] ->
        loader = &CLI.load_schema/1

        case Walk.resolve_path(root, path, loader) do
          {:ok, doc_uuid} ->
            log = CommitStore.commit_log(CommitStore, doc_uuid, limit: limit)

            if log == [] do
              IO.puts("No commits for #{path}")
            else
              IO.puts("#{path} (#{doc_uuid})\n")

              Enum.each(log, fn commit ->
                id_hex = Base.encode16(commit.id, case: :lower) |> String.slice(0, 12)

                parent_hex =
                  if commit.parent_id do
                    Base.encode16(commit.parent_id, case: :lower) |> String.slice(0, 12)
                  else
                    "(root)"
                  end

                ts = DateTime.to_iso8601(commit.timestamp)
                update_size = byte_size(commit.update)

                IO.puts("  #{id_hex}  #{ts}  parent:#{parent_hex}  #{update_size}B")
              end)

              IO.puts("\n#{length(log)} commit(s)")
            end

          {:error, {:not_found, segment}} ->
            IO.puts(:stderr, "Not found: #{segment} in #{path}")
            System.halt(1)
        end

      _ ->
        IO.puts(:stderr, "Usage: commonplace log <path> [--limit N]")
        System.halt(1)
    end
  end
end
