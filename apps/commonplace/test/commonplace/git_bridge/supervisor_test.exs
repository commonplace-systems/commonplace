defmodule Commonplace.GitBridge.SupervisorTest do
  use ExUnit.Case, async: false

  alias Commonplace.GitBridge.Server
  alias Commonplace.GitBridge.Supervisor, as: GitBridgeSupervisor
  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore

  setup do
    store_dir = Path.join(System.tmp_dir!(), "cp_gb_sup_store_#{:rand.uniform(1_000_000_000)}")
    data_dir = Path.join(System.tmp_dir!(), "cp_gb_sup_data_#{:rand.uniform(1_000_000_000)}")
    repo_dir1 = Path.join(System.tmp_dir!(), "cp_gb_sup_repo1_#{:rand.uniform(1_000_000_000)}")
    repo_dir2 = Path.join(System.tmp_dir!(), "cp_gb_sup_repo2_#{:rand.uniform(1_000_000_000)}")

    File.mkdir_p!(store_dir)
    File.mkdir_p!(data_dir)

    store_name = :"gb_sup_store_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: store_dir, name: store_name})

    root =
      Schema.new_schema()
      |> Schema.add_file("a.txt", "doc-a")

    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "a.txt")
    doc = ContentType.insert_text(doc, 0, "hi")
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store_name, "doc-a", update, nil)

    schema_update = Yelixer.Encoding.encode_update(root)
    CommitStore.create_commit(store_name, "mount-uuid", schema_update, nil)

    # Workspace root == mount-uuid so Server's reachability check is
    # trivially satisfied without building a separate schema tree.
    workspace_dir = Path.join(System.tmp_dir!(), "cp_gb_sup_ws_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(workspace_dir)
    prev_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, workspace_dir)

    Commonplace.Test.WorkspaceFixture.complete_workspace!(workspace_dir,
      store: store_name
    )

    File.write!(Path.join(workspace_dir, "root"), "mount-uuid")

    on_exit(fn ->
      File.rm_rf!(store_dir)
      File.rm_rf!(data_dir)
      File.rm_rf!(repo_dir1)
      File.rm_rf!(repo_dir2)
      File.rm_rf!(workspace_dir)

      Application.put_env(:commonplace, :data_dir, prev_data_dir || "tmp/test_data")
    end)

    %{store: store_name, data_dir: data_dir, repo_dir1: repo_dir1, repo_dir2: repo_dir2}
  end

  # CX-c93b: each `sup` is `start_link`'d to the test process, so when the
  # test finishes the supervisor already receives EXIT `:shutdown` down the
  # link — `on_exit` (a separate process) races that termination, and an
  # `alive?`-then-`stop` can still catch the supervisor mid-`:shutdown`,
  # which `Supervisor.stop/1` (expecting `:normal`) re-raises as a teardown
  # failure. The teardown only needs it GONE; tolerate any exit reason.
  defp stop_quietly(pid) do
    if is_pid(pid) and Process.alive?(pid) do
      try do
        Supervisor.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end
  end

  test "add_mapping writes git_bridges.json and starts a Server child", %{
    store: store,
    data_dir: data_dir,
    repo_dir1: repo_dir1
  } do
    {:ok, sup} = GitBridgeSupervisor.start_link(data_dir: data_dir, store: store)
    on_exit(fn -> stop_quietly(sup) end)

    mapping = %{mount_uuid: "mount-uuid", repo_dir: repo_dir1, interval_ms: 3_600_000}

    assert {:ok, _} =
             GitBridgeSupervisor.add_mapping(sup, mapping, data_dir: data_dir, store: store)

    contents = File.read!(Path.join(data_dir, "git_bridges.json"))
    decoded = Jason.decode!(contents)
    assert length(decoded) == 1
    assert hd(decoded)["repo_dir"] == repo_dir1

    children = Supervisor.which_children(sup)
    assert length(children) == 1
  end

  test "duplicate repo_dir mapping is rejected", %{
    store: store,
    data_dir: data_dir,
    repo_dir1: repo_dir1
  } do
    {:ok, sup} = GitBridgeSupervisor.start_link(data_dir: data_dir, store: store)
    on_exit(fn -> stop_quietly(sup) end)

    mapping = %{mount_uuid: "mount-uuid", repo_dir: repo_dir1, interval_ms: 3_600_000}

    assert {:ok, _} =
             GitBridgeSupervisor.add_mapping(sup, mapping, data_dir: data_dir, store: store)

    dup = %{mount_uuid: "other-mount", repo_dir: repo_dir1, interval_ms: 3_600_000}

    assert {:error, _} =
             GitBridgeSupervisor.add_mapping(sup, dup, data_dir: data_dir, store: store)

    decoded = Jason.decode!(File.read!(Path.join(data_dir, "git_bridges.json")))
    assert length(decoded) == 1
    assert length(Supervisor.which_children(sup)) == 1
  end

  test "duplicate non-nil remote mapping is rejected", %{
    store: store,
    data_dir: data_dir,
    repo_dir1: repo_dir1,
    repo_dir2: repo_dir2
  } do
    {:ok, sup} = GitBridgeSupervisor.start_link(data_dir: data_dir, store: store)
    on_exit(fn -> stop_quietly(sup) end)

    mapping = %{
      mount_uuid: "mount-uuid",
      repo_dir: repo_dir1,
      remote: "/some/remote.git",
      interval_ms: 3_600_000
    }

    assert {:ok, _} =
             GitBridgeSupervisor.add_mapping(sup, mapping, data_dir: data_dir, store: store)

    dup = %{
      mount_uuid: "mount-uuid",
      repo_dir: repo_dir2,
      remote: "/some/remote.git",
      interval_ms: 3_600_000
    }

    assert {:error, _} =
             GitBridgeSupervisor.add_mapping(sup, dup, data_dir: data_dir, store: store)

    decoded = Jason.decode!(File.read!(Path.join(data_dir, "git_bridges.json")))
    assert length(decoded) == 1
    assert length(Supervisor.which_children(sup)) == 1
  end

  test "mappings persist across supervisor restarts on the same data_dir", %{
    store: store,
    data_dir: data_dir,
    repo_dir1: repo_dir1
  } do
    {:ok, sup1} = GitBridgeSupervisor.start_link(data_dir: data_dir, store: store)

    mapping = %{mount_uuid: "mount-uuid", repo_dir: repo_dir1, interval_ms: 3_600_000}

    assert {:ok, _} =
             GitBridgeSupervisor.add_mapping(sup1, mapping, data_dir: data_dir, store: store)

    :ok = Supervisor.stop(sup1)

    {:ok, sup2} = GitBridgeSupervisor.start_link(data_dir: data_dir, store: store)
    on_exit(fn -> stop_quietly(sup2) end)

    children = Supervisor.which_children(sup2)
    assert length(children) == 1

    [{_id, pid, _, _}] = children
    status = Server.status(pid)
    assert status.mount_uuid == "mount-uuid"
    assert status.repo_dir == repo_dir1

    {:ok, result} = Server.sync_now(pid)
    assert result.committed == true
    assert File.read!(Path.join(repo_dir1, "a.txt")) == "hi"
  end

  test "remove_mapping removes from file and stops the child", %{
    store: store,
    data_dir: data_dir,
    repo_dir1: repo_dir1
  } do
    {:ok, sup} = GitBridgeSupervisor.start_link(data_dir: data_dir, store: store)
    on_exit(fn -> stop_quietly(sup) end)

    mapping = %{mount_uuid: "mount-uuid", repo_dir: repo_dir1, interval_ms: 3_600_000}

    assert {:ok, _} =
             GitBridgeSupervisor.add_mapping(sup, mapping, data_dir: data_dir, store: store)

    assert length(Supervisor.which_children(sup)) == 1

    assert :ok = GitBridgeSupervisor.remove_mapping(sup, "mount-uuid", data_dir: data_dir)

    decoded = Jason.decode!(File.read!(Path.join(data_dir, "git_bridges.json")))
    assert decoded == []
    assert Supervisor.which_children(sup) == []
  end

  test "a mapping written then reread survives (no data loss on plain restart)", %{
    store: store,
    data_dir: data_dir,
    repo_dir1: repo_dir1,
    repo_dir2: repo_dir2
  } do
    {:ok, sup1} = GitBridgeSupervisor.start_link(data_dir: data_dir, store: store)

    mapping1 = %{mount_uuid: "mount-uuid", repo_dir: repo_dir1, interval_ms: 3_600_000}

    mapping2 = %{
      mount_uuid: "mount-uuid",
      repo_dir: repo_dir2,
      remote: nil,
      interval_ms: 3_600_000
    }

    assert {:ok, _} =
             GitBridgeSupervisor.add_mapping(sup1, mapping1, data_dir: data_dir, store: store)

    assert {:ok, _} =
             GitBridgeSupervisor.add_mapping(sup1, mapping2, data_dir: data_dir, store: store)

    :ok = Supervisor.stop(sup1)

    {:ok, sup2} = GitBridgeSupervisor.start_link(data_dir: data_dir, store: store)
    on_exit(fn -> stop_quietly(sup2) end)

    children = Supervisor.which_children(sup2)
    assert length(children) == 2

    decoded = Jason.decode!(File.read!(Path.join(data_dir, "git_bridges.json")))
    repo_dirs = Enum.map(decoded, & &1["repo_dir"]) |> Enum.sort()
    assert repo_dirs == Enum.sort([repo_dir1, repo_dir2])
  end

  test "a corrupt/truncated git_bridges.json is archived aside and boot proceeds with zero mappings",
       %{store: store, data_dir: data_dir} do
    mapping_path = Path.join(data_dir, "git_bridges.json")
    File.write!(mapping_path, "{not valid json")

    {:ok, sup} = GitBridgeSupervisor.start_link(data_dir: data_dir, store: store)
    on_exit(fn -> stop_quietly(sup) end)

    assert Supervisor.which_children(sup) == []

    refute File.exists?(mapping_path)

    corrupt_files =
      data_dir
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, "git_bridges.json.corrupt."))

    assert length(corrupt_files) == 1

    archived_contents = File.read!(Path.join(data_dir, hd(corrupt_files)))
    assert archived_contents == "{not valid json"
  end
end
