defmodule Commonplace.Gold.RedLogAttestationTest do
  use ExUnit.Case, async: false

  alias Commonplace.Dataflow.RedLog
  alias Commonplace.Gold.Chain
  alias Commonplace.Store.{CommitStore, SecretStore}
  alias Commonplace.Crypto.Signing

  setup do
    commit_dir = Path.join(System.tmp_dir!(), "cp_redlog_gold_commits_#{:rand.uniform(999_999)}")
    secret_dir = Path.join(System.tmp_dir!(), "cp_redlog_gold_secrets_#{:rand.uniform(999_999)}")
    File.mkdir_p!(commit_dir)
    File.mkdir_p!(secret_dir)

    store_name = :"redlog_gold_store_#{:rand.uniform(999_999)}"
    {:ok, store} = CommitStore.start_link(data_dir: commit_dir, name: store_name)

    secret_store =
      unless Process.whereis(SecretStore) do
        {:ok, ss} = SecretStore.start_link(data_dir: secret_dir, name: SecretStore)
        ss
      end

    {pub, priv} = Signing.generate_keypair()
    SecretStore.set("signing_key:default", Base.encode64(priv))
    SecretStore.set("signing_pub:default", Base.encode64(pub))
    SecretStore.set("signing_identity", "test-redlog-identity")

    on_exit(fn ->
      if is_pid(store) and Process.alive?(store), do: (try do GenServer.stop(store) catch (:exit, _ -> :ok) end)
      if is_pid(secret_store) and Process.alive?(secret_store), do: (try do GenServer.stop(secret_store) catch (:exit, _ -> :ok) end)
      SecretStore.delete("signing_key:default")
      SecretStore.delete("signing_pub:default")
      SecretStore.delete("signing_identity")
      File.rm_rf!(commit_dir)
      File.rm_rf!(secret_dir)
    end)

    %{store: store_name, pub: pub}
  end

  test "commit creates a gold attestation automatically", %{store: store} do
    uuid = UUID.uuid4()
    log = RedLog.new(uuid, store)
    log = RedLog.append_raw(log, %{"action" => "test", "value" => 1})
    RedLog.commit(log)

    {:ok, att} = Chain.latest_attestation(uuid, store)
    assert att.doc_uuid == uuid
    assert att.prev_attestation_id == nil
    assert att.signer_id =~ ~r/test-redlog-identity@[0-9a-f]{8}/
  end

  test "two commits build a linked attestation chain", %{store: store, pub: pub} do
    uuid = UUID.uuid4()

    # First commit
    log = RedLog.new(uuid, store)
    log = RedLog.append_raw(log, %{"action" => "first", "seq" => 1})
    log = RedLog.commit(log)

    {:ok, att1} = Chain.latest_attestation(uuid, store)

    # Second commit
    log = RedLog.append_raw(log, %{"action" => "second", "seq" => 2})
    RedLog.commit(log)

    {:ok, att2} = Chain.latest_attestation(uuid, store)

    # Chain should have 2 entries
    chain = Chain.chain(uuid, store)
    assert length(chain) == 2

    # Second attestation chains to the first
    assert att2.prev_attestation_id == att1.id
    assert att2.commit_id != att1.commit_id

    # Newest first ordering
    [first, second] = chain
    assert first.id == att2.id
    assert second.id == att1.id

    # Full chain verification
    assert :ok = Chain.verify_chain(uuid, pub, store)
  end
end
