defmodule Commonplace.CLI.Import do
  @moduledoc "Import files from disk into the document tree."

  alias Commonplace.CLI
  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStoreClient, as: CommitStore

  def run(data_dir, args) do
    CLI.ensure_started(data_dir)
    root = CLI.root_uuid(data_dir)

    unless root do
      IO.puts(:stderr, "Not a commonplace workspace. Run 'commonplace init' first.")
      System.halt(1)
    end

    case args do
      [] ->
        IO.puts(:stderr, "Usage: commonplace import <directory>")
        System.halt(1)

      [source_dir | _] ->
        unless File.dir?(source_dir) do
          IO.puts(:stderr, "Not a directory: #{source_dir}")
          System.halt(1)
        end

        root_doc = CLI.load_schema(root)
        root_doc = import_directory(source_dir, root_doc)
        update = Yelixer.Encoding.encode_update(root_doc)
        CommitStore.create_commit(root, update, nil)

        IO.puts("Imported #{source_dir} into workspace")
    end
  end

  defp import_directory(dir_path, schema_doc) do
    File.ls!(dir_path)
    |> Enum.sort()
    |> Enum.reduce(schema_doc, fn name, schema ->
      full_path = Path.join(dir_path, name)

      cond do
        File.dir?(full_path) ->
          # Create a schema doc for the subdirectory
          sub_uuid = UUID.uuid4()
          sub_schema = Schema.new_schema()
          sub_schema = import_directory(full_path, sub_schema)
          update = Yelixer.Encoding.encode_update(sub_schema)
          CommitStore.create_commit(sub_uuid, update, nil)

          Schema.add_directory(schema, name, sub_uuid)

        File.regular?(full_path) ->
          file_uuid = UUID.uuid4()
          import_file(full_path, file_uuid)
          Schema.add_file(schema, name, file_uuid)

        true ->
          # Skip symlinks, devices, etc.
          schema
      end
    end)
  end

  defp import_file(file_path, uuid) do
    content = File.read!(file_path)

    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, Path.basename(file_path))

    # Skip insert for empty files (Text.insert doesn't accept empty strings)
    doc = if content != "", do: ContentType.insert_text(doc, 0, content), else: doc

    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(uuid, update, nil)

    IO.puts("  + #{file_path} (#{uuid})")
  end
end
