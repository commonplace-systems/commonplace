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

  # The non-empty rendering lived in core's ProtoChitHarvestTest as a
  # cross-app call — an UNDECLARED dep on this app (commonplace_cli is not
  # and cannot be a dep of commonplace: cycle), so the core suite was
  # deterministically red on every per-app run and green in CI only by
  # umbrella-root code paths (plan #14425 finding 3 / #14426 rank 3).
  # The rendering assertion belongs where the renderer lives: here.
  test "log renders a signed entry: verb, author, [signature present], message", ctx do
    log_uuid = UUID.uuid4()
    {pub, priv} = Commonplace.Crypto.Signing.generate_keypair()

    signing_ctx = %Commonplace.Crypto.SigningContext{
      identity_uuid: "a1c-deploy-signer",
      private_key: priv,
      public_key: pub
    }

    event = %{
      "verb" => "commit",
      "author-principal" => "a1c-deploy-signer",
      "message" => "rendered by the CLI",
      "proto-pin" => nil,
      "predecessor-ref" => nil,
      "git-sha" => nil
    }

    assert {:ok, %{event_ref: _}} =
             Commonplace.ProtoChit.ingest_verified(log_uuid, event, signing_ctx)

    {status, output} =
      with_io(fn ->
        Commonplace.CLI.ProtoChit.run(ctx.data_dir, "", ["log", "--event-log", log_uuid])
      end)

    assert status == 0
    assert output =~ "commit  by a1c-deploy-signer  [signature present]"
    assert output =~ "message: rendered by the CLI"
  end
end
