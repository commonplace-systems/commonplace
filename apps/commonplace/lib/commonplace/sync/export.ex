defmodule Commonplace.Sync.Export do
  @moduledoc """
  Export the CRDT document tree to disk.

  Walks the schema tree, loads each document, and writes content
  to the filesystem using atomic writes (temp file + rename).
  """

  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore

  @doc """
  Export a document tree to a directory on disk.

  Walks the schema tree starting at `root_uuid`, loading documents
  from `store` and writing their content to `output_dir`.
  """
  def export(root_uuid, output_dir, store \\ CommitStore) do
    File.mkdir_p!(output_dir)
    schema_doc = load_schema(root_uuid, store)
    export_entries(schema_doc, output_dir, store)
  end

  defp export_entries(schema_doc, dir, store) do
    Schema.list_entries(schema_doc)
    |> Enum.each(fn entry ->
      path = Path.join(dir, entry.name)

      case entry.type do
        :dir ->
          File.mkdir_p!(path)
          sub_schema = load_schema(entry.node_id, store)
          export_entries(sub_schema, path, store)

        :doc ->
          content = load_content(entry.node_id, store)
          atomic_write(path, content)
      end
    end)
  end

  defp load_schema(uuid, store) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end

  defp load_content(uuid, store) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Yelixer.Doc.new()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)

        case ContentType.get_type(doc) do
          :text -> ContentType.get_content(doc) || ""
          _ -> ContentType.get_content(doc) |> inspect()
        end

      :none ->
        ""
    end
  end

  @doc """
  Write content to a file atomically.

  Writes to a temp file, fsyncs, then renames over the target.
  Readers see either the old content or the new content, never partial.
  """
  def atomic_write(path, content) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    tmp_path = Path.join(dir, ".#{Path.basename(path)}.tmp.#{System.pid()}")

    try do
      File.write!(tmp_path, content)
      # fsync the file
      case :file.open(String.to_charlist(tmp_path), [:read]) do
        {:ok, fd} ->
          :file.datasync(fd)
          :file.close(fd)
        {:error, _} ->
          :ok
      end
      # Atomic rename
      File.rename!(tmp_path, path)
    rescue
      error ->
        # Clean up temp file on failure
        File.rm(tmp_path)
        reraise error, __STACKTRACE__
    end
  end
end
