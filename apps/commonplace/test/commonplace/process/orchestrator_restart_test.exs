defmodule Commonplace.Process.OrchestratorRestartTest do
  @moduledoc """
  Move #2 (CX-tdkq.12): restart correctness. Managed processes are
  unnamed + unlinked by design, so a restarted orchestrator must SWEEP
  the prior generation (via `orchestrator_status.json`, the file-backed
  tracker that survives both orchestrator and BEAM crashes) before
  reconciling — otherwise every crash duplicates every process.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.ContentType
  alias Commonplace.Process.Orchestrator
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_orch_restart_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"orch_restart_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})

    # The status file lives under :data_dir — point it at the scratch dir.
    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    Application.put_env(:commonplace, :trust, %{accept_unsigned: true, trusted_identities: %{}})

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()

    CommitStore.create_commit(
      store_name,
      root_uuid,
      Yelixer.Encoding.encode_update(root_doc),
      nil
    )

    Process.flag(:trap_exit, true)

    on_exit(fn ->
      Application.delete_env(:commonplace, :trust)
      Application.put_env(:commonplace, :data_dir, prior_data_dir || "tmp/test_data")
      File.rm_rf!(dir)
    end)

    %{store: store_name, root: root_uuid, dir: dir}
  end

  defp put_doc(store, root, filename, content) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, filename)
    doc = ContentType.insert_text(doc, 0, content)

    CommitStore.create_chained_commit(store, uuid, Yelixer.Encoding.encode_update(doc), %{
      kind: :regular
    })

    root_doc = load_schema(root, store)
    root_doc = Schema.add_file(root_doc, filename, uuid)
    CommitStore.create_chained_commit(store, root, Yelixer.Encoding.encode_update(root_doc))
    uuid
  end

  defp load_schema(uuid, store) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        {:ok, doc} = Yelixer.Encoding.apply_update(Schema.new_schema(), commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end

  defp sleeper_source(n) do
    """
    defmodule Commonplace.UserProcess.RestartSleeper#{n} do
      use GenServer
      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
      def init(opts), do: {:ok, opts}
    end
    """
  end

  defp declare!(store, root, proc_name, n) do
    put_doc(store, root, "rs#{n}.exs", sleeper_source(n))

    put_doc(
      store,
      root,
      "__processes.json",
      Jason.encode!(%{proc_name => %{"mode" => "elixir", "source" => "rs#{n}.exs"}})
    )
  end

  defp start_orchestrator!(store, root) do
    {:ok, orch} = Orchestrator.start_link(root_uuid: root, store: store, interval: 100)
    orch
  end

  defp await_running(orch, proc_name) do
    Enum.reduce_while(1..100, nil, fn _, _ ->
      procs = Orchestrator.running_processes(orch)

      case Map.get(procs, proc_name) do
        pid when is_pid(pid) -> {:halt, pid}
        _ -> Process.sleep(50) && {:cont, nil}
      end
    end) || flunk("#{proc_name} never started")
  end

  test "status file records a live, parseable beam_pid for managed processes",
       %{store: store, root: root, dir: dir} do
    declare!(store, root, "restart_sleeper_one", "One")
    orch = start_orchestrator!(store, root)
    managed = await_running(orch, "restart_sleeper_one")

    status =
      Path.join(dir, "orchestrator_status.json")
      |> File.read!()
      |> Jason.decode!()

    beam_pid_s = get_in(status, ["processes", "restart_sleeper_one", "beam_pid"])
    assert is_binary(beam_pid_s)

    parsed = :erlang.list_to_pid(String.to_charlist(beam_pid_s))
    assert parsed == managed
    assert Process.alive?(parsed)

    GenServer.stop(orch)
  end

  test "restart sweeps the prior generation — no duplicates", %{store: store, root: root} do
    declare!(store, root, "restart_sleeper_two", "Two")

    orch_a = start_orchestrator!(store, root)
    p1 = await_running(orch_a, "restart_sleeper_two")
    assert Process.alive?(p1)

    # The orchestrator dies hard — no terminate/2 cleanup runs. p1
    # survives (unlinked by design): exactly the duplicate-leak setup.
    Process.exit(orch_a, :kill)
    refute Process.alive?(orch_a)
    assert Process.alive?(p1)

    orch_b = start_orchestrator!(store, root)
    p2 = await_running(orch_b, "restart_sleeper_two")

    # Sweep correctness: the prior generation is REAPED, the new
    # generation is the only one running.
    refute Process.alive?(p1)
    assert Process.alive?(p2)
    assert p2 != p1

    GenServer.stop(orch_b)
  end

  test "sweep tolerates a stale/garbage status file", %{store: store, root: root, dir: dir} do
    File.write!(
      Path.join(dir, "orchestrator_status.json"),
      Jason.encode!(%{
        "pid" => "999999",
        "processes" => %{
          "long_gone" => %{"mode" => "elixir", "beam_pid" => "<0.99999999.0>", "os_pid" => nil},
          "half_gone" => %{
            "mode" => "sandbox_exec",
            "beam_pid" => "not even a pid",
            "os_pid" => nil
          }
        }
      })
    )

    declare!(store, root, "restart_sleeper_three", "Three")
    orch = start_orchestrator!(store, root)
    assert await_running(orch, "restart_sleeper_three")

    GenServer.stop(orch)
  end

  test "missing status file: sweep is a no-op, reconcile proceeds", %{store: store, root: root} do
    declare!(store, root, "restart_sleeper_four", "Four")
    orch = start_orchestrator!(store, root)
    assert await_running(orch, "restart_sleeper_four")
    GenServer.stop(orch)
  end

  test "declaration gating survives restart (O8): untrusted declarations stay dead",
       %{store: store, root: root} do
    declare!(store, root, "restart_sleeper_five", "Five")

    orch_a = start_orchestrator!(store, root)
    p1 = await_running(orch_a, "restart_sleeper_five")
    Process.exit(orch_a, :kill)

    # Strict mode with nothing pinned: the (unsigned) declaration loses
    # trust. The restarted orchestrator must sweep p1 AND not restart it.
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})

    orch_b = start_orchestrator!(store, root)
    # Give reconcile a few ticks.
    Process.sleep(500)

    refute Process.alive?(p1)
    assert Orchestrator.running_processes(orch_b) == %{}

    GenServer.stop(orch_b)
  end
end
