defmodule Commonplace.Gold.ChainTest do
  use ExUnit.Case, async: false

  alias Commonplace.Gold.Chain
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Crypto.Signing

  setup do
    commit_dir = Path.join(System.tmp_dir!(), "cp_gold_commits_#{:rand.uniform(999_999)}")
    secret_dir = Path.join(System.tmp_dir!(), "cp_gold_secrets_#{:rand.uniform(999_999)}")
    File.mkdir_p!(commit_dir)
    File.mkdir_p!(secret_dir)

    store_name = :"gold_store_#{:rand.uniform(999_999)}"
    {:ok, store} = CommitStore.start_link(data_dir: commit_dir, name: store_name)

    # Chain.get_signing_key/0 uses Process.whereis(SecretStore), so we need the default name.
    # The Application may already have started one, so only start if not present.
    secret_store =
      unless Process.whereis(SecretStore) do
        {:ok, ss} = SecretStore.start_link(data_dir: secret_dir, name: SecretStore)
        ss
      end

    {pub, priv} = Signing.generate_keypair()
    SecretStore.set("signing_key:default", Base.encode64(priv))
    SecretStore.set("signing_pub:default", Base.encode64(pub))
    SecretStore.set("signing_identity", "test-gold-identity")

    on_exit(fn ->
      if is_pid(store) and Process.alive?(store), do: GenServer.stop(store)
      if is_pid(secret_store) and Process.alive?(secret_store), do: GenServer.stop(secret_store)
      # Clean up secrets so we don't affect other tests
      SecretStore.delete("signing_key:default")
      SecretStore.delete("signing_pub:default")
      SecretStore.delete("signing_identity")
      File.rm_rf!(commit_dir)
      File.rm_rf!(secret_dir)
    end)

    %{store: store_name, pub: pub}
  end

  test "attest creates attestation for document head", %{store: store} do
    uuid = UUID.uuid4()
    CommitStore.create_commit(store, uuid, "data", nil)

    assert {:ok, att} = Chain.attest(uuid, store)
    assert att.doc_uuid == uuid
    assert att.prev_attestation_id == nil
    assert att.signer_id =~ ~r/test-gold-identity@[0-9a-f]{8}/
  end

  test "attest chains to previous attestation", %{store: store} do
    uuid = UUID.uuid4()
    CommitStore.create_commit(store, uuid, "data1", nil)

    {:ok, att1} = Chain.attest(uuid, store)

    # Add another commit and attest again
    CommitStore.create_chained_commit(store, uuid, "data2")
    {:ok, att2} = Chain.attest(uuid, store)

    assert att2.prev_attestation_id == att1.id
    assert att2.commit_id != att1.commit_id
  end

  test "latest_attestation returns most recent", %{store: store} do
    uuid = UUID.uuid4()
    CommitStore.create_commit(store, uuid, "data", nil)

    {:ok, _att1} = Chain.attest(uuid, store)
    CommitStore.create_chained_commit(store, uuid, "data2")
    {:ok, att2} = Chain.attest(uuid, store)

    {:ok, latest} = Chain.latest_attestation(uuid, store)
    assert latest.id == att2.id
  end

  test "chain returns attestations newest first", %{store: store} do
    uuid = UUID.uuid4()
    CommitStore.create_commit(store, uuid, "d1", nil)
    {:ok, att1} = Chain.attest(uuid, store)

    CommitStore.create_chained_commit(store, uuid, "d2")
    {:ok, att2} = Chain.attest(uuid, store)

    CommitStore.create_chained_commit(store, uuid, "d3")
    {:ok, att3} = Chain.attest(uuid, store)

    chain = Chain.chain(uuid, store)
    assert length(chain) == 3

    # Verify newest-first ordering
    [first, second, third] = chain
    assert first.id == att3.id
    assert second.id == att2.id
    assert third.id == att1.id
  end

  test "verify_chain validates entire chain", %{store: store, pub: pub} do
    uuid = UUID.uuid4()
    CommitStore.create_commit(store, uuid, "data", nil)
    {:ok, _} = Chain.attest(uuid, store)
    CommitStore.create_chained_commit(store, uuid, "data2")
    {:ok, _} = Chain.attest(uuid, store)

    assert :ok = Chain.verify_chain(uuid, pub, store)
  end

  test "verify_chain fails with wrong public key", %{store: store} do
    uuid = UUID.uuid4()
    CommitStore.create_commit(store, uuid, "data", nil)
    {:ok, _} = Chain.attest(uuid, store)

    {wrong_pub, _} = Signing.generate_keypair()
    assert {:error, _, {:error, :invalid_signature}} = Chain.verify_chain(uuid, wrong_pub, store)
  end

  test "attest returns error when no commits", %{store: store} do
    assert {:error, :no_commits} = Chain.attest(UUID.uuid4(), store)
  end

  test "latest_attestation returns :none for unattested doc", %{store: store} do
    assert :none = Chain.latest_attestation(UUID.uuid4(), store)
  end

  test "chain returns empty list for unattested doc", %{store: store} do
    assert [] = Chain.chain(UUID.uuid4(), store)
  end

  test "attestation commit_id matches the actual commit head", %{store: store} do
    uuid = UUID.uuid4()
    commit = CommitStore.create_commit(store, uuid, "payload", nil)

    {:ok, att} = Chain.attest(uuid, store)
    assert att.commit_id == commit.id
  end

  test "multiple attests on same commit produce different attestations", %{store: store} do
    uuid = UUID.uuid4()
    CommitStore.create_commit(store, uuid, "data", nil)

    {:ok, att1} = Chain.attest(uuid, store)
    {:ok, att2} = Chain.attest(uuid, store)

    # Same commit, but second attestation chains to first
    assert att2.prev_attestation_id == att1.id
    assert att2.commit_id == att1.commit_id
    assert att2.id != att1.id
  end
end
