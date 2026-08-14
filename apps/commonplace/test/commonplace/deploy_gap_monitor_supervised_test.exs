defmodule Commonplace.DeployGapMonitorSupervisedTest do
  # ⛔ THIS FILE EXISTS BECAUSE THE RESCUE WAS PROVEN AT THE FUNCTION LEVEL AND
  # THE OUTAGE IS AT THE PROCESS LEVEL.
  #
  # `deploy_gap_monitor_test.exs` proves `check/1` returns `{:error, :exec, _}`
  # and that `report/1` logs it. Both are true and neither exercises the child
  # under a supervisor — which is where the failure would actually land.
  #
  # Reproduced in a standalone harness on 2026-08-14, with the rescue removed:
  # `System.cmd` RAISES `ErlangError :enoent` on a missing binary rather than
  # returning `{_, status}`; the child re-checks on `init`, so a crash restarts
  # into another crash; measured FOUR terminations and then the supervisor
  # exited `:shutdown`. In `Commonplace.Supervisor` under `:one_for_one` that is
  # the application — the serve gone about a second after boot, and staying
  # gone.
  #
  # ⭐ So the assertion that matters is not "check/1 handles it" but "the CHILD
  # IS STILL ALIVE and the SUPERVISOR IS STILL ALIVE after the failing check has
  # actually run" — and that it SAID SOMETHING, because a child that survives
  # silently is the quiet failure this whole ticket is about.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Commonplace.DeployGapMonitor

  @missing "/does/not/exist/cp-deploy-gap"

  test "a missing gauge does not take the supervisor down, and does not fail silently" do
    log =
      capture_log(fn ->
        {:ok, sup} =
          Supervisor.start_link(
            [
              %{
                id: DeployGapMonitor,
                start:
                  {DeployGapMonitor, :start_link,
                   [[command: @missing, interval_ms: 50, name: :deploy_gap_monitor_sup_test]]}
              }
            ],
            strategy: :one_for_one
          )

        # The first check is sent from init/1, so it has already been queued.
        # Wait past several intervals: if the child were crashing, restart
        # intensity would be exceeded in well under this window (measured: 4
        # terminations, then :shutdown).
        Process.sleep(300)

        child = Process.whereis(:deploy_gap_monitor_sup_test)

        assert is_pid(child) and Process.alive?(child),
               "the monitor child died on a missing gauge — this is the serve-outage path"

        assert Process.alive?(sup),
               "the SUPERVISOR died on a missing gauge — in the real tree this is the serve"

        # Prove the child is still doing its job rather than merely existing.
        assert DeployGapMonitor.check(command: @missing) == :quiet or
                 match?({:error, :exec, _}, DeployGapMonitor.check(command: @missing))

        Supervisor.stop(sup)
      end)

    assert log =~ "DEPLOY GAP MONITOR FAILED",
           "the child survived but said nothing — a silent monitor is the failure this ticket exists to prevent"

    assert log =~ ":enoent",
           "the log must name WHAT went wrong; 'it failed' costs the next reader the investigation"
  end

  test "it announces itself at boot, so silence is distinguishable from death" do
    # config/test.exs pins Logger to :warning, so an :info line is filtered
    # before any handler sees it. The SERVE records :info (verified in the live
    # log), so the line is real in production — this raises the level only to
    # make it assertable here.
    prior = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: prior) end)

    log =
      capture_log(fn ->
        {:ok, pid} =
          DeployGapMonitor.start_link(
            command: @missing,
            interval_ms: 60_000,
            name: :deploy_gap_monitor_boot_line_test
          )

        Process.sleep(100)
        GenServer.stop(pid)
      end)

    assert log =~ "DeployGapMonitor armed",
           "no boot line — 'quiet because the gap is 0' and 'never started' would be the same observation"

    assert log =~ @missing,
           "the boot line must name the resolved gauge path, or a wrong path is invisible until the first check"
  end
end
