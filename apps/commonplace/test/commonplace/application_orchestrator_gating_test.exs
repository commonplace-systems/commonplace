defmodule Commonplace.ApplicationOrchestratorGatingTest do
  @moduledoc """
  Move #2 Task 3 (CX-tdkq.12, decisions O2/O4/O7): orchestrator-on-boot
  is DOUBLE-GATED — explicit opt-in config AND a resolvable workspace
  root — and announces its trust posture when enabled permissive.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Commonplace.Process.Orchestrator
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_orch_gate_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    on_exit(fn ->
      Application.delete_env(:commonplace, :orchestrator_on_boot)
      Application.delete_env(:commonplace, :trust)
      Application.put_env(:commonplace, :data_dir, prior_data_dir || "tmp/test_data")
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp write_root!(dir) do
    root_uuid = UUID.uuid4()
    File.write!(Path.join(dir, "root"), root_uuid)
    root_uuid
  end

  test "flag false → no child" do
    Application.put_env(:commonplace, :orchestrator_on_boot, false)
    assert Commonplace.Application.orchestrator_children() == []
  end

  test "flag absent → no child (default off)" do
    assert Commonplace.Application.orchestrator_children() == []
  end

  test "flag true but no workspace root → no child" do
    Application.put_env(:commonplace, :orchestrator_on_boot, true)
    assert Commonplace.Application.orchestrator_children() == []
  end

  test "flag true + workspace root → named permanent child spec", %{dir: dir} do
    write_root!(dir)
    Application.put_env(:commonplace, :orchestrator_on_boot, true)

    assert [spec] = Commonplace.Application.orchestrator_children()
    assert spec.id == Orchestrator
    assert spec.restart == :permanent
    {Orchestrator, :start_link, [opts]} = spec.start
    assert opts[:root_uuid] == :workspace
    assert opts[:name] == Orchestrator
  end

  test ":workspace sentinel resolves the root in init", %{dir: dir} do
    root_uuid = write_root!(dir)
    store = :"orch_gate_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(Schema.new_schema()), nil)

    Process.flag(:trap_exit, true)
    {:ok, orch} = Orchestrator.start_link(root_uuid: :workspace, store: store, interval: 60_000)

    assert :sys.get_state(orch).root_uuid == root_uuid
    GenServer.stop(orch)
  end

  test ":workspace sentinel with no root file stops cleanly" do
    Process.flag(:trap_exit, true)
    assert {:error, :no_workspace_root} = Orchestrator.start_link(root_uuid: :workspace, interval: 60_000)
  end

  test "enabled + fully-permissive trust posture logs a loud warning", %{dir: dir} do
    root_uuid = write_root!(dir)
    store = :"orch_gate_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(Schema.new_schema()), nil)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: true, trusted_identities: %{}})

    Process.flag(:trap_exit, true)

    log =
      capture_log(fn ->
        {:ok, orch} = Orchestrator.start_link(root_uuid: :workspace, store: store, interval: 60_000)
        GenServer.stop(orch)
      end)

    assert log =~ "permissive"
    assert log =~ "auto-execute"
  end

  test "enabled + strict trust posture does NOT warn", %{dir: dir} do
    root_uuid = write_root!(dir)
    store = :"orch_gate_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(Schema.new_schema()), nil)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})

    Process.flag(:trap_exit, true)

    log =
      capture_log(fn ->
        {:ok, orch} = Orchestrator.start_link(root_uuid: :workspace, store: store, interval: 60_000)
        GenServer.stop(orch)
      end)

    refute log =~ "auto-execute"
  end
end
