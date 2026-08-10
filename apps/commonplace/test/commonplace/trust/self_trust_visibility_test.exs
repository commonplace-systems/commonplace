defmodule Commonplace.Trust.SelfTrustVisibilityTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Commonplace.Crypto.{NodeIdentity, Signing}
  alias Commonplace.Trust

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cp_self_trust_visibility_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    prior_trust = Application.get_env(:commonplace, :trust)

    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, strict_config())

    on_exit(fn ->
      restore_env(:data_dir, prior_data_dir)
      restore_env(:trust, prior_trust)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "an absent public-key artifact makes missing self-trust loud" do
    assert :absent = NodeIdentity.public_keys()

    {cfg, log} = capture_config()

    assert cfg == strict_config()
    assert log =~ "error local node self-trust was not added"
    assert log =~ "public-key artifact is absent"
  end

  test "an unreadable public-key artifact is distinct from absence", %{dir: dir} do
    public_keys_path = Path.join(dir, "node_signing_public_keys.json")
    File.mkdir_p!(public_keys_path)

    assert File.exists?(public_keys_path)
    assert {:error, :eisdir} = NodeIdentity.public_keys()

    {cfg, log} = capture_config()

    assert cfg == strict_config()
    assert log =~ "error local node self-trust was not added"
    assert log =~ "public-key artifact is present but unreadable"
    assert log =~ ":eisdir"
  end

  test "a public-key artifact declaring zero keys is distinct from absence", %{dir: dir} do
    public_keys_path = Path.join(dir, "node_signing_public_keys.json")
    File.write!(public_keys_path, Jason.encode!([]) <> "\n")

    assert {:ok, []} = NodeIdentity.public_keys()

    {cfg, log} = capture_config()

    assert cfg == strict_config()
    assert log =~ "error local node self-trust was not added"
    assert log =~ "public-key artifact declares zero keys"
  end

  test "an unavailable node identity is reported separately", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "node_id"))
    {public_key, _private_key} = Signing.generate_keypair()

    File.write!(
      Path.join(dir, "node_signing_public_keys.json"),
      Jason.encode!([Signing.encode_key(public_key)]) <> "\n"
    )

    assert {:error, :eisdir} = NodeIdentity.identity()
    assert {:ok, [^public_key]} = NodeIdentity.public_keys()

    {cfg, log} = capture_config()

    assert cfg == strict_config()
    assert log =~ "error local node self-trust was not added"
    assert log =~ "node identity could not be sourced"
    assert log =~ ":eisdir"
    refute log =~ "public-key artifact"
  end

  test "a healthy local identity is folded into trust without logging" do
    assert {:ok, node_ctx} = NodeIdentity.signing_context()
    assert {:ok, [node_ctx.public_key]} == NodeIdentity.public_keys()

    positive_control =
      capture_log([format: "$level $message\n"], fn ->
        Logger.error("self-trust visibility positive control")
      end)

    assert positive_control == "error self-trust visibility positive control\n"

    {cfg, log} = capture_config()

    assert cfg.trusted_identities[node_ctx.identity_uuid] == [
             Signing.encode_key(node_ctx.public_key)
           ]

    assert log == ""
  end

  defp capture_config do
    caller = self()
    ref = make_ref()

    log =
      capture_log([format: "$level $message\n"], fn ->
        send(caller, {ref, Trust.config()})
      end)

    assert_receive {^ref, cfg}
    {cfg, log}
  end

  defp strict_config do
    %{accept_unsigned: false, trusted_identities: %{}}
  end

  defp restore_env(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore_env(key, value), do: Application.put_env(:commonplace, key, value)
end
