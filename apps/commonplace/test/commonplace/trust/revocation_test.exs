defmodule Commonplace.Trust.RevocationTest do
  @moduledoc """
  CX-bepn design §1: the revocation record struct itself — content
  address, sign/verify, and `Capability.revoke/2`'s minting shape.
  Chain-authority semantics (§2/§7.6) are `VerifyChain`'s job and are
  covered in `verify_chain_revocation_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Trust.{Capability, Revocation}

  defp ident(id) do
    {pub, priv} = Signing.generate_keypair()
    %SigningContext{identity_uuid: id, private_key: priv, public_key: pub}
  end

  test "new/2 + sign/2 produce a self-verifying record" do
    revoker = ident("revoker")
    revoked_cid = :crypto.hash(:sha256, "some-cert")

    rev = Revocation.new(revoked_cid, revoker.public_key) |> Revocation.sign(revoker.private_key)

    assert :ok = Revocation.verify_id(rev)
    assert :ok = Revocation.verify_sig(rev)
    assert rev.revoked_cid == revoked_cid
    assert rev.revoker_pubkey == revoker.public_key
  end

  test "id is content-addressed over revoked_cid <> revoker_pubkey (dedupes)" do
    revoker = ident("revoker")
    revoked_cid = :crypto.hash(:sha256, "cert-a")

    rev1 = Revocation.new(revoked_cid, revoker.public_key)
    rev2 = Revocation.new(revoked_cid, revoker.public_key)
    assert rev1.id == rev2.id

    {other_pub, _} = Signing.generate_keypair()
    rev3 = Revocation.new(revoked_cid, other_pub)
    assert rev3.id != rev1.id
  end

  test "verify_id catches a tampered revoked_cid" do
    revoker = ident("revoker")
    rev = Revocation.new(:crypto.hash(:sha256, "cert-a"), revoker.public_key)
    tampered = %{rev | revoked_cid: :crypto.hash(:sha256, "cert-b")}

    assert {:error, {:id_mismatch, _, _}} = Revocation.verify_id(tampered)
  end

  test "verify_sig rejects an unsigned record" do
    revoker = ident("revoker")
    rev = Revocation.new(:crypto.hash(:sha256, "cert-a"), revoker.public_key)
    assert {:error, :unsigned} = Revocation.verify_sig(rev)
  end

  test "verify_sig rejects a forged signature" do
    revoker = ident("revoker")
    rev = Revocation.new(:crypto.hash(:sha256, "cert-a"), revoker.public_key)
    forged = %{rev | sig: :crypto.strong_rand_bytes(64)}
    assert {:error, :invalid_signature} = Revocation.verify_sig(forged)
  end

  test "Capability.revoke/2 mints a self-verifying revocation with no authority check (§7.6)" do
    # A total stranger (no relationship to the cert at all) can still
    # MINT a revocation — minting never checks authority; only
    # VerifyChain does, at verify time.
    stranger = ident("stranger")
    revoked_cid = :crypto.hash(:sha256, "cert-a")

    assert {:ok, rev} = Capability.revoke(stranger, revoked_cid)
    assert :ok = Revocation.verify_id(rev)
    assert :ok = Revocation.verify_sig(rev)
    assert rev.revoker_pubkey == stranger.public_key
    assert rev.revoked_cid == revoked_cid
  end
end
