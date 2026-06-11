defmodule Commonplace.Store.CapabilityEnvelopeTest do
  @moduledoc """
  CX-tdkq.22e (phase 3): the capability envelope at Gate A. A commit
  carries `metadata.capability_proof: <leaf CID>` (binds into the content
  address — tamper-evident). When the authorizing cert isn't present yet,
  the import is DEFERRED via the R11 pending queue (`:awaiting_capability`),
  not hard-rejected — and lands once the cert arrives. Crucially, the
  retry re-runs the FULL trust check (cert path included), so a deferred
  commit never bypasses capability verification.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Store.{Commit, CommitStore}
  alias Commonplace.Trust.Capability

  setup do
    dir = Path.join(System.tmp_dir!(), "capenv_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"capenv_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})

    {root_pub, root_priv} = Signing.generate_keypair()
    root_ctx = %SigningContext{identity_uuid: "root", private_key: root_priv, public_key: root_pub}
    {alice_pub, alice_priv} = Signing.generate_keypair()
    alice_signer = Signing.signer_id("alice", alice_pub)

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{"root" => Signing.encode_key(root_pub)}
    })

    {:ok, leaf} =
      Capability.issue(root_ctx, {"alice", alice_pub},
        %{verbs: [:write], scope: {:docs, ["doc-x"]}, caveats: %{not_before: nil, not_after: nil}})

    commit =
      Commit.new("doc-x", "payload", nil, %{kind: :regular, capability_proof: leaf.id})
      |> Signing.sign_commit(alice_priv, alice_signer)

    on_exit(fn -> Application.delete_env(:commonplace, :trust) end)
    %{store: name, leaf: leaf, commit: commit}
  end

  test "a commit whose cert is absent is DEFERRED, not hard-rejected", %{store: store, commit: commit} do
    assert {:error, {:trust_rejected, :awaiting_capability}} =
             CommitStore.import_commit(store, commit, validator: fn _ -> :ok end)

    # Not stored — held pending.
    assert :none = CommitStore.get_commit(store, commit.id)
  end

  test "deferred commit lands once its cert is stored (retry re-runs the cert check)",
       %{store: store, leaf: leaf, commit: commit} do
    assert {:error, {:trust_rejected, :awaiting_capability}} =
             CommitStore.import_commit(store, commit, validator: fn _ -> :ok end)
    assert :none = CommitStore.get_commit(store, commit.id)

    # The cert arrives — which retries the pending queue.
    :ok = CommitStore.store_capability(store, leaf)

    assert {:ok, _} = CommitStore.get_commit(store, commit.id)
  end

  test "a commit with a present, valid cert imports straight away",
       %{store: store, leaf: leaf, commit: commit} do
    :ok = CommitStore.store_capability(store, leaf)
    assert :ok = CommitStore.import_commit(store, commit, validator: fn _ -> :ok end)
    assert {:ok, _} = CommitStore.get_commit(store, commit.id)
  end

  test "capability_proof in metadata binds into the content address (tamper-evident)",
       %{commit: commit} do
    tampered = %{commit | metadata: %{kind: :regular, capability_proof: <<0::256>>}}
    assert {:error, {:id_mismatch, _, _}} = Commit.verify_id(tampered)
  end

  test "a hard-untrusted commit (no cert) is NOT queued — stays rejected", %{store: store} do
    {_pub, priv} = Signing.generate_keypair()
    stranger = Signing.signer_id("stranger", elem(Signing.generate_keypair(), 0))
    commit = Commit.new("doc-x", "p", nil) |> Signing.sign_commit(priv, stranger)

    assert {:error, {:trust_rejected, {:untrusted_signer, "stranger"}}} =
             CommitStore.import_commit(store, commit, validator: fn _ -> :ok end)

    # A later successful import must not resurrect it.
    :ok = CommitStore.store_capability(store, %Commonplace.Trust.Capability{id: <<1::256>>})
    assert :none = CommitStore.get_commit(store, commit.id)
  end
end
