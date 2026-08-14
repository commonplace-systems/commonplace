defmodule Commonplace.DeployGapMonitorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Commonplace.DeployGapMonitor

  setup do
    fixture = Path.join(System.tmp_dir!(), "cp_deploy_gap_#{System.unique_integer([:positive])}")
    build_dir = Path.join(fixture, "lib/sample/ebin")
    File.mkdir_p!(build_dir)

    beam = Path.join(build_dir, "Elixir.Sample.beam")
    File.write!(beam, "synthetic beam fixture")

    reference = System.os_time(:second) - 10
    original_mtime = reference - 10
    File.touch!(beam, original_mtime)

    on_exit(fn -> File.rm_rf!(fixture) end)

    command = Path.expand("../../../../bin/cp-deploy-gap", __DIR__)

    opts = [
      command: command,
      args: ["--assert-empty", "--since", "@#{reference}"],
      command_opts: [
        cd: Path.dirname(Path.dirname(command)),
        env: [{"CP_BUILD_DIR", Path.join(fixture, "lib")}],
        stderr_to_stdout: true
      ]
    ]

    %{beam: beam, original_mtime: original_mtime, opts: opts}
  end

  test "normal state is quiet", %{opts: opts} do
    assert DeployGapMonitor.check(opts) == :quiet
    assert capture_log(fn -> DeployGapMonitor.report(:quiet) end) == ""
  end

  test "a newer beam is named in unsolicited error output, then restoration is quiet", %{
    beam: beam,
    original_mtime: original_mtime,
    opts: opts
  } do
    File.touch!(beam, System.os_time(:second))

    assert {:gap, output} = DeployGapMonitor.check(opts)
    assert output =~ "WOULD-DEPLOY-ON-RESTART: 1 beam(s)"
    assert output =~ "Elixir.Sample.beam"

    log =
      capture_log(fn ->
        pid = start_supervised!({DeployGapMonitor, opts})
        _ = :sys.get_state(pid)
        Logger.flush()
      end)

    assert log =~ "DEPLOY GAP DETECTED"
    assert log =~ "Elixir.Sample.beam"

    File.touch!(beam, original_mtime)
    assert DeployGapMonitor.check(opts) == :quiet
    assert capture_log(fn -> DeployGapMonitor.report(:quiet) end) == ""
  end

  test "measurement failure is distinct from an empty gap", %{opts: opts} do
    missing_opts =
      Keyword.update!(opts, :command_opts, fn command_opts ->
        Keyword.put(command_opts, :env, [{"CP_BUILD_DIR", "/does/not/exist"}])
      end)

    assert {:error, 2, output} = error = DeployGapMonitor.check(missing_opts)
    assert output =~ "cp-deploy-gap: no /does/not/exist"

    log = capture_log(fn -> DeployGapMonitor.report(error) end)
    assert log =~ "DEPLOY GAP MONITOR FAILED"
    assert log =~ "gauge exit 2"
  end

  test "an unavailable gauge is reported instead of crashing" do
    assert {:error, :exec, output} =
             error = DeployGapMonitor.check(command: "/does/not/exist/cp-deploy-gap")

    assert output =~ ":enoent"

    log = capture_log(fn -> DeployGapMonitor.report(error) end)
    assert log =~ "DEPLOY GAP MONITOR FAILED"
    assert log =~ "gauge exit exec"
  end
end
