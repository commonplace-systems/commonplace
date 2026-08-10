defmodule Commonplace.Process.OrchestratorWorkerRoleTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Commonplace.Process.Orchestrator

  @refusal_name :worker_role_requires_strict_trust

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "cp_worker_role_#{System.unique_integer([:positive])}")

    File.mkdir_p!(data_dir)

    prior_data_dir = Application.fetch_env(:commonplace, :data_dir)
    prior_node_role = Application.fetch_env(:commonplace, :node_role)
    prior_trust = Application.fetch_env(:commonplace, :trust)
    prior_sandbox = System.fetch_env("CODEX_SANDBOX")

    Application.put_env(:commonplace, :data_dir, data_dir)
    Application.delete_env(:commonplace, :node_role)
    permissive!()
    System.delete_env("CODEX_SANDBOX")
    Process.flag(:trap_exit, true)

    on_exit(fn ->
      restore_app_env(:data_dir, prior_data_dir)
      restore_app_env(:node_role, prior_node_role)
      restore_app_env(:trust, prior_trust)
      restore_system_env("CODEX_SANDBOX", prior_sandbox)
      File.rm_rf!(data_dir)
    end)

    %{data_dir: data_dir}
  end

  test "declared worker role refuses to start with permissive trust" do
    Application.put_env(:commonplace, :node_role, :worker)

    assert {:error, {@refusal_name, message}} = start_orchestrator()
    assert message =~ "role=worker declared"
    assert message =~ "trust config permissive"
    assert message =~ "write trust.json or remove the role"
  end

  test "declared worker role starts with explicit strict trust config", %{data_dir: data_dir} do
    Application.put_env(:commonplace, :node_role, :worker)
    Application.delete_env(:commonplace, :trust)

    File.write!(
      Path.join(data_dir, "trust.json"),
      Jason.encode!(%{accept_unsigned: false, trusted_identities: %{}})
    )

    assert {:ok, orchestrator} = start_orchestrator()
    assert :sys.get_state(orchestrator).root_uuid == "worker-role-test-root"
    GenServer.stop(orchestrator)
  end

  test "unmarked permissive node starts and preserves the warning" do
    {result, log} =
      with_log(fn ->
        result = start_orchestrator()
        stop_if_started(result)
        result
      end)

    assert {:ok, _orchestrator} = result
    assert log =~ "Orchestrator running with a permissive trust config"
    assert log =~ "auto-execute ungated"
  end

  test "sandbox-like environment without the explicit marker does not refuse" do
    System.put_env("CODEX_SANDBOX", "workspace-write")

    {result, log} =
      with_log(fn ->
        result = start_orchestrator()
        stop_if_started(result)
        result
      end)

    assert System.fetch_env!("CODEX_SANDBOX") == "workspace-write"
    assert Application.fetch_env(:commonplace, :node_role) == :error
    assert {:ok, _orchestrator} = result
    refute match?({:error, {@refusal_name, _message}}, result)
    assert log =~ "Orchestrator running with a permissive trust config"
  end

  defp start_orchestrator do
    Orchestrator.start_link(root_uuid: "worker-role-test-root", interval: 60_000)
  end

  defp stop_if_started({:ok, orchestrator}), do: GenServer.stop(orchestrator)
  defp stop_if_started(_result), do: :ok

  defp permissive! do
    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: true,
      trusted_identities: %{}
    })
  end

  defp restore_app_env(key, {:ok, value}), do: Application.put_env(:commonplace, key, value)
  defp restore_app_env(key, :error), do: Application.delete_env(:commonplace, key)

  defp restore_system_env(key, {:ok, value}), do: System.put_env(key, value)
  defp restore_system_env(key, :error), do: System.delete_env(key)
end
