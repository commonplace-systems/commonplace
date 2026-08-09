defmodule Commonplace.Trust.PublicAnchorArtifactTest do
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Store.{Commit, CommitStore}
  alias Commonplace.Trust.{Capability, VerifyChain}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_public_anchor_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"public_anchor_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"public_anchor_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"public_anchor_tss_#{n}",
       pending_imports_name: :"public_anchor_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    old_trust = Application.get_env(:commonplace, :trust)
    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})

    on_exit(fn ->
      restore_env(:data_dir, old_data_dir)
      restore_env(:trust, old_trust)
      File.rm_rf!(dir)
    end)

    %{dir: dir, store: store}
  end

  test "a real node-anchored chain verifies after the private key is masked", %{
    dir: dir,
    store: store
  } do
    assert {:ok, node_ctx} = NodeIdentity.signing_context()

    {alice_pub, alice_priv} = Signing.generate_keypair()

    alice_ctx = %SigningContext{
      identity_uuid: "alice",
      private_key: alice_priv,
      public_key: alice_pub
    }

    assert {:ok, leaf} =
             Capability.issue(
               node_ctx,
               {alice_ctx.identity_uuid, alice_ctx.public_key},
               %{
                 verbs: [:write],
                 scope: {:docs, ["doc-x"]},
                 caveats: %{not_before: nil, not_after: nil}
               }
             )

    :ok = CommitStore.store_capability(store, leaf)

    private_key_path = Path.join(dir, "node_signing_key")
    assert File.exists?(private_key_path)
    :ok = File.rm(private_key_path)
    refute File.exists?(private_key_path)

    anchors =
      Commonplace.Trust.config().trusted_identities
      |> Map.values()
      |> Enum.flat_map(&List.wrap/1)
      |> Enum.map(fn encoded ->
        {:ok, key} = Signing.decode_key(encoded)
        key
      end)
      |> MapSet.new()

    assert {:ok, effective} = VerifyChain.verify_chain(leaf.id, anchors, store)
    assert :write in effective.verbs

    commit =
      Commit.new("doc-x", "payload", nil, %{kind: :regular, capability_proof: leaf.id})
      |> Signing.sign_commit(
        alice_ctx.private_key,
        Signing.signer_id(alice_ctx.identity_uuid, alice_ctx.public_key)
      )

    assert :ok =
             Commonplace.Trust.authorized?(
               commit,
               :write,
               {:doc, "doc-x"},
               %{accept_unsigned: false, trusted_identities: %{}},
               store
             )
  end

  test "public-key requests work with no private-key file", %{dir: dir} do
    assert {:ok, node_ctx} = NodeIdentity.signing_context()

    private_key_path = Path.join(dir, "node_signing_key")
    assert File.exists?(private_key_path)
    :ok = File.rm(private_key_path)
    refute File.exists?(private_key_path)

    public_key = node_ctx.public_key
    assert {:ok, [^public_key]} = NodeIdentity.public_keys()
    assert {:ok, ^public_key} = NodeIdentity.public_key()
    refute File.exists?(private_key_path)
  end

  test "concurrent signing-context requests publish the public artifact without colliding", %{
    dir: dir
  } do
    assert {:ok, node_ctx} = NodeIdentity.signing_context()
    public_keys_path = Path.join(dir, "node_signing_public_keys.json")
    :ok = File.rm(public_keys_path)

    results =
      1..20
      |> Task.async_stream(fn _ -> NodeIdentity.signing_context() end,
        max_concurrency: 20,
        timeout: :infinity
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, %SigningContext{}}}, &1))
    assert {:ok, [node_ctx.public_key]} == NodeIdentity.public_keys()
  end

  test "an absent public artifact is distinguishable from one declaring zero keys", %{dir: dir} do
    assert :absent = NodeIdentity.public_keys()

    public_keys_path = Path.join(dir, "node_signing_public_keys.json")
    File.write!(public_keys_path, Jason.encode!([]) <> "\n")

    assert {:ok, []} = NodeIdentity.public_keys()
    assert {:error, :no_node_public_keys} = NodeIdentity.public_key()
  end

  defp restore_env(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore_env(key, value), do: Application.put_env(:commonplace, key, value)
end
