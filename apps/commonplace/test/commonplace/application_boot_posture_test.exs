defmodule Commonplace.ApplicationBootPostureTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup do
    keys = [:local_write_gate, :local_read_gate, :trust, :reflog_on_boot]
    old_values = Map.new(keys, &{&1, Application.fetch_env(:commonplace, &1)})
    old_log_level = :logger.get_primary_config()[:level]
    :ok = Logger.configure(level: :info)

    on_exit(fn ->
      :ok = Logger.configure(level: old_log_level)

      Enum.each(old_values, fn
        {key, {:ok, value}} -> Application.put_env(:commonplace, key, value)
        {key, :error} -> Application.delete_env(:commonplace, key)
      end)
    end)

    :ok
  end

  test "boot fact distinguishes an absent-defaulted write gate" do
    Application.delete_env(:commonplace, :local_write_gate)

    log =
      capture_log([level: :info], fn -> Commonplace.Application.log_trust_posture_at_boot() end)

    assert log =~ "Commonplace.Trust posture at boot"
    assert log =~ "local_write_gate: :dry_run (ABSENT — defaulted)"
  end

  test "boot fact distinguishes an env-set write gate" do
    Application.put_env(:commonplace, :local_write_gate, "enforce")

    log =
      capture_log([level: :info], fn -> Commonplace.Application.log_trust_posture_at_boot() end)

    assert log =~ "local_write_gate: :enforce (env-set)"
  end

  test "boot fact distinguishes an absent-defaulted read gate" do
    Application.delete_env(:commonplace, :local_read_gate)

    log =
      capture_log([level: :info], fn -> Commonplace.Application.log_trust_posture_at_boot() end)

    assert log =~ "local_read_gate: :permissive (ABSENT — defaulted)"
  end

  test "boot fact distinguishes an env-set read gate after resolution" do
    Application.put_env(:commonplace, :local_read_gate, "enforce")

    log =
      capture_log([level: :info], fn -> Commonplace.Application.log_trust_posture_at_boot() end)

    assert log =~ "local_read_gate: :enforce (env-set)"
  end
end
