defmodule Commonplace.DeployGapTest do
  use ExUnit.Case, async: false

  @script Path.expand("../../../../bin/cp-deploy-gap", __DIR__)

  test "CI build has no beams newer than the running test VM" do
    build_dir = Path.join(Mix.Project.build_path(), "lib")
    beams = Path.wildcard(Path.join([build_dir, "*", "ebin", "*.beam"]))

    assert File.dir?(build_dir), "deploy-gap scan target does not exist: #{build_dir}"
    assert beams != [], "deploy-gap positive-control corpus is empty under: #{build_dir}"

    {output, status} =
      System.cmd(@script, ["--assert-empty", "--since", test_vm_started_at()],
        env: [{"CP_BUILD_DIR", build_dir}],
        stderr_to_stdout: true
      )

    assert status == 0, output
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

  defp test_vm_started_at do
    {elapsed_ms, _since_last_call_ms} = :erlang.statistics(:wall_clock)

    System.system_time(:millisecond)
    |> Kernel.-(elapsed_ms)
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end
end
