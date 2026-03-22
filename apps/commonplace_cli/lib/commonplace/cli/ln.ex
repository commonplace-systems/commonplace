defmodule Commonplace.CLI.Ln do
  @moduledoc """
  CRDT-native hardlinks — make two paths point to the same document.

  Like unix hardlinks: no "original" vs "link", both are equal
  references. The document exists as long as any schema entry
  references its UUID.
  """

  alias Commonplace.CLI
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore

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

          {:error, :not_found} ->
            IO.puts(:stderr, "Source not found: #{source}")
            System.halt(1)
        end

      _ ->
        IO.puts(:stderr, "Usage: commonplace ln <source> <target>")
        System.halt(1)
    end
  end

  @doc "Create a CRDT hardlink: target gets the same UUID as source."
  def link(source, target, root_uuid, store \\ CommitStore) do
    root_doc = load_schema(root_uuid, store)

    case Schema.get_entry(root_doc, source) do
      {:ok, entry} ->
        # Add target with the same UUID
        root_doc = load_schema(root_uuid, store)
        root_doc = Schema.add_file(root_doc, target, entry.node_id)
        update = Yelixer.Encoding.encode_update(root_doc)
        CommitStore.create_commit(store, root_uuid, update, nil)
        :ok

      :error ->
        {:error, :not_found}
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
