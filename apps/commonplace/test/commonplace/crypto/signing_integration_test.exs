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

    # signer_id should be "anonymous@<fingerprint>" since no signing_identity is set
    assert String.starts_with?(commit.signer_id, "anonymous@")
    {:ok, "anonymous", fp} = Signing.parse_signer_id(commit.signer_id)
    assert String.length(fp) == 8
    assert fp == Signing.fingerprint(pub)

    # Verify the signature
    assert :ok = Signing.verify_commit(commit, pub)

    # Clean up
    SecretStore.delete("signing_key:default")
    SecretStore.delete("signing_pub:default")
  end

  test "commits use identity UUID in signer_id when signing_identity is set", %{store: store} do
    {pub, priv} = Signing.generate_keypair()
    SecretStore.set("signing_key:default", Base.encode64(priv))
    SecretStore.set("signing_pub:default", Base.encode64(pub))
    SecretStore.set("signing_identity", "my-identity-uuid-1234")

    commit = CommitStore.create_commit(store, UUID.uuid4(), "test data", nil)
    assert commit.signature != nil
    assert String.starts_with?(commit.signer_id, "my-identity-uuid-1234@")
    {:ok, "my-identity-uuid-1234", fp} = Signing.parse_signer_id(commit.signer_id)
    assert fp == Signing.fingerprint(pub)

    # Verify the signature
    assert :ok = Signing.verify_commit(commit, pub)

    # Clean up
    SecretStore.delete("signing_key:default")
    SecretStore.delete("signing_pub:default")
    SecretStore.delete("signing_identity")
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
    assert String.starts_with?(c1.signer_id, "anonymous@")
    assert String.starts_with?(c2.signer_id, "anonymous@")
    assert :ok = Signing.verify_commit(c1, pub)
    assert :ok = Signing.verify_commit(c2, pub)

    # Clean up
    SecretStore.delete("signing_key:default")
    SecretStore.delete("signing_pub:default")
  end

  describe "per-call signing context (CX-hoj)" do
    setup do
      # Always tear down the global signing slots after each test in
      # this describe block — assertions that fail mid-test would
      # otherwise leak signing_key:default / signing_identity into the
      # subsequent tests' SecretStore reads, which corrupts both this
      # file's earlier tests AND any other test that depends on the
      # global SecretStore being clean.
      on_exit(fn ->
        SecretStore.delete("signing_key:default")
        SecretStore.delete("signing_pub:default")
        SecretStore.delete("signing_identity")
      end)

      :ok
    end

    test "explicit signing_context overrides global SecretStore", %{store: store} do
      # Global slot: the human user.
      {human_pub, human_priv} = Signing.generate_keypair()
      SecretStore.set("signing_key:default", Base.encode64(human_priv))
      SecretStore.set("signing_pub:default", Base.encode64(human_pub))
      SecretStore.set("signing_identity", "human-user")

      # Per-call: the agent (different identity).
      {agent_pub, agent_priv} = Signing.generate_keypair()

      agent_ctx = %Commonplace.Crypto.SigningContext{
        identity_uuid: "agent-mcp-1234",
        private_key: agent_priv,
        public_key: agent_pub
      }

      # Agent commit — should be signed with the agent's keypair.
      agent_commit =
        CommitStore.create_commit(store, UUID.uuid4(), "agent data", nil, %{},
          signing_context: agent_ctx
        )

      assert agent_commit.signature != nil
      assert String.starts_with?(agent_commit.signer_id, "agent-mcp-1234@")
      assert :ok = Signing.verify_commit(agent_commit, agent_pub)

      # Concurrent human commit (no per-call context) — should still
      # use the global slot (human_priv), NOT the agent's key.
      human_commit = CommitStore.create_commit(store, UUID.uuid4(), "human data", nil)

      assert human_commit.signature != nil
      assert String.starts_with?(human_commit.signer_id, "human-user@")
      assert :ok = Signing.verify_commit(human_commit, human_pub)

      # Cross-check: agent's commit must NOT verify under human's key,
      # and vice versa.
      assert {:error, _} = Signing.verify_commit(agent_commit, human_pub)
      assert {:error, _} = Signing.verify_commit(human_commit, agent_pub)
    end

    test "signing_context: :unsigned skips signing even when global slot is set",
         %{store: store} do
      {pub, priv} = Signing.generate_keypair()
      SecretStore.set("signing_key:default", Base.encode64(priv))
      SecretStore.set("signing_pub:default", Base.encode64(pub))

      commit =
        CommitStore.create_commit(store, UUID.uuid4(), "unsigned", nil, %{},
          signing_context: :unsigned
        )

      assert commit.signature == nil
      assert commit.signer_id == nil
    end

    test "signing_context flows through create_chained_commit too", %{store: store} do
      {agent_pub, agent_priv} = Signing.generate_keypair()

      ctx = %Commonplace.Crypto.SigningContext{
        identity_uuid: "agent-2",
        private_key: agent_priv,
        public_key: agent_pub
      }

      uuid = UUID.uuid4()
      first = CommitStore.create_commit(store, uuid, "v1", nil, %{}, signing_context: ctx)
      assert String.starts_with?(first.signer_id, "agent-2@")

      second =
        CommitStore.create_chained_commit(store, uuid, "v2", %{}, signing_context: ctx)

      assert String.starts_with?(second.signer_id, "agent-2@")
      assert :ok = Signing.verify_commit(second, agent_pub)
    end
  end
end
