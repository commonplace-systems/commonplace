defmodule Commonplace.WriterHandTest do
  @moduledoc """
  CX-41qg / CX-qat5.2: hand derivation. `for_doc/1` and `for_doc_actor/2`
  (the 32-bit, nonce-free funnel family) already ship under CX-41qg.1/.3
  — this file adds coverage for `for_session/2`, the 53-bit
  nonce-bearing family W4 introduces for browser sessions.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Crypto.Signing
  alias Commonplace.WriterHand

  describe "for_session/2" do
    test "is deterministic: same (pubkey, nonce) yields the same hand every call" do
      {pub, _priv} = Signing.generate_keypair()
      nonce = :crypto.strong_rand_bytes(16)

      hand1 = WriterHand.for_session(pub, nonce)
      hand2 = WriterHand.for_session(pub, nonce)

      assert hand1 == hand2
    end

    test "two different nonces for the same principal yield different hands" do
      {pub, _priv} = Signing.generate_keypair()
      nonce_a = :crypto.strong_rand_bytes(16)
      nonce_b = :crypto.strong_rand_bytes(16)

      refute WriterHand.for_session(pub, nonce_a) == WriterHand.for_session(pub, nonce_b)
    end

    test "two different principals with the same nonce yield different hands" do
      {pub_a, _} = Signing.generate_keypair()
      {pub_b, _} = Signing.generate_keypair()
      nonce = :crypto.strong_rand_bytes(16)

      refute WriterHand.for_session(pub_a, nonce) == WriterHand.for_session(pub_b, nonce)
    end

    test "stays within the 53-bit JS-safe-integer ceiling (W2 Resolved §1)" do
      for _ <- 1..50 do
        {pub, _priv} = Signing.generate_keypair()
        nonce = :crypto.strong_rand_bytes(16)
        hand = WriterHand.for_session(pub, nonce)

        assert hand >= 0
        assert hand < 0x20_0000_0000_0000
      end
    end

    test "matches the spec's exact derivation (lower 53 bits of SHA-256(pub <> nonce))" do
      pub = :crypto.strong_rand_bytes(32)
      nonce = "fixed-nonce-for-test"

      expected =
        :crypto.hash(:sha256, pub <> nonce)
        |> binary_part(0, 8)
        |> :binary.decode_unsigned()
        |> Bitwise.band(0x1F_FFFF_FFFF_FFFF)

      assert WriterHand.for_session(pub, nonce) == expected
    end
  end
end
