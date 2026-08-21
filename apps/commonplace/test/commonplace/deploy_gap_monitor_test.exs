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

  # A minimal ledger state for driving decide/3 without the GenServer.
  defp state(overrides \\ []) do
    base = %{last: :unset, since_ms: nil, ticks: 0, ticks_since_heartbeat: 0, heartbeat_every: 3}
    Map.merge(base, Map.new(overrides))
  end

  test "check returns :quiet on an empty gap", %{opts: opts} do
    assert DeployGapMonitor.check(opts) == :quiet
  end

  test "the supervised monitor logs the gap ONCE on the opening tick", %{
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
  end

  test "check distinguishes a measurement failure from an empty gap", %{opts: opts} do
    missing_opts =
      Keyword.update!(opts, :command_opts, fn command_opts ->
        Keyword.put(command_opts, :env, [{"CP_BUILD_DIR", "/does/not/exist"}])
      end)

    assert {:error, 2, output} = DeployGapMonitor.check(missing_opts)
    assert output =~ "cp-deploy-gap: no /does/not/exist"
  end

  test "an unavailable gauge is reported instead of crashing" do
    assert {:error, :exec, output} =
             DeployGapMonitor.check(command: "/does/not/exist/cp-deploy-gap")

    assert output =~ ":enoent"
  end

  # ── candidate 3: the ledger — log on state change, NOT every tick ──────────
  describe "decide/3 (the ledger state machine)" do
    test "an empty gap is silent — no action, from :unset and while it persists" do
      assert {[], s1} = DeployGapMonitor.decide(:quiet, 0, state())
      assert s1.last == :quiet
      assert {[], _} = DeployGapMonitor.decide(:quiet, 100, s1)
    end

    test "a gap OPENING logs exactly once" do
      assert {[{:condition, {:gap, "out"}, :opened}], s1} =
               DeployGapMonitor.decide({:gap, "out"}, 100, state())

      assert s1.last == {:gap, "out"}
      assert s1.ticks == 1
    end

    test "an UNCHANGED gap does NOT re-log every tick — heartbeat only at the cadence" do
      # heartbeat_every: 3 → two silent ticks, then one heartbeat.
      s0 = state(last: {:gap, "out"}, since_ms: 0, ticks: 1, heartbeat_every: 3)

      assert {[], s1} = DeployGapMonitor.decide({:gap, "out"}, 10, s0)
      assert s1.ticks_since_heartbeat == 1

      assert {[], s2} = DeployGapMonitor.decide({:gap, "out"}, 20, s1)
      assert s2.ticks_since_heartbeat == 2

      assert {[{:heartbeat, {:gap, "out"}, age, ticks}], s3} =
               DeployGapMonitor.decide({:gap, "out"}, 30, s2)

      assert age == 30
      assert ticks == 4
      assert s3.ticks_since_heartbeat == 0
    end

    test "a gap CLEARING logs the end, with how long it stood" do
      s0 = state(last: {:gap, "out"}, since_ms: 0, ticks: 5)
      assert {[{:ended, {:gap, "out"}, 500, 5}], s1} = DeployGapMonitor.decide(:quiet, 500, s0)
      assert s1.last == :quiet
    end

    test "a gap whose beam set CHANGES ends the old row and opens the new" do
      s0 = state(last: {:gap, "1 beam"}, since_ms: 0, ticks: 9)

      assert {[{:ended, {:gap, "1 beam"}, _, 9}, {:condition, {:gap, "2 beams"}, :changed}], s1} =
               DeployGapMonitor.decide({:gap, "2 beams"}, 90, s0)

      assert s1.last == {:gap, "2 beams"}
      assert s1.ticks == 1
    end

    test "a persistent gauge FAILURE also heartbeats, not floods" do
      s0 = state(last: {:error, 2, "boom"}, since_ms: 0, ticks: 1, heartbeat_every: 2)
      assert {[], s1} = DeployGapMonitor.decide({:error, 2, "boom"}, 10, s0)

      assert {[{:heartbeat, {:error, 2, "boom"}, _, _}], _} =
               DeployGapMonitor.decide({:error, 2, "boom"}, 20, s1)
    end
  end

  describe "emit/1 (log banners)" do
    test "opened → DEPLOY GAP DETECTED" do
      log =
        capture_log(fn ->
          DeployGapMonitor.emit(
            {:condition, {:gap, "WOULD-DEPLOY-ON-RESTART: 1 beam(s)\n    Elixir.Sample.beam"},
             :opened}
          )
        end)

      assert log =~ "DEPLOY GAP DETECTED"
      assert log =~ "Elixir.Sample.beam"
    end

    test "changed → DEPLOY GAP CHANGED" do
      log = capture_log(fn -> DeployGapMonitor.emit({:condition, {:gap, "x"}, :changed}) end)
      assert log =~ "DEPLOY GAP CHANGED"
    end

    test "heartbeat → STILL OPEN with its age" do
      log =
        capture_log(fn ->
          DeployGapMonitor.emit(
            {:heartbeat, {:gap, "WOULD-DEPLOY-ON-RESTART: 7 beam(s) newer"}, 90_000_000, 100}
          )
        end)

      assert log =~ "DEPLOY GAP STILL OPEN"
      assert log =~ "1.0d"
      assert log =~ "WOULD-DEPLOY-ON-RESTART: 7 beam(s)"
    end

    test "ended → DEPLOY GAP CLEARED (warning: co-visible with the :error open)" do
      log = capture_log(fn -> DeployGapMonitor.emit({:ended, {:gap, "x"}, 3_600_000, 60}) end)
      assert log =~ "DEPLOY GAP CLEARED"
      assert log =~ "1.0h"
    end

    test "ended error → DEPLOY GAP MONITOR RECOVERED (warning)" do
      log = capture_log(fn -> DeployGapMonitor.emit({:ended, {:error, 2, "boom"}, 60_000, 1}) end)
      assert log =~ "DEPLOY GAP MONITOR RECOVERED"
    end

    test "error condition → MONITOR FAILED with the exit" do
      log =
        capture_log(fn -> DeployGapMonitor.emit({:condition, {:error, 2, "boom"}, :opened}) end)

      assert log =~ "DEPLOY GAP MONITOR FAILED"
      assert log =~ "exit 2"
    end
  end
end
