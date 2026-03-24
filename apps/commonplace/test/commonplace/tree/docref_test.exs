defmodule Commonplace.Tree.DocrefTest do
  @moduledoc """
  Tests for Docref — flexible document reference resolution.

  Docrefs resolve strings to UUIDs:
  - Raw UUID → returned directly
  - Single name → looked up in root schema
  - Multi-segment path → walked through nested schemas
  """
  use ExUnit.Case

  alias Commonplace.Tree.{Docref, Schema}
  alias Commonplace.Store.CommitStore

  @uuid_example "550e8400-e29b-41d4-a716-446655440000"

  describe "UUID passthrough" do
    test "raw UUID resolves directly without store or root" do
      assert {:ok, @uuid_example} = Docref.resolve(@uuid_example, root_uuid: nil, loader: nil)
    end

    test "uppercase UUID resolves" do
      upper = String.upcase(@uuid_example)
      assert {:ok, ^upper} = Docref.resolve(upper, root_uuid: nil, loader: nil)
    end

    test "rejects UUID-like strings with wrong length" do
      assert {:error, _} = Docref.resolve("550e8400-e29b-41d4-a716", root_uuid: nil, loader: nil)
    end
  end

  describe "name resolution" do
    setup do
      dir = Path.join(System.tmp_dir!(), "docref_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
      start_supervised!({CommitStore, data_dir: dir, name: store_name})
      on_exit(fn -> File.rm_rf!(dir) end)

      # Root schema with two entries
      root_schema =
        Schema.new_schema()
        |> Schema.add_directory("main", "uuid-main")
        |> Schema.add_file("config.txt", "uuid-config")

      commit_schema(store_name, "uuid-root", root_schema)

      loader = &load_schema(store_name, &1)

      %{store: store_name, root: "uuid-root", loader: loader}
    end

    test "single name resolves via root schema", %{root: root, loader: loader} do
      assert {:ok, "uuid-main"} = Docref.resolve("main", root_uuid: root, loader: loader)
    end

    test "single name resolves a file entry", %{root: root, loader: loader} do
      assert {:ok, "uuid-config"} = Docref.resolve("config.txt", root_uuid: root, loader: loader)
    end

    test "missing name returns error", %{root: root, loader: loader} do
      assert {:error, {:not_found, "nonexistent"}} =
               Docref.resolve("nonexistent", root_uuid: root, loader: loader)
    end
  end

  describe "path resolution" do
    setup do
      dir = Path.join(System.tmp_dir!(), "docref_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
      start_supervised!({CommitStore, data_dir: dir, name: store_name})
      on_exit(fn -> File.rm_rf!(dir) end)

      # Build tree:
      #   root/
      #     main/           (dir → uuid-main)
      #       docs/         (dir → uuid-docs)
      #         plans/      (dir → uuid-plans)
      #           todo.txt  (doc → uuid-todo)
      #     config.txt      (doc → uuid-config)

      plans_schema =
        Schema.new_schema()
        |> Schema.add_file("todo.txt", "uuid-todo")

      commit_schema(store_name, "uuid-plans", plans_schema)

      docs_schema =
        Schema.new_schema()
        |> Schema.add_directory("plans", "uuid-plans")

      commit_schema(store_name, "uuid-docs", docs_schema)

      main_schema =
        Schema.new_schema()
        |> Schema.add_directory("docs", "uuid-docs")

      commit_schema(store_name, "uuid-main", main_schema)

      root_schema =
        Schema.new_schema()
        |> Schema.add_directory("main", "uuid-main")
        |> Schema.add_file("config.txt", "uuid-config")

      commit_schema(store_name, "uuid-root", root_schema)

      loader = &load_schema(store_name, &1)

      %{store: store_name, root: "uuid-root", loader: loader}
    end

    test "multi-segment path walks through nested schemas", %{root: root, loader: loader} do
      assert {:ok, "uuid-plans"} =
               Docref.resolve("main/docs/plans", root_uuid: root, loader: loader)
    end

    test "path resolves to a leaf file", %{root: root, loader: loader} do
      assert {:ok, "uuid-todo"} =
               Docref.resolve("main/docs/plans/todo.txt", root_uuid: root, loader: loader)
    end

    test "path with trailing slash is trimmed", %{root: root, loader: loader} do
      assert {:ok, "uuid-docs"} =
               Docref.resolve("main/docs/", root_uuid: root, loader: loader)
    end

    test "missing intermediate segment returns error", %{root: root, loader: loader} do
      assert {:error, {:not_found, "missing"}} =
               Docref.resolve("main/missing/plans", root_uuid: root, loader: loader)
    end

    test "traversing through a file returns error", %{root: root, loader: loader} do
      assert {:error, {:not_a_directory, "config.txt"}} =
               Docref.resolve("config.txt/sub", root_uuid: root, loader: loader)
    end
  end

  describe "error cases" do
    test "nil root_uuid with name returns error" do
      assert {:error, :no_root} = Docref.resolve("main", root_uuid: nil, loader: fn _ -> nil end)
    end

    test "empty string returns error" do
      assert {:error, :empty_ref} = Docref.resolve("", root_uuid: "uuid-root", loader: nil)
    end
  end

  # --- Helpers ---

  defp commit_schema(store, uuid, doc) do
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  defp load_schema(store, uuid) do
    {:ok, commit} = CommitStore.latest_commit(store, uuid)
    doc = Schema.new_schema()
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
    doc
  end
end
