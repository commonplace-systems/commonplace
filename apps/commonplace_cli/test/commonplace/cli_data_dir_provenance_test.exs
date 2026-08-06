defmodule Commonplace.CLI.DataDirProvenanceTest do
  @moduledoc """
  CX-x8jk defect 3: when the CLI resolves its data dir by walking up from
  cwd, it must say so — one stderr line naming the resolved path, before
  anything is opened.

  The 2026-08-06 incident was documented usage from a directory that
  looked ordinary; the walk-up landed on the live `workspace/.commonplace`
  and nothing said so until the store crashed.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Commonplace.CLI

  test "the announcement names the resolved path, expanded, on stderr" do
    dir = Path.join(System.tmp_dir!(), "cx_x8jk_prov/./sub/../.commonplace")

    out = capture_io(:stderr, fn -> assert CLI.announce_data_dir(dir, :cwd) == dir end)

    assert out =~ "data dir"
    assert out =~ "resolved from cwd"
    assert out =~ Path.expand(dir)
    # Expanded, so the operator sees the real location and not a path
    # they have to resolve in their head.
    refute out =~ "/./"
    assert length(String.split(String.trim(out), "\n")) == 1
  end

  test "every cwd-resolved branch of main/1 goes through the announcement" do
    # A source guard: the value of this line is that it is printed on the
    # path an operator actually takes, so the two places main/1 resolves a
    # data dir from cwd (`init`, and the walk-up for every other command)
    # must both call it. `-d/--data_dir` must NOT — that is the operator
    # telling us, and echoing it back is noise.
    source = File.read!(Path.join(__DIR__, "../../lib/commonplace/cli.ex"))

    init_branch =
      source
      |> String.split("[\"init\" | rest] ->")
      |> Enum.at(1)
      |> String.split("Commonplace.CLI.Init.run")
      |> Enum.at(0)

    assert init_branch =~ "announce_data_dir",
           "init resolves .commonplace from cwd without announcing it"

    assert source =~ "run_command(cmd, announce_data_dir(data_dir, :cwd), relative_path, rest)",
           "the walk-up branch of main/1 no longer announces its resolved data dir"

    assert source =~ ~r/# -d override.*\n\s*run_command\(cmd, data_dir, "", rest\)/,
           "the -d override branch should pass data_dir through unannounced"
  end
end
