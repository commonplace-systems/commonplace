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

  describe "terminate/2 escalation" do
    test "sends SIGTERM then SIGKILL to managed process groups", %{store: store, root: root} do
      # Create a __processes.json with a long-running sleep command
      proc_uuid = UUID.uuid4()
      doc = Yelixer.Doc.new()
      doc = Commonplace.Document.ContentType.create(doc, :text, "__processes.json")
      content = Jason.encode!(%{
        "sleeper" => %{
          "mode" => "sandbox-exec",
          "command" => "sleep",
          "args" => ["3600"]
        }
      })
      doc = Commonplace.Document.ContentType.insert_text(doc, 0, content)
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, proc_uuid, update, nil)

      root_doc = Schema.new_schema()
      root_doc = Schema.add_file(root_doc, "__processes.json", proc_uuid)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(store, root, update, nil)

      {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100_000)
      send(orch, :reconcile)

      # Poll for os_pid to be available (port starts async with 200ms delay)
      os_pid = poll_for_os_pid(orch, "sleeper", 10)
      assert os_pid != nil, "sleeper process should have an os_pid"

      # Verify sleep is running
      {_, 0} = System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true)

      # Stop orchestrator — should kill the sleep process
      GenServer.stop(orch, :shutdown, 10_000)
      Process.sleep(500)

      # Sleep process should be dead
      {_, exit_code} = System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true)
      assert exit_code != 0
    end
  end

  defp poll_for_os_pid(orch, name, retries) when retries > 0 do
    info = Orchestrator.process_info(orch)
    case info do
      %{^name => %{os_pid: pid}} when not is_nil(pid) -> pid
      _ ->
        Process.sleep(200)
        poll_for_os_pid(orch, name, retries - 1)
    end
  end

  defp poll_for_os_pid(_, _, 0), do: nil
end
