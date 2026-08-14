defmodule Commonplace.DeployGapTest do
  use ExUnit.Case, async: false

  @script Path.expand("../../../../bin/cp-deploy-gap", __DIR__)

  # ⛔ REMOVED 2026-08-14, SAME DAY IT LANDED — it was RED ON CORRECT STATE.
  #
  # The arm asserted "no beam in the build is newer than the RUNNING TEST VM".
  # That reference is wrong for this subject BY CONSTRUCTION: `mix test` boots
  # the VM and THEN compiles, so every beam recompiled during the run is newer
  # than the VM start. Measured: a clean tree, no source change to the flagged
  # modules, 10 beams reported, rc 2. It passed only when nothing needed
  # recompiling — i.e. intermittently, which is the worst property a gate can
  # have, and `--no-compile` was already circulating as the workaround.
  #
  # The gauge itself is correct for the SERVE, which does not compile after it
  # starts. The mechanism (`--assert-empty`, per-beam enumeration) is kept and
  # is exercised by the synthetic test below. Re-landing a serve-side check is
  # CX-beph; the false-positive analysis is its own row.
  #
  # A positive control proved this could fire; nothing proved it fires ONLY
  # when it should.

  @tag :tmp_dir
  test "assertion failure enumerates every newer beam", %{tmp_dir: tmp_dir} do
    build_dir = Path.join(tmp_dir, "lib")
    older_beam = Path.join([build_dir, "older", "ebin", "Older.beam"])
    newer_beam = Path.join([build_dir, "newer", "ebin", "Newer.beam"])

    File.mkdir_p!(Path.dirname(older_beam))
    File.mkdir_p!(Path.dirname(newer_beam))
    File.write!(older_beam, "older")
    File.write!(newer_beam, "newer")
    File.touch!(older_beam, {{2020, 1, 1}, {0, 0, 0}})
    File.touch!(newer_beam, {{2030, 1, 1}, {0, 0, 0}})

    assert Path.wildcard(Path.join([build_dir, "*", "ebin", "*.beam"])) ==
             [newer_beam, older_beam]

    {output, status} =
      System.cmd(@script, ["--assert-empty", "--since", "2025-01-01T00:00:00Z"],
        env: [{"CP_BUILD_DIR", build_dir}],
        stderr_to_stdout: true
      )

    assert status == 1
    assert output =~ "ASSERTION FAILED — 1 beam(s)"
    assert output =~ newer_beam
    refute output =~ "    #{older_beam}\n"
  end

  defp test_vm_started_at do
    {elapsed_ms, _since_last_call_ms} = :erlang.statistics(:wall_clock)

    System.system_time(:millisecond)
    |> Kernel.-(elapsed_ms)
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end
end
