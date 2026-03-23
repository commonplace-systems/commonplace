defmodule Commonplace.CLI.UuidTest do
  @moduledoc """
  Tests for commonplace uuid — resolve a path to its document UUID.
  """
  use ExUnit.Case

  alias Commonplace.Tree.{Schema, Walk}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_uuid_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_uuid_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    root_uuid = UUID.uuid4()

    # Create a file entry
    file_uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "hello.txt")
    doc = ContentType.insert_text(doc, 0, "hello")
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store_name, file_uuid, update, nil)

    # Create root schema with the file
    root_doc = Schema.new_schema()
    root_doc = Schema.add_file(root_doc, "hello.txt", file_uuid)
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{root: root_uuid, file_uuid: file_uuid, store: store_name, dir: dir}
  end

  describe "resolve_path logic used by uuid command" do
    test "resolves file path to UUID", %{root: root, file_uuid: file_uuid, store: store} do
      loader = &load_schema(&1, store)
      assert {:ok, ^file_uuid} = Walk.resolve_path(root, "hello.txt", loader)
    end

    test "resolves empty path to root UUID", %{root: root, store: store} do
      loader = &load_schema(&1, store)
      assert {:ok, ^root} = Walk.resolve_path(root, "", loader)
    end

    test "returns error for missing path", %{root: root, store: store} do
      loader = &load_schema(&1, store)
      assert {:error, {:not_found, "missing.txt"}} = Walk.resolve_path(root, "missing.txt", loader)
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
