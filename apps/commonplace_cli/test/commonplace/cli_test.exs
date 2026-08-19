defmodule Commonplace.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "help text includes commands" do
    assert Commonplace.CLI.__info__(:functions) |> Keyword.has_key?(:main)
  end

  test "init owns first-checkout registration without changing its output" do
    checkout_dir =
      Path.join(System.tmp_dir!(), "cp_cli_init_#{System.unique_integer([:positive])}")

    data_dir = Path.join(checkout_dir, ".commonplace")
    File.mkdir_p!(checkout_dir)

    on_exit(fn ->
      _ = Application.stop(:commonplace)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data", persistent: true)
      File.rm_rf!(checkout_dir)
      {:ok, _} = Application.ensure_all_started(:commonplace)
    end)

    output = capture_io(fn -> Commonplace.CLI.Init.run(data_dir, []) end)
    root_uuid = Commonplace.CLI.root_uuid(data_dir)

    assert output ==
             "Initialized commonplace workspace at #{data_dir}\n" <>
               "Root: #{root_uuid}\n"

    assert [
             %{
               "sync_dir" => ^checkout_dir,
               "type" => "dir",
               "uuid" => ^root_uuid
             }
           ] = data_dir |> Path.join("checkouts.json") |> File.read!() |> Jason.decode!()

    source =
      __DIR__
      |> Path.join("../../lib/commonplace/cli/init.ex")
      |> Path.expand()
      |> File.read!()

    assert source =~ "CheckoutRegistry.start_link",
           "CLI init must own the checkout registry lifetime above the core seam"

    assert source =~ "CheckoutRegistry.register",
           "CLI init must register the first checkout above the core seam"
  end
end
