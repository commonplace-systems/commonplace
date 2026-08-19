defmodule Commonplace.Tree.WalkTest do
  @moduledoc """
  Tests for walking the document tree across schema docs.

  Each schema doc is a separate Yelixer.Doc stored in the CommitStore.
  Walking resolves paths like "repos/myrepo/main/notes.txt" by loading
  schema docs at each level and following node_id references.
  """
  use ExUnit.Case

  alias Commonplace.Tree.{Schema, Walk}
  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "commonplace_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    # Build a tree:
    #   root/
    #     repos/          (dir → uuid-repos)
    #       myrepo/       (dir → uuid-myrepo)
    #         main/        (dir → uuid-main)
    #           notes.txt  (doc → uuid-notes)
    #           data.json  (doc → uuid-data)
    #     config.txt      (doc → uuid-config)

    # notes.txt schema (leaf, no children)
    main_schema =
      Schema.new_schema()
      |> Schema.add_file("notes.txt", "uuid-notes")
      |> Schema.add_file("data.json", "uuid-data")

    commit_schema(store_name, "uuid-main", main_schema)

    # myrepo schema
    myrepo_schema =
      Schema.new_schema()
      |> Schema.add_directory("main", "uuid-main")

    commit_schema(store_name, "uuid-myrepo", myrepo_schema)

    # repos schema
    repos_schema =
      Schema.new_schema()
      |> Schema.add_directory("myrepo", "uuid-myrepo")

    commit_schema(store_name, "uuid-repos", repos_schema)

    # root schema
    root_schema =
      Schema.new_schema()
      |> Schema.add_directory("repos", "uuid-repos")
      |> Schema.add_file("config.txt", "uuid-config")

    commit_schema(store_name, "uuid-root", root_schema)

    %{store: store_name, root: "uuid-root"}
  end

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

  describe "resolve_path/4" do
    test "resolves a single-level path", %{store: store, root: root} do
      loader = &load_schema(store, &1)
      assert {:ok, "uuid-config"} = Walk.resolve_path(root, "config.txt", loader)
    end

    test "resolves a multi-level path to a file", %{store: store, root: root} do
      loader = &load_schema(store, &1)

      assert {:ok, "uuid-notes"} =
               Walk.resolve_path(root, "repos/myrepo/main/notes.txt", loader)
    end

    test "resolves a path to a directory", %{store: store, root: root} do
      loader = &load_schema(store, &1)
      assert {:ok, "uuid-myrepo"} = Walk.resolve_path(root, "repos/myrepo", loader)
    end

    test "returns error for missing path segment", %{store: store, root: root} do
      loader = &load_schema(store, &1)

      assert {:error, {:not_found, "nonexistent"}} =
               Walk.resolve_path(root, "nonexistent", loader)
    end

    test "returns error for missing intermediate directory", %{store: store, root: root} do
      loader = &load_schema(store, &1)

      assert {:error, {:not_found, "missing"}} =
               Walk.resolve_path(root, "repos/missing/main", loader)
    end

    test "returns error when traversing through a file (not a dir)", %{store: store, root: root} do
      loader = &load_schema(store, &1)

      assert {:error, {:not_a_directory, "config.txt"}} =
               Walk.resolve_path(root, "config.txt/sub", loader)
    end

    test "resolves root path (empty string) to root uuid", %{store: store, root: root} do
      loader = &load_schema(store, &1)
      assert {:ok, ^root} = Walk.resolve_path(root, "", loader)
    end
  end

  describe "list_path/4" do
    test "lists children of root", %{store: store, root: root} do
      loader = &load_schema(store, &1)
      {:ok, entries} = Walk.list_path(root, "", loader)

      names = Enum.map(entries, & &1.name) |> Enum.sort()
      assert names == ["config.txt", "repos"]
    end

    test "lists children of a subdirectory", %{store: store, root: root} do
      loader = &load_schema(store, &1)
      {:ok, entries} = Walk.list_path(root, "repos/myrepo/main", loader)

      names = Enum.map(entries, & &1.name) |> Enum.sort()
      assert names == ["data.json", "notes.txt"]
    end

    test "returns error for missing directory", %{store: store, root: root} do
      loader = &load_schema(store, &1)
      assert {:error, _} = Walk.list_path(root, "nonexistent", loader)
    end
  end

  describe "reachable_uuids/3" do
    test "collects all UUIDs reachable from root", %{store: store, root: root} do
      loader = &load_schema(store, &1)
      uuids = Walk.reachable_uuids(root, loader)

      assert MapSet.member?(uuids, "uuid-root")
      assert MapSet.member?(uuids, "uuid-repos")
      assert MapSet.member?(uuids, "uuid-myrepo")
      assert MapSet.member?(uuids, "uuid-main")
      assert MapSet.member?(uuids, "uuid-notes")
      assert MapSet.member?(uuids, "uuid-data")
      assert MapSet.member?(uuids, "uuid-config")
      assert MapSet.size(uuids) == 7
    end
  end
end
