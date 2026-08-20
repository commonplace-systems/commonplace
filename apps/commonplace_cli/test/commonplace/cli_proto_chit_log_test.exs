defmodule Commonplace.CLIProtoChitLogTest do
  @moduledoc """
  A2 read surface wiring: `commonplace proto-chit log` parses, walks an
  event log read-only, and renders. Chain semantics (ordering, pairing,
  refusal) are covered in core's ProtoChitChainTest; this file proves the
  CLI wiring and the empty-chain case end-to-end through run/3.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    checkout_dir =
      Path.join(System.tmp_dir!(), "cp_cli_pclog_#{System.unique_integer([:positive])}")

    data_dir = Path.join(checkout_dir, ".commonplace")
    File.mkdir_p!(checkout_dir)

    on_exit(fn ->
      _ = Application.stop(:commonplace)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data", persistent: true)
      File.rm_rf!(checkout_dir)
      {:ok, _} = Application.ensure_all_started(:commonplace)
    end)

    capture_io(fn -> Commonplace.CLI.Init.run(data_dir, []) end)
    %{data_dir: data_dir}
  end

  test "log on an empty event log exits 0 and prints nothing", ctx do
    log_uuid = UUID.uuid4()

    {status, output} =
      with_io(fn ->
        Commonplace.CLI.ProtoChit.run(ctx.data_dir, "", ["log", "--event-log", log_uuid])
      end)

    assert status == 0
    assert output == ""
  end

  test "log refuses a missing --event-log", ctx do
    {status, stderr} =
      with_io(:stderr, fn ->
        Commonplace.CLI.ProtoChit.run(ctx.data_dir, "", ["log"])
      end)

    assert status == 1
    assert stderr =~ "missing_option"
  end
end
