defmodule Commonplace.Crypto.DelegationRootTest do
  @moduledoc """
  ROOTKEY-R1 acceptance arms for the delegation-root key-material ceremony.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Crypto.{DelegationRoot, Signing}

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "cp_delegation_root_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(data_dir)
    on_exit(fn -> File.rm_rf!(data_dir) end)

    %{data_dir: data_dir}
  end

  test "arm 1: the public key and signatures remain usable while the private file is masked",
       %{data_dir: data_dir} do
    assert :ok = DelegationRoot.provision!(data_dir)
    assert {:ok, private_key} = DelegationRoot.private_key(data_dir)
    assert {:ok, expected_public_key} = DelegationRoot.public_key(data_dir)

    payload = "ROOTKEY-R1 masking fixture"
    signature = :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])

    private_path = Path.join(data_dir, "delegation_root_key")
    File.write!(private_path, "")
    assert File.stat!(private_path).size == 0
    assert DelegationRoot.provisioned?(data_dir)

    assert {:ok, ^expected_public_key} = DelegationRoot.public_key(data_dir)

    assert :crypto.verify(
             :eddsa,
             :none,
             payload,
             signature,
             [expected_public_key, :ed25519]
           )
  end

  test "arm 2: private-key lookup refuses absence by name and never mints", %{
    data_dir: data_dir
  } do
    before = File.ls!(data_dir)
    private_path = Path.join(data_dir, "delegation_root_key")

    assert {:error, {:delegation_root_absent, ^private_path}} =
             DelegationRoot.private_key(data_dir)

    assert File.ls!(data_dir) == before
  end

  test "arm 3: the ceremony refuses reprovision and leaves both artifacts byte-unchanged", %{
    data_dir: data_dir
  } do
    assert :ok = DelegationRoot.provision!(data_dir)

    private_path = Path.join(data_dir, "delegation_root_key")
    public_path = Path.join(data_dir, "delegation_root_pub")
    before = artifact_hashes(private_path, public_path)

    assert {:error, {:delegation_root_already_exists, ^private_path}} =
             DelegationRoot.provision!(data_dir)

    assert artifact_hashes(private_path, public_path) == before
  end

  test "arm 4: the ceremony creates a complete usable pair and flips provisioned?", %{
    data_dir: data_dir
  } do
    refute DelegationRoot.provisioned?(data_dir)
    assert :ok = DelegationRoot.provision!(data_dir)
    assert DelegationRoot.provisioned?(data_dir)

    private_path = Path.join(data_dir, "delegation_root_key")
    public_path = Path.join(data_dir, "delegation_root_pub")
    assert File.exists?(private_path)
    assert File.exists?(public_path)
    assert Bitwise.band(File.stat!(private_path).mode, 0o777) == 0o600

    assert {:ok, private_key} = DelegationRoot.private_key(data_dir)
    assert {:ok, public_key} = DelegationRoot.public_key(data_dir)
    assert File.read!(public_path) == Signing.encode_key(public_key)

    payload = "ROOTKEY-R1 completeness fixture"
    signature = :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])
    assert :crypto.verify(:eddsa, :none, payload, signature, [public_key, :ed25519])
  end

  defp artifact_hashes(private_path, public_path) do
    for path <- [private_path, public_path], into: %{} do
      {path, path |> File.read!() |> then(&:crypto.hash(:sha256, &1))}
    end
  end
end
