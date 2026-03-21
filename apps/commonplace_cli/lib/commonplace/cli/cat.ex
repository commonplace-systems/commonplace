defmodule Commonplace.CLI.Cat do
  @moduledoc "Show document content at a path."

  alias Commonplace.CLI
  alias Commonplace.Tree.Walk
  alias Commonplace.Document.ContentType
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
        IO.puts(:stderr, "Usage: commonplace cat <path>")
        System.halt(1)

      [arg_path | _] ->
        path = join_paths(relative_path, arg_path)
        loader = &CLI.load_schema/1

        case Walk.resolve_path(root, path, loader) do
          {:ok, uuid} ->
            print_content(uuid)

          {:error, {:not_found, name}} ->
            IO.puts(:stderr, "Not found: #{name}")
            System.halt(1)

          {:error, reason} ->
            IO.puts(:stderr, "Error: #{inspect(reason)}")
            System.halt(1)
        end
    end
  end

  defp join_paths("", path), do: path
  defp join_paths(base, ""), do: base
  defp join_paths(base, path), do: Path.join(base, path)

  defp print_content(uuid) do
    case CommitStore.latest_commit(uuid) do
      {:ok, commit} ->
        doc = Yelixer.Doc.new()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)

        case ContentType.get_type(doc) do
          nil ->
            if Yelixer.Doc.has_type?(doc, "text") do
              IO.write(Yelixer.Types.Text.to_string(doc, "text"))
            else
              IO.puts(:stderr, "Unknown document format")
            end

          type ->
            content = ContentType.get_content(doc)
            format_content(type, content)
        end

      :none ->
        IO.puts(:stderr, "Document not found: #{uuid}")
        System.halt(1)
    end
  end

  defp format_content(:text, text) when is_binary(text), do: IO.write(text)

  defp format_content(:map, map) when is_map(map) do
    IO.puts(Jason.encode!(map, pretty: true))
  end

  defp format_content(:array, list) when is_list(list) do
    IO.puts(Jason.encode!(list, pretty: true))
  end

  defp format_content(type, content) do
    IO.puts("#{type}: #{inspect(content)}")
  end
end
