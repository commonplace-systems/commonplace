defmodule Commonplace.Process.OrchestratorCleanupTest do
  use ExUnit.Case

  alias Commonplace.Process.Orchestrator
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_cleanup_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_cleanup_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    Application.put_env(:commonplace, :data_dir, dir)
    on_exit(fn ->
      Application.delete_env(:commonplace, :data_dir)
      File.rm_rf!(dir)
    end)
    Process.flag(:trap_exit, true)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{store: store_name, root: root_uuid, dir: dir}
  end

  describe "status file" do
    test "write uses atomic rename (no .tmp file left behind)", %{dir: dir, store: store, root: root} do
      {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100_000)

      # Trigger a reconcile to write the status file
      send(orch, :reconcile)
      Process.sleep(100)

      status_file = Path.join(dir, "orchestrator_status.json")
      tmp_file = status_file <> ".tmp"

      assert File.exists?(status_file)
      refute File.exists?(tmp_file)

      # Verify it's valid JSON
      {:ok, content} = File.read(status_file)
      assert {:ok, _} = Jason.decode(content)

      GenServer.stop(orch)
    end
  end
end
