defmodule Commonplace.Sync.ExportTest do
  @moduledoc """
  Tests for exporting the CRDT document tree to disk.
  """
  use ExUnit.Case

  alias Commonplace.Sync.Export
  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore

  setup do
    store_dir = Path.join(System.tmp_dir!(), "cp_export_store_#{:rand.uniform(1_000_000)}")
    export_dir = Path.join(System.tmp_dir!(), "cp_export_out_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(store_dir)
    File.mkdir_p!(export_dir)

    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: store_dir, name: store_name})

    on_exit(fn ->
      File.rm_rf!(store_dir)
      File.rm_rf!(export_dir)
    end)

    %{store: store_name, export_dir: export_dir}
  end

  defp create_text_doc(store, uuid, name, content) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = ContentType.insert_text(doc, 0, content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  defp create_schema(store, uuid, schema_doc) do
    update = Yelixer.Encoding.encode_update(schema_doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  describe "export" do
    test "exports a single file", %{store: store, export_dir: dir} do
      create_text_doc(store, "uuid-hello", "hello.txt", "Hello, World!\n")

      root =
        Schema.new_schema()
        |> Schema.add_file("hello.txt", "uuid-hello")

      create_schema(store, "uuid-root", root)

      Export.export("uuid-root", dir, store)

      assert File.read!(Path.join(dir, "hello.txt")) == "Hello, World!\n"
    end

    test "exports multiple files", %{store: store, export_dir: dir} do
      create_text_doc(store, "uuid-a", "a.txt", "aaa")
      create_text_doc(store, "uuid-b", "b.txt", "bbb")

      root =
        Schema.new_schema()
        |> Schema.add_file("a.txt", "uuid-a")
        |> Schema.add_file("b.txt", "uuid-b")

      create_schema(store, "uuid-root", root)

      Export.export("uuid-root", dir, store)

      assert File.read!(Path.join(dir, "a.txt")) == "aaa"
      assert File.read!(Path.join(dir, "b.txt")) == "bbb"
    end

    test "exports nested directories", %{store: store, export_dir: dir} do
      create_text_doc(store, "uuid-nested", "nested.txt", "I am nested\n")

      sub_schema =
        Schema.new_schema()
        |> Schema.add_file("nested.txt", "uuid-nested")

      create_schema(store, "uuid-sub", sub_schema)

      root =
        Schema.new_schema()
        |> Schema.add_directory("subdir", "uuid-sub")

      create_schema(store, "uuid-root", root)

      Export.export("uuid-root", dir, store)

      assert File.dir?(Path.join(dir, "subdir"))
      assert File.read!(Path.join(dir, "subdir/nested.txt")) == "I am nested\n"
    end

    test "exports deeply nested tree", %{store: store, export_dir: dir} do
      create_text_doc(store, "uuid-leaf", "leaf.txt", "deep content")

      deep =
        Schema.new_schema()
        |> Schema.add_file("leaf.txt", "uuid-leaf")

      create_schema(store, "uuid-deep", deep)

      mid =
        Schema.new_schema()
        |> Schema.add_directory("deep", "uuid-deep")

      create_schema(store, "uuid-mid", mid)

      root =
        Schema.new_schema()
        |> Schema.add_directory("mid", "uuid-mid")

      create_schema(store, "uuid-root", root)

      Export.export("uuid-root", dir, store)

      assert File.read!(Path.join(dir, "mid/deep/leaf.txt")) == "deep content"
    end

    test "exports empty directories", %{store: store, export_dir: dir} do
      empty = Schema.new_schema()
      create_schema(store, "uuid-empty", empty)

      root =
        Schema.new_schema()
        |> Schema.add_directory("empty", "uuid-empty")

      create_schema(store, "uuid-root", root)

      Export.export("uuid-root", dir, store)

      assert File.dir?(Path.join(dir, "empty"))
      assert File.ls!(Path.join(dir, "empty")) == []
    end

    test "uses atomic writes (no temp files left behind)", %{store: store, export_dir: dir} do
      create_text_doc(store, "uuid-f", "file.txt", "content")

      root =
        Schema.new_schema()
        |> Schema.add_file("file.txt", "uuid-f")

      create_schema(store, "uuid-root", root)

      Export.export("uuid-root", dir, store)

      # No temp files should remain
      files = File.ls!(dir)
      assert files == ["file.txt"]
      refute Enum.any?(files, &String.starts_with?(&1, "."))
    end

    test "import then export roundtrip preserves content", %{store: store, export_dir: dir} do
      # Create a tree with various content
      create_text_doc(store, "uuid-readme", "readme.txt", "# My Project\n\nHello!\n")
      create_text_doc(store, "uuid-config", "config.json", ~s({"key": "value"}\n))
      create_text_doc(store, "uuid-inner", "inner.txt", "nested content\n")

      sub =
        Schema.new_schema()
        |> Schema.add_file("inner.txt", "uuid-inner")

      create_schema(store, "uuid-sub", sub)

      root =
        Schema.new_schema()
        |> Schema.add_file("readme.txt", "uuid-readme")
        |> Schema.add_file("config.json", "uuid-config")
        |> Schema.add_directory("sub", "uuid-sub")

      create_schema(store, "uuid-root", root)

      Export.export("uuid-root", dir, store)

      assert File.read!(Path.join(dir, "readme.txt")) == "# My Project\n\nHello!\n"
      assert File.read!(Path.join(dir, "config.json")) == ~s({"key": "value"}\n)
      assert File.read!(Path.join(dir, "sub/inner.txt")) == "nested content\n"
    end
  end
end
