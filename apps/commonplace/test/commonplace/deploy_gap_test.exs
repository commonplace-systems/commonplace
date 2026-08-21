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

  # ── candidate 2: serve identity via the socket it OWNS, not an argv substring ─
  #
  # The prior identity (`pgrep -f 'commonplace_dev'`) matched any process that
  # merely NAMED the node on its command line — a `mix run --no-start` probe did,
  # and the deploy-gap monitor fired on the probe. A listening socket is a handle
  # the OS grants to exactly one process; a probe can never hold it. These tests
  # drive the serve-identification branch (no `--since`), which had NO coverage
  # before, using the test VM itself as the "serve": it opens the socket, so ss
  # reports OUR os-pid as the holder.
  describe "serve identity via the listening socket (candidate 2)" do
    @tag :tmp_dir
    test "identifies the process that OWNS the serve port", %{tmp_dir: tmp_dir} do
      build_dir = Path.join(tmp_dir, "lib")
      old_beam = Path.join([build_dir, "old", "ebin", "Old.beam"])
      File.mkdir_p!(Path.dirname(old_beam))
      File.write!(old_beam, "old")
      File.touch!(old_beam, {{2020, 1, 1}, {0, 0, 0}})

      {:ok, sock} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}])
      {:ok, port} = :inet.port(sock)
      os_pid = System.pid()

      try do
        {output, status} =
          System.cmd(@script, [],
            env: [{"CP_SERVE_PORT", Integer.to_string(port)}, {"CP_BUILD_DIR", build_dir}],
            stderr_to_stdout: true
          )

        assert status == 0, output

        assert output =~ "serve pid #{os_pid},",
               "gauge did not identify the process OWNING the :#{port} socket (expected pid #{os_pid}): #{output}"

        assert output =~ "holds the :#{port} listening socket",
               "gauge did not state the socket-ownership method: #{output}"
      after
        :gen_tcp.close(sock)
      end
    end

    @tag :tmp_dir
    test "REFUSES (never reports 0) when nothing listens on the port — the must-fail control",
         %{tmp_dir: tmp_dir} do
      build_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(build_dir)

      # Reserve a port, then release it, so we query a port with NO listener.
      {:ok, sock} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}])
      {:ok, port} = :inet.port(sock)
      :gen_tcp.close(sock)

      {output, status} =
        System.cmd(@script, [],
          env: [{"CP_SERVE_PORT", Integer.to_string(port)}, {"CP_BUILD_DIR", build_dir}],
          stderr_to_stdout: true
        )

      assert status == 2,
             "a port with no listener must REFUSE (exit 2), not report an empty gap — got #{status}: #{output}"

      assert output =~ "no process is listening on :#{port}"
      refute output =~ "WOULD-DEPLOY-ON-RESTART"
    end

    @tag :tmp_dir
    test "matches the port EXACTLY — a prefix port must not resolve to the full-port owner",
         %{tmp_dir: tmp_dir} do
      # This guard is UNEXERCISED by the live host (v4-only, no confusable ports
      # exist to trip over — boss #14130), so this test is the ONLY thing holding
      # it: the class that quietly rots.
      #
      # A naive `grep :Q` over ss output would match a listener on port P whenever
      # `:Q` is a substring of `:P`. In `0.0.0.0:P` the only such `:digits`
      # substrings are `:`+ a PREFIX of P's digits (there is one colon, before the
      # port). So query Q = P with its last digit dropped (a prefix of P): a
      # substring match would resolve Q to the process OWNING P; the exact
      # last-colon-field match must not.
      build_dir = Path.join(tmp_dir, "lib")
      File.mkdir_p!(build_dir)

      {:ok, sock} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}])
      {:ok, p} = :inet.port(sock)
      q = div(p, 10)
      os_pid = System.pid()

      try do
        {output, _status} =
          System.cmd(@script, [],
            env: [{"CP_SERVE_PORT", Integer.to_string(q)}, {"CP_BUILD_DIR", build_dir}],
            stderr_to_stdout: true
          )

        # Robust against a coincidental real listener on Q: on the substring
        # REGRESSION the gauge would report THIS VM's pid (it owns :P); a genuine
        # listener on :Q would report some OTHER pid. Only the regression names
        # os_pid, so this refute discriminates without depending on :Q being free.
        refute output =~ "serve pid #{os_pid}",
               "querying :#{q} (a prefix of :#{p}) resolved to the process owning :#{p} — the port match is a substring, not an exact field: #{output}"
      after
        :gen_tcp.close(sock)
      end
    end
  end
end
