defmodule Commonplace.CLI.IntegrationTest do
  @moduledoc """
  End-to-end integration tests for the CLI.

  These tests run the full flow: init a workspace, import files,
  list directories, and cat file contents.
  """
  use ExUnit.Case

  alias Commonplace.CLI
  alias Commonplace.Tree.{Schema, Walk}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore

  setup do
    # Create a temp workspace and temp source files
    workspace = Path.join(System.tmp_dir!(), "cp_test_ws_#{:rand.uniform(1_000_000)}")
    source = Path.join(System.tmp_dir!(), "cp_test_src_#{:rand.uniform(1_000_000)}")

    File.mkdir_p!(workspace)
    File.mkdir_p!(source)

    on_exit(fn ->
      File.rm_rf!(workspace)
      File.rm_rf!(source)
    end)

    %{workspace: workspace, source: source}
  end

  describe "init" do
    test "creates workspace with root UUID", %{workspace: ws} do
      CLI.ensure_started(ws)

      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(root_uuid, update, nil)
      CLI.set_root_uuid(ws, root_uuid)

      assert CLI.root_uuid(ws) == root_uuid

      # Root schema should be loadable and empty
      doc = CLI.load_schema(root_uuid)
      assert Schema.entries(doc) == %{}
      assert Schema.version(doc) == 1
    end
  end

  describe "full import → ls → cat flow" do
    test "import a directory tree, then list and read files", %{workspace: ws, source: src} do
      # Create source files
      File.write!(Path.join(src, "hello.txt"), "Hello, World!\n")
      File.write!(Path.join(src, "numbers.txt"), "one\ntwo\nthree\n")
      File.mkdir_p!(Path.join(src, "subdir"))
      File.write!(Path.join(src, "subdir/nested.txt"), "I am nested\n")
      File.mkdir_p!(Path.join(src, "subdir/deep"))
      File.write!(Path.join(src, "subdir/deep/leaf.txt"), "leaf content\n")

      # Init workspace
      CLI.ensure_started(ws)
      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(root_uuid, update, nil)
      CLI.set_root_uuid(ws, root_uuid)

      # Import
      root_doc = CLI.load_schema(root_uuid)
      root_doc = import_directory(src, root_doc)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(root_uuid, update, nil)

      # ls root
      loader = &CLI.load_schema/1
      {:ok, root_entries} = Walk.list_path(root_uuid, "", loader)
      root_names = Enum.map(root_entries, & &1.name) |> Enum.sort()
      assert root_names == ["hello.txt", "numbers.txt", "subdir"]

      # Verify types
      root_types = Map.new(root_entries, &{&1.name, &1.type})
      assert root_types["hello.txt"] == :doc
      assert root_types["numbers.txt"] == :doc
      assert root_types["subdir"] == :dir

      # ls subdir
      {:ok, sub_entries} = Walk.list_path(root_uuid, "subdir", loader)
      sub_names = Enum.map(sub_entries, & &1.name) |> Enum.sort()
      assert sub_names == ["deep", "nested.txt"]

      # ls subdir/deep
      {:ok, deep_entries} = Walk.list_path(root_uuid, "subdir/deep", loader)
      deep_names = Enum.map(deep_entries, & &1.name)
      assert deep_names == ["leaf.txt"]

      # cat hello.txt
      {:ok, hello_uuid} = Walk.resolve_path(root_uuid, "hello.txt", loader)
      hello_content = read_doc_content(hello_uuid)
      assert hello_content == "Hello, World!\n"

      # cat numbers.txt
      {:ok, numbers_uuid} = Walk.resolve_path(root_uuid, "numbers.txt", loader)
      numbers_content = read_doc_content(numbers_uuid)
      assert numbers_content == "one\ntwo\nthree\n"

      # cat subdir/nested.txt
      {:ok, nested_uuid} = Walk.resolve_path(root_uuid, "subdir/nested.txt", loader)
      nested_content = read_doc_content(nested_uuid)
      assert nested_content == "I am nested\n"

      # cat subdir/deep/leaf.txt
      {:ok, leaf_uuid} = Walk.resolve_path(root_uuid, "subdir/deep/leaf.txt", loader)
      leaf_content = read_doc_content(leaf_uuid)
      assert leaf_content == "leaf content\n"
    end

    test "import preserves file content exactly", %{workspace: ws, source: src} do
      # Create a file with special content
      content = "line 1\n\ttabbed\n  spaced\n\"quoted\"\n"
      File.write!(Path.join(src, "special.txt"), content)

      CLI.ensure_started(ws)
      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(root_uuid, update, nil)
      CLI.set_root_uuid(ws, root_uuid)

      root_doc = CLI.load_schema(root_uuid)
      root_doc = import_directory(src, root_doc)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(root_uuid, update, nil)

      loader = &CLI.load_schema/1
      {:ok, uuid} = Walk.resolve_path(root_uuid, "special.txt", loader)
      assert read_doc_content(uuid) == content
    end

    test "import handles empty directories", %{workspace: ws, source: src} do
      File.mkdir_p!(Path.join(src, "empty"))
      File.write!(Path.join(src, "file.txt"), "content")

      CLI.ensure_started(ws)
      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(root_uuid, update, nil)
      CLI.set_root_uuid(ws, root_uuid)

      root_doc = CLI.load_schema(root_uuid)
      root_doc = import_directory(src, root_doc)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(root_uuid, update, nil)

      loader = &CLI.load_schema/1
      {:ok, entries} = Walk.list_path(root_uuid, "", loader)
      names = Enum.map(entries, & &1.name) |> Enum.sort()
      assert names == ["empty", "file.txt"]

      # Empty dir should have no children
      {:ok, empty_entries} = Walk.list_path(root_uuid, "empty", loader)
      assert empty_entries == []
    end

    test "reachability covers all imported documents", %{workspace: ws, source: src} do
      File.write!(Path.join(src, "a.txt"), "aaa")
      File.mkdir_p!(Path.join(src, "sub"))
      File.write!(Path.join(src, "sub/b.txt"), "bbb")

      CLI.ensure_started(ws)
      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(root_uuid, update, nil)
      CLI.set_root_uuid(ws, root_uuid)

      root_doc = CLI.load_schema(root_uuid)
      root_doc = import_directory(src, root_doc)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(root_uuid, update, nil)

      loader = &CLI.load_schema/1
      reachable = Walk.reachable_uuids(root_uuid, loader)

      # root + sub dir + a.txt + b.txt = 4 UUIDs
      assert MapSet.size(reachable) == 4
      assert MapSet.member?(reachable, root_uuid)
    end

    test "resolve_path returns error for nonexistent file", %{workspace: ws} do
      CLI.ensure_started(ws)
      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(root_uuid, update, nil)
      CLI.set_root_uuid(ws, root_uuid)

      loader = &CLI.load_schema/1
      assert {:error, {:not_found, "missing.txt"}} =
               Walk.resolve_path(root_uuid, "missing.txt", loader)
    end
  end

  # --- Helpers ---

  defp import_directory(dir_path, schema_doc) do
    File.ls!(dir_path)
    |> Enum.sort()
    |> Enum.reduce(schema_doc, fn name, schema ->
      full_path = Path.join(dir_path, name)

      cond do
        File.dir?(full_path) ->
          sub_uuid = UUID.uuid4()
          sub_schema = Schema.new_schema()
          sub_schema = import_directory(full_path, sub_schema)
          update = Yelixer.Encoding.encode_update(sub_schema)
          CommitStore.create_commit(sub_uuid, update, nil)
          Schema.add_directory(schema, name, sub_uuid)

        File.regular?(full_path) ->
          file_uuid = UUID.uuid4()
          content = File.read!(full_path)
          doc = Yelixer.Doc.new()
          doc = ContentType.create(doc, :text, name)
          doc = ContentType.insert_text(doc, 0, content)
          update = Yelixer.Encoding.encode_update(doc)
          CommitStore.create_commit(file_uuid, update, nil)
          Schema.add_file(schema, name, file_uuid)

        true ->
          schema
      end
    end)
  end

  defp read_doc_content(uuid) do
    {:ok, commit} = CommitStore.latest_commit(uuid)
    doc = Yelixer.Doc.new()
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
    ContentType.get_content(doc)
  end
end
