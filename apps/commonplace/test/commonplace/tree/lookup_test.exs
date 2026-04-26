defmodule Commonplace.Tree.LookupTest do
  @moduledoc """
  CX-j6ul (sub-bead ii of CX-jfwv M4): substrate-tier lookup-and-extract
  primitive. Lifted from Chat.Rooms.lookup so chat (and any future
  view-type) can resolve a directory path then extract named children
  in one composed call.

  Generic across domains — non-chat fixtures prove substrate-tier.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{Lookup, Schema}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_tree_lookup_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"})

      Commonplace.Tree.DocCache.clear()
      File.rm_rf!(dir)
    end)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, update, nil)

    %{root: root_uuid}
  end

  defp mint_dir(parent_uuid, name) do
    dir_uuid = UUID.uuid4()
    dir_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(dir_doc)
    CommitStoreClient.create_chained_commit(dir_uuid, update)

    parent_doc = load_schema(parent_uuid)
    parent_doc = Schema.add_directory(parent_doc, name, dir_uuid)
    update = Yelixer.Encoding.encode_update(parent_doc)
    CommitStoreClient.create_chained_commit(parent_uuid, update)

    dir_uuid
  end

  defp mint_file(parent_uuid, name) do
    file_uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStoreClient.create_chained_commit(file_uuid, update)

    parent_doc = load_schema(parent_uuid)
    parent_doc = Schema.add_file(parent_doc, name, file_uuid)
    update = Yelixer.Encoding.encode_update(parent_doc)
    CommitStoreClient.create_chained_commit(parent_uuid, update)

    file_uuid
  end

  defp load_schema(uuid) do
    case Commonplace.Tree.DocBuilder.reconstruct_snapshot(CommitStoreClient, uuid) do
      {:ok, doc} -> doc
      :none -> Schema.new_schema()
    end
  end

  describe "lookup_doc_by_path/3" do
    test "resolves a single-segment path", %{root: root} do
      foo_uuid = mint_dir(root, "foo")

      assert {:ok, ^foo_uuid} = Lookup.lookup_doc_by_path(root, "foo")
    end

    test "resolves a multi-segment path", %{root: root} do
      foo_uuid = mint_dir(root, "foo")
      bar_uuid = mint_dir(foo_uuid, "bar")

      assert {:ok, ^bar_uuid} = Lookup.lookup_doc_by_path(root, "foo/bar")
    end

    test "leading and trailing slashes work", %{root: root} do
      foo_uuid = mint_dir(root, "foo")

      assert {:ok, ^foo_uuid} = Lookup.lookup_doc_by_path(root, "/foo")
      assert {:ok, ^foo_uuid} = Lookup.lookup_doc_by_path(root, "foo/")
      assert {:ok, ^foo_uuid} = Lookup.lookup_doc_by_path(root, "/foo/")
    end

    test "missing intermediate dir returns {:error, :not_found}", %{root: root} do
      _foo_uuid = mint_dir(root, "foo")

      assert {:error, :not_found} = Lookup.lookup_doc_by_path(root, "missing/bar")
    end

    test "missing final segment returns {:error, :not_found}", %{root: root} do
      _foo_uuid = mint_dir(root, "foo")

      assert {:error, :not_found} = Lookup.lookup_doc_by_path(root, "foo/missing")
    end
  end

  describe "extract_named_children/3" do
    test "extracts UUIDs for a list of named entries", %{root: root} do
      foo_uuid = mint_dir(root, "foo")
      a_uuid = mint_file(foo_uuid, "a")
      b_uuid = mint_file(foo_uuid, "b")
      c_uuid = mint_file(foo_uuid, "c")

      assert {:ok, %{} = result} =
               Lookup.extract_named_children(foo_uuid, ["a", "b", "c"])

      assert result["a"] == a_uuid
      assert result["b"] == b_uuid
      assert result["c"] == c_uuid
    end

    test "returns {:error, {:not_found, name}} when a named child is missing",
         %{root: root} do
      foo_uuid = mint_dir(root, "foo")
      _a_uuid = mint_file(foo_uuid, "a")

      assert {:error, {:not_found, "missing"}} =
               Lookup.extract_named_children(foo_uuid, ["a", "missing"])
    end

    test "empty names list returns empty map (vacuous truth)", %{root: root} do
      foo_uuid = mint_dir(root, "foo")
      assert {:ok, %{}} = Lookup.extract_named_children(foo_uuid, [])
    end
  end

  describe "lookup_path_and_extract/3 — composed (chat-tier convenience)" do
    test "resolves path + extracts named children in one call", %{root: root} do
      foo_uuid = mint_dir(root, "foo")
      bar_uuid = mint_dir(foo_uuid, "bar")
      a_uuid = mint_file(bar_uuid, "a")
      b_uuid = mint_file(bar_uuid, "b")

      assert {:ok, %{"a" => ^a_uuid, "b" => ^b_uuid}} =
               Lookup.lookup_path_and_extract(root, "foo/bar", ["a", "b"])
    end

    test "missing path → {:error, :not_found} (preserves Chat.Rooms.lookup semantic)",
         %{root: root} do
      assert {:error, :not_found} =
               Lookup.lookup_path_and_extract(root, "no-such-dir", ["a"])
    end

    test "path resolves but child missing → {:error, {:not_found, name}}",
         %{root: root} do
      foo_uuid = mint_dir(root, "foo")
      _a_uuid = mint_file(foo_uuid, "a")

      assert {:error, {:not_found, "missing"}} =
               Lookup.lookup_path_and_extract(root, "foo", ["missing"])
    end
  end

  describe "non-chat synthetic anchor — substrate domain-agnosticism" do
    test "resolves a project/web-app/config path then extracts named files",
         %{root: root} do
      # Synthetic non-chat tree: /projects/web-app/config/{database, env, secrets}
      projects = mint_dir(root, "projects")
      web_app = mint_dir(projects, "web-app")
      config = mint_dir(web_app, "config")

      database = mint_file(config, "database")
      env = mint_file(config, "env")
      secrets = mint_file(config, "secrets")

      assert {:ok, result} =
               Lookup.lookup_path_and_extract(
                 root,
                 "projects/web-app/config",
                 ["database", "env", "secrets"]
               )

      assert result["database"] == database
      assert result["env"] == env
      assert result["secrets"] == secrets
    end
  end
end
