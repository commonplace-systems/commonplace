defmodule Mix.Tasks.Commonplace.MixedPlaneScanTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Commonplace.MixedPlaneScan

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "mixed-plane-mix-task-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "--incremental selects the incremental history path", %{dir: dir} do
    output =
      capture_io(fn ->
        MixedPlaneScan.run([
          "--fixture",
          "--checkpoint",
          Path.join(dir, "incremental"),
          "--incremental"
        ])
      end)

    assert output =~ "SWEEP START"
    assert output =~ "strategy=incremental"
  end
end
