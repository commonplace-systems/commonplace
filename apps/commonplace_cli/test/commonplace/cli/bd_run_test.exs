defmodule Commonplace.CLI.BdRunTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Commonplace.CLI
  alias Commonplace.Tree.Schema

  setup do
    workspace = Path.join(System.tmp_dir!(), "cp_cli_bd_run_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(workspace)

    on_exit(fn ->
      _ = Application.stop(:commonplace)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data", persistent: true)
      File.rm_rf!(workspace)
      {:ok, _} = Application.ensure_all_started(:commonplace)
    end)

    %{workspace: workspace}
  end

  test "a refused bd ensure stops the CLI command and names the refusal", %{workspace: workspace} do
    _output = capture_io(fn -> Commonplace.CLI.Init.run(workspace, ["--profile", "minimal"]) end)
    root = CLI.root_uuid(workspace)

    {result, stderr} =
      capture_result(:stderr, fn -> Commonplace.CLI.Bd.run(workspace, "", ["list"]) end)

    refusal =
      "bd ensure refused before CLI bd command: " <>
        "{:trust_rejected, \"workspace class 'minimal' does not accept root entry 'bd' — declared in profile\"}; " <>
        "CLI bd command did not run"

    assert result == {:error, refusal}
    assert stderr == "REFUSED: #{refusal}\n"
    assert :error = Schema.get_entry(CLI.load_schema(root), "bd")
  end

  test "a default workspace still runs the CLI bd command", %{workspace: workspace} do
    _output = capture_io(fn -> Commonplace.CLI.Init.run(workspace, ["--profile", "default"]) end)
    root = CLI.root_uuid(workspace)

    output = capture_io(fn -> assert :ok = Commonplace.CLI.Bd.run(workspace, "", ["list"]) end)

    assert output == "(no issues)\n"
    assert {:ok, _entry} = Schema.get_entry(CLI.load_schema(root), "bd")
  end

  defp capture_result(device, fun) do
    ref = make_ref()
    parent = self()
    output = capture_io(device, fn -> send(parent, {ref, fun.()}) end)
    assert_receive {^ref, result}
    {result, output}
  end
end
