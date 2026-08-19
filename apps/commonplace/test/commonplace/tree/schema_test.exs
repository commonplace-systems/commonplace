defmodule Commonplace.Tree.SchemaTest do
  @moduledoc """
  Tests for the document tree schema — how directories map names to UUIDs.

  Schema docs are YMaps with structure:
    version: 1
    root: YMap {
      type: "dir"
      entries: YMap {
        "name": YMap { type: "doc"|"dir", node_id: "uuid" }
      }
    }
  """
  use ExUnit.Case

  alias Commonplace.Tree.Schema

  describe "creating schemas" do
    test "creates a new empty schema document" do
      doc = Schema.new_schema()

      assert Schema.version(doc) == 1
      assert Schema.entries(doc) == %{}
    end
  end

  describe "adding entries" do
    test "add a file entry" do
      doc = Schema.new_schema()
      doc = Schema.add_file(doc, "notes.txt", "uuid-1")

      entries = Schema.entries(doc)

      assert entries == %{
               "notes.txt" => %{"type" => "doc", "node_id" => "uuid-1", "sync" => true}
             }
    end

    test "add a directory entry" do
      doc = Schema.new_schema()
      doc = Schema.add_directory(doc, "subdir", "uuid-2")

      entries = Schema.entries(doc)
      assert entries == %{"subdir" => %{"type" => "dir", "node_id" => "uuid-2", "sync" => true}}
    end

    test "add multiple entries" do
      doc =
        Schema.new_schema()
        |> Schema.add_file("a.txt", "uuid-a")
        |> Schema.add_file("b.txt", "uuid-b")
        |> Schema.add_directory("sub", "uuid-s")

      entries = Schema.entries(doc)
      assert map_size(entries) == 3
      assert entries["a.txt"]["type"] == "doc"
      assert entries["b.txt"]["type"] == "doc"
      assert entries["sub"]["type"] == "dir"
    end
  end

  describe "reading entries" do
    test "get_entry returns a single entry" do
      doc =
        Schema.new_schema()
        |> Schema.add_file("notes.txt", "uuid-1")

      assert {:ok, entry} = Schema.get_entry(doc, "notes.txt")
      assert entry.type == :doc
      assert entry.node_id == "uuid-1"
      assert entry.name == "notes.txt"
    end

    test "get_entry for directory" do
      doc =
        Schema.new_schema()
        |> Schema.add_directory("subdir", "uuid-2")

      assert {:ok, entry} = Schema.get_entry(doc, "subdir")
      assert entry.type == :dir
      assert entry.node_id == "uuid-2"
    end

    test "get_entry returns error for missing entry" do
      doc = Schema.new_schema()
      assert :error = Schema.get_entry(doc, "missing")
    end

    test "list_entries returns all entries as structs" do
      doc =
        Schema.new_schema()
        |> Schema.add_file("a.txt", "uuid-a")
        |> Schema.add_directory("sub", "uuid-s")

      entries = Schema.list_entries(doc)
      assert length(entries) == 2

      names = Enum.map(entries, & &1.name) |> Enum.sort()
      assert names == ["a.txt", "sub"]
    end
  end

  describe "removing entries" do
    test "remove an entry by name" do
      doc =
        Schema.new_schema()
        |> Schema.add_file("a.txt", "uuid-a")
        |> Schema.add_file("b.txt", "uuid-b")

      doc = Schema.remove_entry(doc, "a.txt")

      entries = Schema.entries(doc)
      assert map_size(entries) == 1
      assert entries["b.txt"] != nil
      assert entries["a.txt"] == nil
    end
  end

  describe "resolve path" do
    test "resolve a simple one-segment path" do
      doc =
        Schema.new_schema()
        |> Schema.add_file("notes.txt", "uuid-1")

      assert {:ok, "uuid-1"} = Schema.resolve_name(doc, "notes.txt")
    end

    test "resolve returns error for missing name" do
      doc = Schema.new_schema()
      assert :error = Schema.resolve_name(doc, "missing")
    end
  end

  describe "commit/reconstruct roundtrip" do
    setup do
      dir = Path.join(System.tmp_dir!(), "commonplace_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      name = :"commit_store_#{:rand.uniform(1_000_000)}"
      start_supervised!({Commonplace.Store.CommitStore, data_dir: dir, name: name})
      on_exit(fn -> File.rm_rf!(dir) end)
      %{store: name}
    end

    test "schema survives commit and reconstruction", %{store: store} do
      doc =
        Schema.new_schema()
        |> Schema.add_file("notes.txt", "uuid-1")
        |> Schema.add_directory("subdir", "uuid-2")

      # Commit
      update = Yelixer.Encoding.encode_update(doc)
      commit = Commonplace.Store.CommitStore.create_commit(store, "schema-doc", update, nil)

      # Reconstruct
      {:ok, fetched} = Commonplace.Store.CommitStore.get_commit(store, commit.id)
      reconstructed = Schema.new_schema()
      {:ok, reconstructed} = Yelixer.Encoding.apply_update(reconstructed, fetched.update)

      entries = Schema.entries(reconstructed)
      assert entries["notes.txt"]["node_id"] == "uuid-1"
      assert entries["notes.txt"]["type"] == "doc"
      assert entries["subdir"]["node_id"] == "uuid-2"
      assert entries["subdir"]["type"] == "dir"
    end
  end
end
