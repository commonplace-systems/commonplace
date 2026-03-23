defmodule Commonplace.CLI.Replay do
  @moduledoc """
  View document content at any commit.

  Usage:
    commonplace replay <path>              Show content at each commit
    commonplace replay <path> --list       List commits only (no content)
    commonplace replay <path> --at <id>    Show content at specific commit

  Reconstructs document state by applying Yjs updates from the commit chain.
  """

  alias Commonplace.CLI
  alias Commonplace.Tree.Walk
  alias Commonplace.Store.CommitStoreClient, as: CommitStore
  alias Commonplace.Document.ContentType

  def run(data_dir, _relative_path, args) do
    CLI.ensure_started(data_dir)
    root = CLI.root_uuid(data_dir)

    unless root do
      IO.puts(:stderr, "Not a commonplace workspace.")
      System.halt(1)
    end

    {opts, rest, _} = OptionParser.parse(args, strict: [list: :boolean, at: :string, limit: :integer])

    case rest do
      [path] ->
        loader = &CLI.load_schema/1

        case Walk.resolve_path(root, path, loader) do
          {:ok, doc_uuid} ->
            limit = Keyword.get(opts, :limit, 50)
            log = CommitStore.commit_log(CommitStore, doc_uuid, limit: limit)

            cond do
              opts[:list] ->
                list_commits(path, doc_uuid, log)

              opts[:at] ->
                show_at_commit(path, log, opts[:at])

              true ->
                replay_all(path, doc_uuid, log)
            end

          {:error, {:not_found, segment}} ->
            IO.puts(:stderr, "Not found: #{segment} in #{path}")
            System.halt(1)
        end

      _ ->
        IO.puts(:stderr, "Usage: commonplace replay <path> [--list] [--at <commit_id>]")
        System.halt(1)
    end
  end

  defp list_commits(path, doc_uuid, log) do
    IO.puts("#{path} (#{doc_uuid})\n")

    Enum.with_index(log, 1)
    |> Enum.each(fn {commit, i} ->
      id_hex = commit_hex(commit.id)
      ts = DateTime.to_iso8601(commit.timestamp)
      IO.puts("  #{i}. #{id_hex}  #{ts}  #{byte_size(commit.update)}B")
    end)

    IO.puts("\n#{length(log)} commit(s)")
  end

  defp show_at_commit(path, log, target_hex) do
    target_hex = String.downcase(target_hex)

    # Find the target commit by prefix match
    target_idx = Enum.find_index(log, fn commit ->
      hex = Base.encode16(commit.id, case: :lower)
      String.starts_with?(hex, target_hex)
    end)

    unless target_idx do
      IO.puts(:stderr, "Commit not found: #{target_hex}")
      System.halt(1)
    end

    # Apply updates up to and including the target
    commits_to_apply = Enum.slice(log, 0..target_idx)
    content = reconstruct(commits_to_apply)

    target = Enum.at(log, target_idx)
    IO.puts("#{path} @ #{commit_hex(target.id)} (#{DateTime.to_iso8601(target.timestamp)})\n")
    IO.puts(content)
  end

  defp replay_all(path, _doc_uuid, []) do
    IO.puts("No commits for #{path}")
  end

  defp replay_all(_path, _doc_uuid, log) do
    Enum.with_index(log, 1)
    |> Enum.each(fn {commit, i} ->
      commits_so_far = Enum.slice(log, 0, i)
      content = reconstruct(commits_so_far)
      id_hex = commit_hex(commit.id)
      ts = DateTime.to_iso8601(commit.timestamp)

      IO.puts("--- #{i}. #{id_hex}  #{ts} ---")
      IO.puts(content)
      IO.puts("")
    end)
  end

  defp reconstruct(commits) do
    doc = Yelixer.Doc.new()

    doc = Enum.reduce(commits, doc, fn commit, acc ->
      case Yelixer.Encoding.apply_update(acc, commit.update) do
        {:ok, updated} -> updated
        _ -> acc
      end
    end)

    ContentType.get_content(doc) || ""
  end

  defp commit_hex(id) do
    Base.encode16(id, case: :lower) |> String.slice(0, 12)
  end
end
