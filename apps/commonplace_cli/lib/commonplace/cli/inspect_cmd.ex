defmodule Commonplace.CLI.InspectCmd do
  @moduledoc "Inspect raw CRDT document state."

  alias Commonplace.CLI
  alias Commonplace.Tree.Walk
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient

  import Commonplace.CLI.Helpers, only: [join_paths: 2, uuid?: 1]

  def run(data_dir, relative_path, args) do
    CLI.ensure_started(data_dir)
    root = CLI.root_uuid(data_dir)

    unless root do
      IO.puts(:stderr, "Not a commonplace workspace. Run 'commonplace init' first.")
      System.halt(1)
    end

    case args do
      [] ->
        IO.puts(:stderr, "Usage: commonplace inspect <path|uuid>")
        System.halt(1)

      [target | _rest] ->
        uuid = resolve_target(root, relative_path, target)
        inspect_document(uuid)
    end
  end

  @doc false
  def run_with_store(root, store, target) do
    uuid = if uuid?(target), do: target, else: resolve_path(root, target, store)
    inspect_document_with_store(uuid, store)
  end

  defp resolve_target(root, relative_path, target) do
    if uuid?(target) do
      target
    else
      path = join_paths(relative_path, target)
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
  end

  defp resolve_path(root, path, store) do
    loader = fn uuid ->
      alias Commonplace.Tree.Schema

      case Commonplace.Store.CommitStore.latest_commit(store, uuid) do
        {:ok, commit} ->
          doc = Schema.new_schema()
          {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
          doc

        :none ->
          Schema.new_schema()
      end
    end

    case Walk.resolve_path(root, path, loader) do
      {:ok, uuid} ->
        uuid

      {:error, reason} ->
        IO.puts(:stderr, "Resolve failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp inspect_document(uuid) do
    case CommitStoreClient.latest_commit(uuid) do
      {:ok, commit} ->
        print_inspection(uuid, commit)

      :none ->
        IO.puts(:stderr, "No commits found for: #{uuid}")
        System.halt(1)
    end
  end

  defp inspect_document_with_store(uuid, store) do
    case Commonplace.Store.CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        print_inspection(uuid, commit)

      :none ->
        IO.puts(:stderr, "No commits found for: #{uuid}")
    end
  end

  defp print_inspection(uuid, commit) do
    doc = Yelixer.Doc.new()
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)

    commit_hex = Base.encode16(commit.id, case: :lower) |> String.slice(0, 12)

    IO.puts("Document: #{uuid}")
    IO.puts("Commit:   #{commit_hex}")
    IO.puts("")

    # Type information
    IO.puts("Types:")

    if map_size(Yelixer.Doc.types(doc)) == 0 do
      IO.puts("  (none)")
    else
      Enum.each(Yelixer.Doc.types(doc), fn {name, type_ref} ->
        IO.puts("  #{name}: #{type_ref}")
      end)
    end

    # Content type (commonplace layer)
    content_type = ContentType.get_type(doc)

    if content_type do
      IO.puts("")
      IO.puts("Content type: #{content_type}")
      content = ContentType.get_content(doc)
      content_preview = preview_content(content_type, content)
      IO.puts("Content preview: #{content_preview}")
    end

    IO.puts("")

    # State vector
    state_vector = Yelixer.Doc.state_vector(doc)

    IO.puts("State vector (#{map_size(state_vector.clocks)} client(s)):")

    Enum.each(state_vector.clocks, fn {client_id, clock} ->
      IO.puts("  client #{client_id}: clock #{clock}")
    end)

    # Block stats
    IO.puts("")

    # CX-w1fw: materialized view — recently-pushed blocks may still be
    # sitting in client_pending rather than doc.store.clients.
    all_blocks = Yelixer.Doc.all_items(doc)
    total_blocks = length(all_blocks)
    total_items = all_blocks |> Enum.map(& &1.length) |> Enum.sum()

    IO.puts("Blocks: #{total_blocks}")
    IO.puts("Items: #{total_items}")

    # Delete set
    delete_count = map_size(doc.delete_set.clients)
    IO.puts("Delete set: #{delete_count} client(s)")
  end

  defp preview_content(:text, text) when is_binary(text) do
    text
    |> String.replace("\n", "\\n")
    |> then(fn s ->
      if String.length(s) > 80 do
        String.slice(s, 0, 80) <> "..."
      else
        s
      end
    end)
  end

  defp preview_content(:map, map) when is_map(map) do
    keys = Map.keys(map) |> Enum.join(", ")
    "{#{keys}}"
  end

  defp preview_content(:array, list) when is_list(list) do
    "[#{length(list)} items]"
  end

  defp preview_content(_, content), do: inspect(content, limit: 5)

end
