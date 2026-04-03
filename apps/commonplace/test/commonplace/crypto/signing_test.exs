defmodule Commonplace.Crypto.SigningTest do
  use ExUnit.Case, async: true

  alias Commonplace.Crypto.Signing
  alias Commonplace.Store.Commit

  setup do
    {pub, priv} = Signing.generate_keypair()
    commit = Commit.new("test-uuid", "some update data", nil)
    %{pub: pub, priv: priv, commit: commit}
  end

  test "generate_keypair returns binary keys", %{pub: pub, priv: priv} do
    assert is_binary(pub)
    assert is_binary(priv)
    assert byte_size(pub) == 32
  end

  test "sign_commit adds signature and signer_id", %{commit: commit, priv: priv} do
    signed = Signing.sign_commit(commit, priv, "alice")
    assert signed.signature != nil
    assert signed.signer_id == "alice"
    assert byte_size(signed.signature) == 64
  end

  test "verify_commit succeeds with correct key", %{commit: commit, pub: pub, priv: priv} do
    signed = Signing.sign_commit(commit, priv, "alice")
    assert :ok = Signing.verify_commit(signed, pub)
  end

  test "verify_commit fails with wrong key", %{commit: commit, priv: priv} do
    signed = Signing.sign_commit(commit, priv, "alice")
    {wrong_pub, _} = Signing.generate_keypair()
    assert {:error, :invalid_signature} = Signing.verify_commit(signed, wrong_pub)
  end

  test "verify_commit returns error for unsigned commit", %{commit: commit} do
    assert {:error, :unsigned} = Signing.verify_commit(commit)
  end

  test "signed? returns true for signed commits", %{commit: commit, priv: priv} do
    signed = Signing.sign_commit(commit, priv, "alice")
    assert Signing.signed?(signed) == true
  end

  test "signed? returns false for unsigned commits", %{commit: commit} do
    assert Signing.signed?(commit) == false
  end

  test "encode_key and decode_key roundtrip", %{pub: pub} do
    encoded = Signing.encode_key(pub)
    assert is_binary(encoded)
    assert {:ok, ^pub} = Signing.decode_key(encoded)
  end

  test "decode_key returns error for invalid encoding" do
    assert {:error, :invalid_encoding} = Signing.decode_key("not!valid!base64!!!")
  end

  test "different commits get different signatures", %{priv: priv} do
    c1 = Commit.new("uuid1", "data1", nil)
    c2 = Commit.new("uuid2", "data2", nil)
    s1 = Signing.sign_commit(c1, priv, "alice")
    s2 = Signing.sign_commit(c2, priv, "alice")
    assert s1.signature != s2.signature
  end
end
