defmodule Commonplace.ApplicationComputeRehydratorGatingTest do
  use ExUnit.Case, async: false

  alias Commonplace.Chat.ComputeRehydrator

  setup do
    prior_enabled = Application.get_env(:commonplace, :compute_rehydrator_on_boot)
    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    data_dir = Path.join(System.tmp_dir!(), "cp_rehydrator_gate_#{:rand.uniform(1_000_000)}")
    root_uuid = UUID.uuid4()

    File.mkdir_p!(data_dir)
    File.write!(Path.join(data_dir, "root"), root_uuid)
    Application.put_env(:commonplace, :data_dir, data_dir)

    on_exit(fn ->
      restore_env(:compute_rehydrator_on_boot, prior_enabled)
      restore_env(:data_dir, prior_data_dir)
      File.rm_rf!(data_dir)
    end)

    %{root_uuid: root_uuid}
  end

  test "flag absence refuses the rehydrator even when a workspace root resolves", %{
    root_uuid: root_uuid
  } do
    assert {:ok, ^root_uuid} = Commonplace.Workspace.root_uuid()
    Application.delete_env(:commonplace, :compute_rehydrator_on_boot)

    assert Commonplace.Application.compute_rehydrator_children() == []
  end

  test "serve flag adds the rehydrator when a workspace root resolves", %{root_uuid: root_uuid} do
    assert {:ok, ^root_uuid} = Commonplace.Workspace.root_uuid()
    Application.put_env(:commonplace, :compute_rehydrator_on_boot, true)

    assert [{ComputeRehydrator, []}] =
             Commonplace.Application.compute_rehydrator_children()
  end

  defp restore_env(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore_env(key, value), do: Application.put_env(:commonplace, key, value)
end
