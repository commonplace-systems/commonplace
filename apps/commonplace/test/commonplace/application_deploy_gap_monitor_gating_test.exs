defmodule Commonplace.ApplicationDeployGapMonitorGatingTest do
  use ExUnit.Case, async: false

  alias Commonplace.DeployGapMonitor

  setup do
    prior_enabled = Application.get_env(:commonplace, :deploy_gap_monitor_on_boot)
    prior_interval = Application.get_env(:commonplace, :deploy_gap_monitor_interval_ms)

    on_exit(fn ->
      restore_env(:deploy_gap_monitor_on_boot, prior_enabled)
      restore_env(:deploy_gap_monitor_interval_ms, prior_interval)
    end)
  end

  test "flag absent means ordinary application boots have no monitor" do
    Application.delete_env(:commonplace, :deploy_gap_monitor_on_boot)
    assert Commonplace.Application.deploy_gap_monitor_children() == []
  end

  test "flag false means no monitor" do
    Application.put_env(:commonplace, :deploy_gap_monitor_on_boot, false)
    assert Commonplace.Application.deploy_gap_monitor_children() == []
  end

  test "serve flag adds the named periodic monitor" do
    Application.put_env(:commonplace, :deploy_gap_monitor_on_boot, true)
    Application.put_env(:commonplace, :deploy_gap_monitor_interval_ms, 12_345)

    assert [{DeployGapMonitor, opts}] =
             Commonplace.Application.deploy_gap_monitor_children()

    assert opts[:interval_ms] == 12_345
  end

  defp restore_env(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore_env(key, value), do: Application.put_env(:commonplace, key, value)
end
