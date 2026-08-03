defmodule Commonplace.ApplicationReflogGatingTest do
  @moduledoc """
  CX-0t2r (recording-half revival): reflog-on-boot is DOUBLE-GATED like
  bursar_children/0 and ghost_reaper_children/0 — explicit opt-in config
  (`:reflog_on_boot`, default false) AND a resolvable workspace root.
  `Commonplace.Reflog.CheckpointTimer` existed since the sync-agent era but
  was never started anywhere (dormant since 2026-04-25, CX-0t2r hunt
  finding); this test locks in that only a deliberately-configured embedder
  starts it. Mirrors `Commonplace.ApplicationBursarGatingTest`.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Reflog.CheckpointTimer

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_reflog_gate_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    on_exit(fn ->
      Application.delete_env(:commonplace, :reflog_on_boot)
      Application.delete_env(:commonplace, :reflog_interval_ms)
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
    Application.put_env(:commonplace, :reflog_on_boot, false)
    assert Commonplace.Application.reflog_children() == []
  end

  test "flag absent → no child (default off)" do
    assert Commonplace.Application.reflog_children() == []
  end

  test "flag true but no workspace root → no child" do
    Application.put_env(:commonplace, :reflog_on_boot, true)
    assert Commonplace.Application.reflog_children() == []
  end

  test "flag true + workspace root → named permanent CheckpointTimer child spec with default interval",
       %{dir: dir} do
    root_uuid = write_root!(dir)
    Application.put_env(:commonplace, :reflog_on_boot, true)

    assert [spec] = Commonplace.Application.reflog_children()
    assert spec.id == CheckpointTimer
    assert spec.restart == :permanent
    {CheckpointTimer, :start_link, [opts]} = spec.start
    assert opts[:root_uuid] == root_uuid
    assert opts[:name] == CheckpointTimer
    assert opts[:interval] == 300_000
  end

  test "reflog_interval_ms overrides the default tick interval", %{dir: dir} do
    write_root!(dir)
    Application.put_env(:commonplace, :reflog_on_boot, true)
    Application.put_env(:commonplace, :reflog_interval_ms, 42_000)

    assert [spec] = Commonplace.Application.reflog_children()
    {CheckpointTimer, :start_link, [opts]} = spec.start
    assert opts[:interval] == 42_000
  end
end
