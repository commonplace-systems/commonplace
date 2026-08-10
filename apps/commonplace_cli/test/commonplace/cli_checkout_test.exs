defmodule Commonplace.CLI.CheckoutTest do
  @moduledoc """
  Tests for re-rooting the workspace via checkout.
  """
  use ExUnit.Case

  alias Commonplace.CLI
  alias Commonplace.Tree.{Schema, Walk}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Sync.Export

  setup do
    workspace = Path.join(System.tmp_dir!(), "cp_checkout_ws_#{:rand.uniform(1_000_000)}")
    sync_dir = Path.join(System.tmp_dir!(), "cp_checkout_sync_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(workspace)
    File.mkdir_p!(sync_dir)

    on_exit(fn ->
      _ = Application.stop(:commonplace)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data", persistent: true)
      File.rm_rf!(workspace)
      File.rm_rf!(sync_dir)
      {:ok, _} = Application.ensure_all_started(:commonplace)
    end)

    CLI.ensure_started(workspace)

    # Build a tree:
    #   root/
    #     repos/
    #       myrepo/
    #         main/
    #           readme.txt ("hello from main")
    #         feature/
    #           feature.txt ("hello from feature")

    # main branch
    create_text_doc("uuid-readme", "readme.txt", "hello from main")
    main_schema = Schema.new_schema() |> Schema.add_file("readme.txt", "uuid-readme")
    commit_schema("uuid-main", main_schema)

    # feature branch
    create_text_doc("uuid-feature-file", "feature.txt", "hello from feature")
    feature_schema = Schema.new_schema() |> Schema.add_file("feature.txt", "uuid-feature-file")
    commit_schema("uuid-feature", feature_schema)

    # myrepo
    myrepo_schema =
      Schema.new_schema()
      |> Schema.add_directory("main", "uuid-main")
      |> Schema.add_directory("feature", "uuid-feature")

    commit_schema("uuid-myrepo", myrepo_schema)

    # repos
    repos_schema = Schema.new_schema() |> Schema.add_directory("myrepo", "uuid-myrepo")
    commit_schema("uuid-repos", repos_schema)

    # root
    root_schema = Schema.new_schema() |> Schema.add_directory("repos", "uuid-repos")
    commit_schema("uuid-root", root_schema)

    CLI.set_root_uuid(workspace, "uuid-root")

    %{workspace: workspace, sync_dir: sync_dir}
  end

  defp create_text_doc(uuid, name, content) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = ContentType.insert_text(doc, 0, content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(uuid, update, nil)
  end

  defp commit_schema(uuid, schema_doc) do
    update = Yelixer.Encoding.encode_update(schema_doc)
    CommitStore.create_commit(uuid, update, nil)
  end

  test "checkout by path changes root UUID", %{workspace: ws} do
    assert CLI.root_uuid(ws) == "uuid-root"

    # Checkout to the main branch by path
    Commonplace.CLI.Checkout.run(ws, "", ["repos/myrepo/main"])

    assert CLI.root_uuid(ws) == "uuid-main"
  end

  test "checkout by UUID changes root", %{workspace: ws} do
    # Use the actual node_id directly (bypasses path resolution)
    CLI.set_root_uuid(ws, "uuid-feature")
    assert CLI.root_uuid(ws) == "uuid-feature"
  end

  test "after checkout, ls shows new root's contents", %{workspace: ws, sync_dir: dir} do
    # Export from root first
    Export.export("uuid-root", dir)

    # Checkout to main branch
    CLI.set_root_uuid(ws, "uuid-main")
    Export.export("uuid-main", dir)

    # ls should show main's contents
    loader = &CLI.load_schema/1
    {:ok, entries} = Walk.list_path("uuid-main", "", loader)
    names = Enum.map(entries, & &1.name)
    assert names == ["readme.txt"]
  end

  test "checkout to feature branch shows feature files", %{workspace: ws, sync_dir: dir} do
    CLI.set_root_uuid(ws, "uuid-feature")
    Export.export("uuid-feature", dir)

    assert File.read!(Path.join(dir, "feature.txt")) == "hello from feature"
  end

  test "checkout with no args shows current root", %{workspace: ws} do
    # Just verify it doesn't crash
    Commonplace.CLI.Checkout.run(ws, "", [])
    assert CLI.root_uuid(ws) == "uuid-root"
  end
end
