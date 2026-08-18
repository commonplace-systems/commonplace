defmodule Commonplace.Trust.SplitRootKeyRotationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Commonplace.Crypto.{DelegationRoot, NodeIdentity, Signing, SigningContext}
  alias Commonplace.Store.{Commit, CommitStore}
  alias Commonplace.Trust.{Capability, VerifyChain}

  setup do
    dir = Path.join(System.tmp_dir!(), "split_root_key_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"split_root_key_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"split_root_key_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"split_root_key_tss_#{n}",
       pending_imports_name: :"split_root_key_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    old_trust = Application.get_env(:commonplace, :trust)
    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, strict_config())

    on_exit(fn ->
      restore_env(:data_dir, old_data_dir)
      restore_env(:trust, old_trust)
      File.rm_rf!(dir)
    end)

    %{dir: dir, store: store}
  end

  test "masked delegation private key leaves its public anchor usable end to end", %{
    dir: dir,
    store: store
  } do
    assert :ok = DelegationRoot.provision!(dir)
    assert {:ok, root_pub} = DelegationRoot.public_key(dir)
    assert {:ok, root_priv} = DelegationRoot.private_key(dir)

    delegate = signing_context("masked-root-delegate")
    cert = issue!(root_context(root_pub, root_priv), delegate, "masked-root-doc")
    :ok = CommitStore.store_capability(store, cert)

    private_path = Path.join(dir, "delegation_root_key")
    File.write!(private_path, <<>>)

    assert DelegationRoot.provisioned?(dir)

    assert {:error, {:corrupt_delegation_root_private_key, ^private_path}} =
             DelegationRoot.private_key(dir)

    anchors = Commonplace.Trust.anchor_keys(strict_config())
    assert MapSet.member?(anchors, root_pub)
    assert {:ok, %{verbs: [:write]}} = VerifyChain.verify_chain(cert.id, anchors, store)
  end

  test "three-phase rotation rehearses overlap before removing the node anchor", %{
    dir: dir,
    store: store
  } do
    assert {:ok, node_ctx} = NodeIdentity.signing_context()
    node_delegate = signing_context("node-generation-delegate")
    node_cert = issue!(node_ctx, node_delegate, "rotation-doc")
    :ok = CommitStore.store_capability(store, node_cert)

    phase_1_anchors = Commonplace.Trust.config() |> Commonplace.Trust.anchor_keys()
    assert {:ok, _effective} = VerifyChain.verify_chain(node_cert.id, phase_1_anchors, store)

    assert :ok = DelegationRoot.provision!(dir)
    assert {:ok, root_pub} = DelegationRoot.public_key(dir)
    assert {:ok, root_priv} = DelegationRoot.private_key(dir)
    root_delegate = signing_context("root-generation-delegate")
    root_cert = issue!(root_context(root_pub, root_priv), root_delegate, "rotation-doc")
    :ok = CommitStore.store_capability(store, root_cert)

    # docs/plans/2026-08-09-delegation-root-design-ticket.md §7.3: rotation is
    # an overlap, not a swap. Both generations must verify before the old anchor
    # is removed, or this rehearsal would skip the safety procedure it protects.
    phase_2_anchors = Commonplace.Trust.config() |> Commonplace.Trust.anchor_keys()
    assert {:ok, _effective} = VerifyChain.verify_chain(node_cert.id, phase_2_anchors, store)
    assert {:ok, _effective} = VerifyChain.verify_chain(root_cert.id, phase_2_anchors, store)

    File.rm!(Path.join(dir, "node_signing_public_keys.json"))
    phase_3_anchors = Commonplace.Trust.config() |> Commonplace.Trust.anchor_keys()
    refute MapSet.member?(phase_3_anchors, node_ctx.public_key)
    assert MapSet.member?(phase_3_anchors, root_pub)
    assert {:ok, _effective} = VerifyChain.verify_chain(root_cert.id, phase_3_anchors, store)

    assert {:error, :untrusted_root} =
             VerifyChain.verify_chain(node_cert.id, phase_3_anchors, store)
  end

  test "delegation root signs certificates but never commits", %{dir: dir, store: store} do
    assert :ok = DelegationRoot.provision!(dir)
    assert {:ok, root_pub} = DelegationRoot.public_key(dir)
    assert {:ok, root_priv} = DelegationRoot.private_key(dir)
    root_ctx = root_context(root_pub, root_priv)

    delegate = signing_context("clean-corpus-delegate")
    delegate_cert = issue!(root_ctx, delegate, "clean-corpus-doc")
    :ok = CommitStore.store_capability(store, delegate_cert)

    clean_commit =
      signed_commit("clean-corpus-doc", delegate, delegate_cert.id)

    assert :ok = CommitStore.import_commit(store, clean_commit)
    assert {:ok, ^clean_commit} = CommitStore.get_commit(store, clean_commit.id)

    root_cert = issue!(root_ctx, root_ctx, "root-signed-commit-doc")
    :ok = CommitStore.store_capability(store, root_cert)
    root_signed_commit = signed_commit("root-signed-commit-doc", root_ctx, root_cert.id)

    assert {:error, {:trust_rejected, :delegation_root_signs_only_certificates}} =
             CommitStore.import_commit(store, root_signed_commit)

    assert :none = CommitStore.get_commit(store, root_signed_commit.id)
  end

  test "phase-three blast radius excludes a compromised node key", %{dir: dir, store: store} do
    assert {:ok, compromised_node_ctx} = NodeIdentity.signing_context()
    attacker_delegate = signing_context("attacker-delegate")
    attacker_cert = issue!(compromised_node_ctx, attacker_delegate, "blast-radius-doc")
    :ok = CommitStore.store_capability(store, attacker_cert)

    assert :ok = DelegationRoot.provision!(dir)
    assert {:ok, root_pub} = DelegationRoot.public_key(dir)
    File.rm!(Path.join(dir, "node_signing_public_keys.json"))

    phase_3_anchors = Commonplace.Trust.config() |> Commonplace.Trust.anchor_keys()
    refute MapSet.member?(phase_3_anchors, compromised_node_ctx.public_key)
    assert MapSet.member?(phase_3_anchors, root_pub)

    assert {:error, :untrusted_root} =
             VerifyChain.verify_chain(attacker_cert.id, phase_3_anchors, store)
  end

  test "absent delegation public artifact is quiet but a corrupt artifact is a degradation", %{
    dir: dir
  } do
    assert capture_log(fn ->
             assert Commonplace.Trust.anchor_keys(strict_config()) == MapSet.new()
           end) == ""

    File.write!(Path.join(dir, "delegation_root_pub"), "not-a-public-key\n")

    log =
      capture_log(fn ->
        assert Commonplace.Trust.anchor_keys(strict_config()) == MapSet.new()
      end)

    assert log =~ "delegation-root public-key artifact is present but unreadable"
    assert log =~ "corrupt_delegation_root_public_key"
  end

  defp strict_config do
    %{accept_unsigned: false, trusted_identities: %{}, eviction_anchors: []}
  end

  defp signing_context(identity_uuid) do
    {public_key, private_key} = Signing.generate_keypair()

    %SigningContext{
      identity_uuid: identity_uuid,
      public_key: public_key,
      private_key: private_key
    }
  end

  defp root_context(public_key, private_key) do
    %SigningContext{
      identity_uuid: "delegation-root",
      public_key: public_key,
      private_key: private_key
    }
  end

  defp issue!(issuer, audience, doc_uuid) do
    assert {:ok, cert} =
             Capability.issue(
               issuer,
               {audience.identity_uuid, audience.public_key},
               %{
                 verbs: [:write],
                 scope: {:docs, [doc_uuid]},
                 caveats: %{not_before: nil, not_after: nil}
               }
             )

    cert
  end

  defp signed_commit(doc_uuid, signer, cert_id) do
    Commit.new(doc_uuid, <<1, 2, 3>>, nil, %{kind: :regular, capability_proof: cert_id})
    |> Signing.sign_commit(
      signer.private_key,
      Signing.signer_id(signer.identity_uuid, signer.public_key)
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore_env(key, value), do: Application.put_env(:commonplace, key, value)
end
