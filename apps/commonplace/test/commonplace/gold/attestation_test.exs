defmodule Commonplace.Gold.AttestationTest do
  use ExUnit.Case, async: true

  alias Commonplace.Gold.Attestation
  alias Commonplace.Crypto.Signing

  setup do
    {pub, priv} = Signing.generate_keypair()
    signer_id = Signing.signer_id("test-identity", pub)
    %{pub: pub, priv: priv, signer_id: signer_id}
  end

  test "new creates a valid attestation", %{priv: priv, signer_id: signer_id} do
    commit_id = :crypto.strong_rand_bytes(32)
    att = Attestation.new("doc-uuid", commit_id, nil, signer_id, priv)

    assert att.doc_uuid == "doc-uuid"
    assert att.commit_id == commit_id
    assert att.prev_attestation_id == nil
    assert att.signer_id == signer_id
    assert att.signature != nil
    assert byte_size(att.signature) == 64
    assert byte_size(att.id) == 32
  end

  test "verify succeeds with correct key", %{pub: pub, priv: priv, signer_id: signer_id} do
    commit_id = :crypto.strong_rand_bytes(32)
    att = Attestation.new("doc-uuid", commit_id, nil, signer_id, priv)
    assert :ok = Attestation.verify(att, pub)
  end

  test "verify fails with wrong key", %{priv: priv, signer_id: signer_id} do
    commit_id = :crypto.strong_rand_bytes(32)
    att = Attestation.new("doc-uuid", commit_id, nil, signer_id, priv)
    {wrong_pub, _} = Signing.generate_keypair()
    assert {:error, :invalid_signature} = Attestation.verify(att, wrong_pub)
  end

  test "verify_id confirms content address", %{priv: priv, signer_id: signer_id} do
    commit_id = :crypto.strong_rand_bytes(32)
    att = Attestation.new("doc-uuid", commit_id, nil, signer_id, priv)
    assert :ok = Attestation.verify_id(att)
  end

  test "verify_id detects tampering", %{priv: priv, signer_id: signer_id} do
    commit_id = :crypto.strong_rand_bytes(32)
    att = Attestation.new("doc-uuid", commit_id, nil, signer_id, priv)
    tampered = %{att | commit_id: :crypto.strong_rand_bytes(32)}
    assert {:error, :id_mismatch} = Attestation.verify_id(tampered)
  end

  test "chained attestations reference previous", %{priv: priv, signer_id: signer_id} do
    c1 = :crypto.strong_rand_bytes(32)
    c2 = :crypto.strong_rand_bytes(32)

    att1 = Attestation.new("doc", c1, nil, signer_id, priv)
    att2 = Attestation.new("doc", c2, att1.id, signer_id, priv)

    assert att2.prev_attestation_id == att1.id
    assert att1.prev_attestation_id == nil
    assert att1.id != att2.id
  end

  test "timestamp is set to current time", %{priv: priv, signer_id: signer_id} do
    before = DateTime.utc_now()
    att = Attestation.new("doc", :crypto.strong_rand_bytes(32), nil, signer_id, priv)
    after_time = DateTime.utc_now()

    assert DateTime.compare(att.timestamp, before) in [:eq, :gt]
    assert DateTime.compare(att.timestamp, after_time) in [:eq, :lt]
  end

  test "different commit_ids produce different attestation ids", %{priv: priv, signer_id: signer_id} do
    c1 = :crypto.strong_rand_bytes(32)
    c2 = :crypto.strong_rand_bytes(32)

    att1 = Attestation.new("doc", c1, nil, signer_id, priv)
    # small delay to ensure different timestamps
    Process.sleep(1)
    att2 = Attestation.new("doc", c2, nil, signer_id, priv)

    assert att1.id != att2.id
  end

  test "same inputs but different prev_attestation_id produce different ids", %{priv: priv, signer_id: signer_id} do
    commit_id = :crypto.strong_rand_bytes(32)
    prev1 = :crypto.strong_rand_bytes(32)
    prev2 = :crypto.strong_rand_bytes(32)

    att1 = Attestation.new("doc", commit_id, prev1, signer_id, priv)
    att2 = Attestation.new("doc", commit_id, prev2, signer_id, priv)

    assert att1.id != att2.id
  end
end
