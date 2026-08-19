defmodule Commonplace.Dataflow.NodeGraphIntegrationTest do
  @moduledoc """
  Integration tests exercising the full reactive dataflow pipeline:
  SmartDoc port declarations -> Orchestrator wiring -> PubSub dispatch -> callback execution.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType
  alias Commonplace.Process.Orchestrator
  alias Commonplace.Dataflow.GraphRegistry

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_integ_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_integ_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    # Clean GraphRegistry edges from prior tests — collect unique process names first
    GraphRegistry.get_graph()
    |> Enum.map(& &1.process)
    |> Enum.uniq()
    |> Enum.each(&GraphRegistry.remove_edges/1)

    # Create root schema
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    # Trap exits so orchestrator shutdown doesn't crash the test
    Process.flag(:trap_exit, true)

    %{store: store_name, root: root_uuid, dir: dir}
  end

  # Poll until condition is true, with timeout
  defp wait_until(fun, timeout_ms \\ 3000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        :timeout
      else
        Process.sleep(50)
        do_wait_until(fun, deadline)
      end
    end
  end

  describe "SmartDoc reacts to blue input" do
    test "handle_blue fires when a watched document gets a new commit", %{
      store: store,
      root: root
    } do
      # Use an Agent as a side-channel to detect callback firing (avoids ETS naming issues)
      {:ok, agent} = Agent.start_link(fn -> nil end)

      # Store the agent pid in a persistent term so the compiled SmartDoc code can find it
      :persistent_term.put(:integ_test_watcher_agent, agent)
      on_exit(fn -> :persistent_term.erase(:integ_test_watcher_agent) end)

      # Create "data.txt" with initial content
      data_uuid = create_source_doc(store, root, "data.txt", "initial")

      # Create SmartDoc source: writes to agent when handle_blue fires
      _watcher_uuid =
        create_source_doc(store, root, "watcher.exs", """
        defmodule Commonplace.UserProcess.Watcher do
          use GenServer
          use Commonplace.SmartDoc

          @blue_inputs ["data.txt"]

          def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
          def init(opts), do: {:ok, opts}

          def handle_blue("data.txt", doc) do
            content = Commonplace.Document.ContentType.get_content(doc) || ""
            agent = :persistent_term.get(:integ_test_watcher_agent)
            Agent.update(agent, fn _ -> content end)
          end
        end
        """)

      # Create __processes.json referencing the watcher
      create_processes_doc(store, root, %{
        "watcher" => %{"mode" => "elixir", "source" => "watcher.exs"}
      })

      # Start the Orchestrator
      {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100)

      # Wait until the watcher process is running
      assert :ok =
               wait_until(fn ->
                 Map.has_key?(Orchestrator.running_processes(orch), "watcher")
               end)

      # Now create a new commit on data.txt to trigger the watcher
      new_doc = Yelixer.Doc.new()
      new_doc = ContentType.create(new_doc, :text, "data.txt")
      new_doc = ContentType.insert_text(new_doc, 0, "updated content")
      new_update = Yelixer.Encoding.encode_update(new_doc)
      CommitStore.create_chained_commit(store, data_uuid, new_update)

      # Wait until the watcher callback fires
      assert :ok =
               wait_until(fn ->
                 content = Agent.get(agent, & &1)
                 content != nil and String.contains?(content, "updated content")
               end)

      GenServer.stop(orch)
    end
  end

  describe "GraphRegistry shows correct edges" do
    test "blue edges are registered after Orchestrator wires a SmartDoc", %{
      store: store,
      root: root
    } do
      # Create "data.txt"
      data_uuid = create_source_doc(store, root, "data.txt", "hello")

      # Create SmartDoc with blue input on data.txt
      _watcher_uuid =
        create_source_doc(store, root, "observer.exs", """
        defmodule Commonplace.UserProcess.Observer do
          use GenServer
          use Commonplace.SmartDoc

          @blue_inputs ["data.txt"]

          def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
          def init(opts), do: {:ok, opts}
        end
        """)

      create_processes_doc(store, root, %{
        "observer" => %{"mode" => "elixir", "source" => "observer.exs"}
      })

      {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100)

      # Wait until blue edges appear in GraphRegistry
      assert :ok =
               wait_until(fn ->
                 graph = GraphRegistry.get_graph()

                 blue_edges =
                   Enum.filter(graph, fn e ->
                     e.color == :blue and e.from == data_uuid and e.to == "observer"
                   end)

                 length(blue_edges) == 1
               end)

      # dependents(data_uuid) should include the observer
      deps = GraphRegistry.dependents(data_uuid)
      process_names = Enum.map(deps, & &1.process)
      assert "observer" in process_names

      GenServer.stop(orch)
    end
  end

  describe "depth protection prevents infinite loops" do
    test "cyclic SmartDoc wiring produces cross-color edges in the graph", %{
      store: store,
      root: root
    } do
      # Create documents that the two processes will read/write
      a_uuid = create_source_doc(store, root, "a.txt", "a-init")
      b_uuid = create_source_doc(store, root, "b.txt", "b-init")

      # Process A: reads b.txt, writes to a.txt
      _proc_a_uuid =
        create_source_doc(store, root, "proc_a.exs", """
        defmodule Commonplace.UserProcess.ProcA do
          use GenServer
          use Commonplace.SmartDoc

          @blue_inputs ["b.txt"]
          @cyan_outputs ["a.txt"]

          def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
          def init(opts), do: {:ok, opts}

          def handle_blue("b.txt", _doc), do: :ok
        end
        """)

      # Process B: reads a.txt, writes to b.txt
      _proc_b_uuid =
        create_source_doc(store, root, "proc_b.exs", """
        defmodule Commonplace.UserProcess.ProcB do
          use GenServer
          use Commonplace.SmartDoc

          @blue_inputs ["a.txt"]
          @cyan_outputs ["b.txt"]

          def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
          def init(opts), do: {:ok, opts}

          def handle_blue("a.txt", _doc), do: :ok
        end
        """)

      create_processes_doc(store, root, %{
        "proc_a" => %{"mode" => "elixir", "source" => "proc_a.exs"},
        "proc_b" => %{"mode" => "elixir", "source" => "proc_b.exs"}
      })

      {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100)

      # Wait until both processes are running
      assert :ok =
               wait_until(fn ->
                 pids = Orchestrator.running_processes(orch)
                 Map.has_key?(pids, "proc_a") and Map.has_key?(pids, "proc_b")
               end)

      # Wait until the graph has the expected cross-color feedback loop
      assert :ok =
               wait_until(fn ->
                 graph = GraphRegistry.get_graph()

                 Enum.any?(graph, fn e ->
                   e.color == :blue and e.from == b_uuid and e.to == "proc_a"
                 end) and
                   Enum.any?(graph, fn e ->
                     e.color == :cyan and e.from == "proc_a" and e.to == a_uuid
                   end)
               end)

      graph = GraphRegistry.get_graph()

      assert Enum.any?(graph, fn e ->
               e.color == :blue and e.from == b_uuid and e.to == "proc_a"
             end)

      assert Enum.any?(graph, fn e ->
               e.color == :cyan and e.from == "proc_a" and e.to == a_uuid
             end)

      assert Enum.any?(graph, fn e ->
               e.color == :blue and e.from == a_uuid and e.to == "proc_b"
             end)

      assert Enum.any?(graph, fn e ->
               e.color == :cyan and e.from == "proc_b" and e.to == b_uuid
             end)

      # Both docs are dependencies of the other process
      assert "proc_a" in Enum.map(GraphRegistry.dependents(b_uuid), & &1.process)
      assert "proc_b" in Enum.map(GraphRegistry.dependents(a_uuid), & &1.process)

      GenServer.stop(orch)
    end

    test "commits with depth exceeding limit are not dispatched", %{store: store, root: root} do
      # Use an Agent as a counter for dispatch events
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      :persistent_term.put(:integ_test_depth_counter, counter)
      on_exit(fn -> :persistent_term.erase(:integ_test_depth_counter) end)

      data_uuid = create_source_doc(store, root, "watched.txt", "start")

      _watcher_uuid =
        create_source_doc(store, root, "depth_watcher.exs", """
        defmodule Commonplace.UserProcess.DepthWatcher do
          use GenServer
          use Commonplace.SmartDoc

          @blue_inputs ["watched.txt"]

          def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
          def init(opts), do: {:ok, opts}

          def handle_blue("watched.txt", _doc) do
            counter = :persistent_term.get(:integ_test_depth_counter)
            Agent.update(counter, &(&1 + 1))
          end
        end
        """)

      create_processes_doc(store, root, %{
        "depth_watcher" => %{"mode" => "elixir", "source" => "depth_watcher.exs"}
      })

      {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100)

      # Wait until depth_watcher process is running and wired
      assert :ok =
               wait_until(fn ->
                 Map.has_key?(Orchestrator.running_processes(orch), "depth_watcher")
               end)

      # Send a commit with depth=0 — should be dispatched
      new_doc = Yelixer.Doc.new()
      new_doc = ContentType.create(new_doc, :text, "watched.txt")
      new_doc = ContentType.insert_text(new_doc, 0, "depth zero")
      update = Yelixer.Encoding.encode_update(new_doc)
      CommitStore.create_chained_commit(store, data_uuid, update, %{kind: :regular, depth: 0})

      # Wait until the counter increments
      assert :ok = wait_until(fn -> Agent.get(counter, & &1) == 1 end)

      # Send a commit with depth > max (8) — should NOT be dispatched
      new_doc2 = Yelixer.Doc.new()
      new_doc2 = ContentType.create(new_doc2, :text, "watched.txt")
      new_doc2 = ContentType.insert_text(new_doc2, 0, "depth exceeded")
      update2 = Yelixer.Encoding.encode_update(new_doc2)
      CommitStore.create_chained_commit(store, data_uuid, update2, %{kind: :regular, depth: 9})

      # Give time for potential (unwanted) dispatch, then verify count unchanged
      Process.sleep(300)
      assert Agent.get(counter, & &1) == 1

      GenServer.stop(orch)
    end
  end

  # --- Helpers (matching orchestrator_test.exs patterns) ---

  defp create_source_doc(store, root, filename, content) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, filename)
    doc = ContentType.insert_text(doc, 0, content)
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
    root_doc = load_schema(root, store)

    case Schema.get_entry(root_doc, "__processes.json") do
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
