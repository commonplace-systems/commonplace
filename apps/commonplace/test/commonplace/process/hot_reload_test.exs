defmodule Commonplace.Process.HotReloadTest do
  @moduledoc """
  Tests for hot code reload of .exs processes.

  Hot reload swaps the module code via Code.purge_module + Code.compile_string
  without stopping the running GenServer process, preserving both pid and state.
  """
  use ExUnit.Case

  alias Commonplace.Process.Orchestrator
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_hotreload_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_hr_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    # Create root schema
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    # Trap exits so orchestrator shutdown doesn't kill test
    Process.flag(:trap_exit, true)

    %{store: store_name, root: root_uuid}
  end

  describe "hot code reload" do
    test "running process gets new behavior without pid changing", %{store: store, root: root} do
      # Use a unique module name to avoid collisions with other tests
      create_source_doc(store, root, "hot_target.exs", """
      defmodule Commonplace.UserProcess.HotTarget do
        use GenServer
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        def version(pid), do: GenServer.call(pid, :version)
        def init(opts), do: {:ok, opts}
        def handle_call(:version, _from, state), do: {:reply, 1, state}
      end
      """)

      create_processes_doc(store, root, %{
        "hot_target" => %{"mode" => "elixir", "source" => "hot_target.exs"}
      })

      {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100)
      reconcile(orch)

      pids = Orchestrator.running_processes(orch)
      assert Map.has_key?(pids, "hot_target")
      original_pid = pids["hot_target"]
      assert Commonplace.UserProcess.HotTarget.version(original_pid) == 1

      # Update source with new behavior
      create_source_doc(store, root, "hot_target.exs", """
      defmodule Commonplace.UserProcess.HotTarget do
        use GenServer
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        def version(pid), do: GenServer.call(pid, :version)
        def init(opts), do: {:ok, opts}
        def handle_call(:version, _from, state), do: {:reply, 2, state}
      end
      """)

      reconcile(orch)

      # PID must be the same — hot reload, not restart
      pids = Orchestrator.running_processes(orch)
      new_pid = pids["hot_target"]
      assert new_pid == original_pid, "Expected pid to stay the same after hot reload"

      # New behavior must be active
      assert Commonplace.UserProcess.HotTarget.version(original_pid) == 2

      Process.unlink(orch)
      GenServer.stop(orch)
    end

    test "GenServer keeps its state across hot reload", %{store: store, root: root} do
      create_source_doc(store, root, "stateful.exs", """
      defmodule Commonplace.UserProcess.Stateful do
        use GenServer
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        def get_counter(pid), do: GenServer.call(pid, :get_counter)
        def increment(pid), do: GenServer.call(pid, :increment)
        def version(pid), do: GenServer.call(pid, :version)
        def init(_opts), do: {:ok, %{counter: 0}}
        def handle_call(:get_counter, _from, state), do: {:reply, state.counter, state}
        def handle_call(:increment, _from, state), do: {:reply, :ok, %{state | counter: state.counter + 1}}
        def handle_call(:version, _from, state), do: {:reply, :v1, state}
      end
      """)

      create_processes_doc(store, root, %{
        "stateful" => %{"mode" => "elixir", "source" => "stateful.exs"}
      })

      {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100)
      reconcile(orch)

      pid = Orchestrator.running_processes(orch)["stateful"]

      # Build up some state
      Commonplace.UserProcess.Stateful.increment(pid)
      Commonplace.UserProcess.Stateful.increment(pid)
      Commonplace.UserProcess.Stateful.increment(pid)
      assert Commonplace.UserProcess.Stateful.get_counter(pid) == 3
      assert Commonplace.UserProcess.Stateful.version(pid) == :v1

      # Update source — new version label, same state handling
      create_source_doc(store, root, "stateful.exs", """
      defmodule Commonplace.UserProcess.Stateful do
        use GenServer
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        def get_counter(pid), do: GenServer.call(pid, :get_counter)
        def increment(pid), do: GenServer.call(pid, :increment)
        def version(pid), do: GenServer.call(pid, :version)
        def init(_opts), do: {:ok, %{counter: 0}}
        def handle_call(:get_counter, _from, state), do: {:reply, state.counter, state}
        def handle_call(:increment, _from, state), do: {:reply, :ok, %{state | counter: state.counter + 1}}
        def handle_call(:version, _from, state), do: {:reply, :v2, state}
      end
      """)

      reconcile(orch)

      # State must be preserved
      assert Commonplace.UserProcess.Stateful.get_counter(pid) == 3
      # New behavior must be active
      assert Commonplace.UserProcess.Stateful.version(pid) == :v2
      # Pid must be the same
      assert Orchestrator.running_processes(orch)["stateful"] == pid

      Process.unlink(orch)
      GenServer.stop(orch)
    end
  end

  # Helpers (duplicated from orchestrator_test — same setup pattern)

  defp reconcile(orch) do
    # The reconciler is message-driven. Sending its real trigger and then
    # synchronizing with the GenServer proves convergence without assuming
    # that a 100 ms timer gets scheduled inside an arbitrary sleep budget.
    send(orch, :reconcile)
    _ = :sys.get_state(orch)
    :ok
  end

  defp create_source_doc(store, root, filename, source_code) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, filename)
    doc = ContentType.insert_text(doc, 0, source_code)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)

    # Add to root schema
    root_doc = load_schema(root, store)
    root_doc = Schema.add_file(root_doc, filename, uuid)
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store, root, update, nil)

    uuid
  end

  defp create_processes_doc(store, root, config) do
    json = Jason.encode!(config)

    # Check if __processes.json already exists
    root_doc = load_schema(root, store)

    case Schema.get_entry(root_doc, "__processes.json") do
      {:ok, entry} ->
        # Update existing
        doc = Yelixer.Doc.new()
        doc = ContentType.create(doc, :text, "__processes.json")
        doc = ContentType.insert_text(doc, 0, json)
        update = Yelixer.Encoding.encode_update(doc)
        CommitStore.create_commit(store, entry.node_id, update, nil)

      :error ->
        # Create new
        uuid = UUID.uuid4()
        doc = Yelixer.Doc.new()
        doc = ContentType.create(doc, :text, "__processes.json")
        doc = ContentType.insert_text(doc, 0, json)
        update = Yelixer.Encoding.encode_update(doc)
        CommitStore.create_commit(store, uuid, update, nil)

        root_doc = load_schema(root, store)
        root_doc = Schema.add_file(root_doc, "__processes.json", uuid)
        update = Yelixer.Encoding.encode_update(root_doc)
        CommitStore.create_commit(store, root, update, nil)
    end
  end

  defp load_schema(uuid, store) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end
end
