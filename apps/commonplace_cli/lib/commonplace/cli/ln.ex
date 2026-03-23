defmodule Commonplace.CLI.Ln do
  @moduledoc """
  CRDT-native hardlinks — make two paths point to the same document.

  Like unix hardlinks: no "original" vs "link", both are equal
  references. The document exists as long as any schema entry
  references its UUID.

  Supports nested paths like "text-to-telegram/content.txt".
  """

  alias Commonplace.CLI
  alias Commonplace.Tree.{Schema, Walk}
  alias Commonplace.Store.CommitStoreClient, as: CommitStore

  def run(data_dir, _relative_path, args) do
    CLI.ensure_started(data_dir)
    root = CLI.root_uuid(data_dir)

    unless root do
      IO.puts(:stderr, "Not a commonplace workspace.")
      System.halt(1)
    end

    case args do
      [source, target] ->
        case link(source, target, root, CommitStore) do
          :ok ->
            IO.puts("#{source} -> #{target}")

          {:error, :source_not_found} ->
            IO.puts(:stderr, "Source not found: #{source}")
            System.halt(1)

          {:error, :target_dir_not_found} ->
            IO.puts(:stderr, "Target directory not found: #{Path.dirname(target)}")
            System.halt(1)
        end

      _ ->
        IO.puts(:stderr, "Usage: commonplace ln <source> <target>")
        System.halt(1)
    end
  end

  @doc "Create a CRDT hardlink: target gets the same UUID as source."
  def link(source, target, root_uuid, store \\ CommitStore) do
    loader = &load_schema(&1, store)

    # Resolve source to its UUID
    case Walk.resolve_path(root_uuid, source, loader) do
      {:ok, source_uuid} ->
        # Find the target's parent directory and filename
        target_dir = Path.dirname(target)
        target_name = Path.basename(target)

        # Resolve the parent directory UUID
        parent_uuid = if target_dir == "." do
          root_uuid
        else
          case Walk.resolve_path(root_uuid, target_dir, loader) do
            {:ok, uuid} -> uuid
            {:error, _} -> nil
          end
        end

        if parent_uuid do
          # Add target with the same UUID as source
          parent_doc = load_schema(parent_uuid, store)
          parent_doc = Schema.add_file(parent_doc, target_name, source_uuid)
          update = Yelixer.Encoding.encode_update(parent_doc)
          CommitStore.create_commit(store, parent_uuid, update, nil)
          :ok
        else
          {:error, :target_dir_not_found}
        end

      {:error, _} ->
        {:error, :source_not_found}
    end
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
end
