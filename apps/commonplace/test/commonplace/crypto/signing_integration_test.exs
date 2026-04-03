defmodule Commonplace.Crypto.SigningIntegrationTest do
  use ExUnit.Case, async: false

  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Crypto.Signing

  setup do
    commit_dir = Path.join(System.tmp_dir!(), "cp_sign_commits_#{:rand.uniform(999999)}")
    secret_dir = Path.join(System.tmp_dir!(), "cp_sign_secrets_#{:rand.uniform(999999)}")
    File.mkdir_p!(commit_dir)
    File.mkdir_p!(secret_dir)

    {:ok, store} = CommitStore.start_link(data_dir: commit_dir, name: :sign_test_store)

    # Start a SecretStore with the default name so CommitStore can find it
    secret_store =
      unless Process.whereis(SecretStore) do
        {:ok, ss} = SecretStore.start_link(data_dir: secret_dir, name: SecretStore)
        ss
      end

    on_exit(fn ->
      if is_pid(store) and Process.alive?(store), do: GenServer.stop(store)
      if is_pid(secret_store) and Process.alive?(secret_store), do: GenServer.stop(secret_store)
      File.rm_rf!(commit_dir)
      File.rm_rf!(secret_dir)
    end)

    %{store: store}
  end

  test "commits are unsigned when no signing key exists", %{store: store} do
    commit = CommitStore.create_commit(store, UUID.uuid4(), "test data", nil)
    assert commit.signature == nil
    assert commit.signer_id == nil
  end

  test "commits are signed when signing key is configured", %{store: store} do
    # Generate and store a keypair
    {pub, priv} = Signing.generate_keypair()
    SecretStore.set("signing_key:default", Base.encode64(priv))
    SecretStore.set("signing_pub:default", Base.encode64(pub))

    commit = CommitStore.create_commit(store, UUID.uuid4(), "test data", nil)
    assert commit.signature != nil
    assert commit.signer_id == "default"

    # Verify the signature
    assert :ok = Signing.verify_commit(commit, pub)

    # Clean up
    SecretStore.delete("signing_key:default")
    SecretStore.delete("signing_pub:default")
  end

  test "chained commits are also signed when key exists", %{store: store} do
    {pub, priv} = Signing.generate_keypair()
    SecretStore.set("signing_key:default", Base.encode64(priv))
    SecretStore.set("signing_pub:default", Base.encode64(pub))

    uuid = UUID.uuid4()
    c1 = CommitStore.create_commit(store, uuid, "first", nil)
    c2 = CommitStore.create_chained_commit(store, uuid, "second")

    assert c1.signature != nil
    assert c2.signature != nil
    assert :ok = Signing.verify_commit(c1, pub)
    assert :ok = Signing.verify_commit(c2, pub)

    # Clean up
    SecretStore.delete("signing_key:default")
    SecretStore.delete("signing_pub:default")
  end
end
