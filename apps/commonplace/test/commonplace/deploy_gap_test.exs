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
  # starts. Its reference is the serve's start instant: a beam newer than that
  # instant is code the lazily-loading serve did not start with. A test VM has
  # no equivalent reference because compilation normally follows its start.
  # The mechanism (`--assert-empty`, per-beam enumeration) is exercised below.
  #
  # A positive control proved this could fire; nothing proved it fires ONLY
  # when it should.

  @tag :tmp_dir
  test "assertion stays quiet when every beam predates the subject", %{tmp_dir: tmp_dir} do
    build_dir = Path.join(tmp_dir, "lib")
    older_beam = Path.join([build_dir, "older", "ebin", "Older.beam"])

    File.mkdir_p!(Path.dirname(older_beam))
    File.write!(older_beam, "older")
    File.touch!(older_beam, {{2020, 1, 1}, {0, 0, 0}})

    assert File.dir?(build_dir), "deploy-gap scan target does not exist: #{build_dir}"

    assert Path.wildcard(Path.join([build_dir, "*", "ebin", "*.beam"])) == [older_beam],
           "deploy-gap TRUE-NEGATIVE corpus is empty or pointed at the wrong build — a 0-beam scan would exit 0 for the wrong reason"

    {output, status} =
      System.cmd(@script, ["--assert-empty", "--since", "2025-01-01T00:00:00Z"],
        env: [{"CP_BUILD_DIR", build_dir}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "WOULD-DEPLOY-ON-RESTART: 0 beam(s) newer than that start"
    refute output =~ "ASSERTION FAILED"
    refute output =~ "    #{older_beam}\n"
  end

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
end
