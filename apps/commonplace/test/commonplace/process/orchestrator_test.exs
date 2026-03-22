defmodule Commonplace.Process.OrchestratorTest do
  @moduledoc """
  Tests for the process orchestrator — watches __processes.json
  and manages Elixir process lifecycle.
  """
  use ExUnit.Case

  alias Commonplace.Process.Orchestrator
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_orch_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
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

  describe "compiling and running elixir processes" do
    test "compiles and starts an elixir process from source doc", %{store: store, root: root} do
      # Create a source document with a simple GenServer
      source_uuid = create_source_doc(store, root, "greeter.exs", """
      defmodule Commonplace.UserProcess.Greeter do
        use GenServer
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        def greet(pid), do: GenServer.call(pid, :greet)
        def init(opts), do: {:ok, opts}
        def handle_call(:greet, _from, state), do: {:reply, "hello from greeter", state}
      end
      """)

      # Create __processes.json
      create_processes_doc(store, root, %{
        "greeter" => %{"mode" => "elixir", "source" => "greeter.exs"}
      })

      {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100)
      Process.sleep(200)

      # The process should be running
      pids = Orchestrator.running_processes(orch)
      assert Map.has_key?(pids, "greeter")

      # Should be callable
      pid = pids["greeter"]
      assert Commonplace.UserProcess.Greeter.greet(pid) == "hello from greeter"

      Process.unlink(orch)
      Process.unlink(orch)
      GenServer.stop(orch)
    end

    test "stops process when removed from config", %{store: store, root: root} do
      create_source_doc(store, root, "temp.exs", """
      defmodule Commonplace.UserProcess.Temp do
        use GenServer
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        def init(opts), do: {:ok, opts}
      end
      """)

      create_processes_doc(store, root, %{
        "temp" => %{"mode" => "elixir", "source" => "temp.exs"}
      })

      {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100)
      Process.sleep(200)

      assert Map.has_key?(Orchestrator.running_processes(orch), "temp")

      # Remove from config
      create_processes_doc(store, root, %{})
      Process.sleep(200)

      refute Map.has_key?(Orchestrator.running_processes(orch), "temp")

      Process.unlink(orch)
      GenServer.stop(orch)
    end

    test "hot-reloads process when source changes (pid preserved)", %{store: store, root: root} do
      create_source_doc(store, root, "evolving.exs", """
      defmodule Commonplace.UserProcess.Evolving do
        use GenServer
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        def version(pid), do: GenServer.call(pid, :version)
        def init(opts), do: {:ok, opts}
        def handle_call(:version, _from, state), do: {:reply, 1, state}
      end
      """)

      create_processes_doc(store, root, %{
        "evolving" => %{"mode" => "elixir", "source" => "evolving.exs"}
      })

      {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100)
      Process.sleep(200)

      pids = Orchestrator.running_processes(orch)
      old_pid = pids["evolving"]
      assert Commonplace.UserProcess.Evolving.version(old_pid) == 1

      # Update source — hot reload keeps the same pid
      create_source_doc(store, root, "evolving.exs", """
      defmodule Commonplace.UserProcess.Evolving do
        use GenServer
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        def version(pid), do: GenServer.call(pid, :version)
        def init(opts), do: {:ok, opts}
        def handle_call(:version, _from, state), do: {:reply, 2, state}
      end
      """)

      Process.sleep(300)

      pids = Orchestrator.running_processes(orch)
      new_pid = pids["evolving"]
      assert new_pid == old_pid
      assert Commonplace.UserProcess.Evolving.version(old_pid) == 2

      Process.unlink(orch)
      GenServer.stop(orch)
    end
  end

  describe "process context" do
    test "process receives store and config in init", %{store: store, root: root} do
      create_source_doc(store, root, "context_check.exs", """
      defmodule Commonplace.UserProcess.ContextCheck do
        use GenServer
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        def get_context(pid), do: GenServer.call(pid, :context)
        def init(opts) do
          {:ok, %{store: opts[:store], name: opts[:name], config: opts[:config]}}
        end
        def handle_call(:context, _from, state), do: {:reply, state, state}
      end
      """)

      create_processes_doc(store, root, %{
        "context_check" => %{"mode" => "elixir", "source" => "context_check.exs", "owns" => "out.txt"}
      })

      {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100)
      Process.sleep(200)

      pid = Orchestrator.running_processes(orch)["context_check"]
      ctx = Commonplace.UserProcess.ContextCheck.get_context(pid)
      assert ctx.store == store
      assert ctx.name == "context_check"
      assert ctx.config["owns"] == "out.txt"

      Process.unlink(orch)
      GenServer.stop(orch)
    end
  end

  describe "recursive __processes.json discovery" do
    test "discovers processes in subdirectory __processes.json", %{store: store, root: root} do
      # Create a subdirectory "sub" with its own __processes.json
      sub_uuid = UUID.uuid4()
      sub_doc = Schema.new_schema()
      update = Yelixer.Encoding.encode_update(sub_doc)
      CommitStore.create_commit(store, sub_uuid, update, nil)

      # Add sub as a directory entry in root
      root_doc = load_schema(root, store)
      root_doc = Schema.add_directory(root_doc, "sub", sub_uuid)
      update = Yelixer.Encoding.encode_update(root_doc)
      CommitStore.create_commit(store, root, update, nil)

      # Create a source doc in root (so elixir process can find it)
      create_source_doc(store, root, "root_worker.exs", """
      defmodule Commonplace.UserProcess.RootWorker do
        use GenServer
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        def scope(pid), do: GenServer.call(pid, :scope)
        def init(opts), do: {:ok, opts}
        def handle_call(:scope, _from, state), do: {:reply, "root", state}
      end
      """)

      # Create __processes.json at root
      create_processes_doc(store, root, %{
        "root_worker" => %{"mode" => "elixir", "source" => "root_worker.exs"}
      })

      # Create __processes.json in sub
      create_processes_doc_in(store, sub_uuid, %{
        "sub_worker" => %{
          "mode" => "sandbox-exec",
          "command" => "/bin/echo",
          "args" => ["hello"]
        }
      })

      {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100)
      Process.sleep(500)

      pids = Orchestrator.running_processes(orch)
      # Both processes should be discovered
      assert Map.has_key?(pids, "root_worker")
      assert Map.has_key?(pids, "sub_worker")

      Process.unlink(orch)
      GenServer.stop(orch)
    end
  end

  # Helpers

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

  defp create_processes_doc_in(store, dir_uuid, config) do
    json = Jason.encode!(config)

    dir_doc = load_schema(dir_uuid, store)

    case Schema.get_entry(dir_doc, "__processes.json") do
      {:ok, entry} ->
        doc = Yelixer.Doc.new()
        doc = ContentType.create(doc, :text, "__processes.json")
        doc = ContentType.insert_text(doc, 0, json)
        update = Yelixer.Encoding.encode_update(doc)
        CommitStore.create_commit(store, entry.node_id, update, nil)

      :error ->
        uuid = UUID.uuid4()
        doc = Yelixer.Doc.new()
        doc = ContentType.create(doc, :text, "__processes.json")
        doc = ContentType.insert_text(doc, 0, json)
        update = Yelixer.Encoding.encode_update(doc)
        CommitStore.create_commit(store, uuid, update, nil)

        dir_doc = load_schema(dir_uuid, store)
        dir_doc = Schema.add_file(dir_doc, "__processes.json", uuid)
        update = Yelixer.Encoding.encode_update(dir_doc)
        CommitStore.create_commit(store, dir_uuid, update, nil)
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
