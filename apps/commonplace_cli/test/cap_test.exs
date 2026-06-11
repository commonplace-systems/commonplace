defmodule Commonplace.CLI.CapTest do
  @moduledoc """
  CX-tdkq.22f: parsing for the `commonplace cap` CLI. The CLI is a thin
  wrapper over the reviewed Capability.issue/delegate API; these tests
  cover the error-prone arg parsing (audience id:pubkey, verb/scope/caveat
  flags), not the crypto (covered by the Capability suite).
  """
  use ExUnit.Case, async: true

  alias Commonplace.CLI.Cap

  test "parse_audience splits identity:base64-pubkey" do
    {pub, _priv} = Commonplace.Crypto.Signing.generate_keypair()
    arg = "alice:" <> Base.encode64(pub)
    assert {:ok, {"alice", ^pub}} = Cap.parse_audience(arg)
  end

  test "parse_audience rejects a malformed audience" do
    assert {:error, _} = Cap.parse_audience("no-colon-here")
    assert {:error, _} = Cap.parse_audience("alice:not!base64!")
  end

  test "parse_claim builds verbs + doc-scope + caveats" do
    assert {:ok, claim} =
             Cap.parse_claim(verbs: "write,delegate", docs: "d1,d2", not_after: nil)

    assert claim.verbs == [:delegate, :write]
    assert claim.scope == {:docs, ["d1", "d2"]}
    assert claim.caveats == %{not_before: nil, not_after: nil}
  end

  test "parse_claim rejects an unknown verb" do
    assert {:error, {:unknown_verb, "frobnicate"}} =
             Cap.parse_claim(verbs: "write,frobnicate", docs: "d1", not_after: nil)
  end

  test "parse_claim parses not_after as ISO8601" do
    {:ok, claim} = Cap.parse_claim(verbs: "write", docs: "d1", not_after: "2030-01-01T00:00:00Z")
    assert %DateTime{} = claim.caveats.not_after
    assert claim.caveats.not_after.year == 2030
  end

  test "parse_claim rejects a bad not_after" do
    assert {:error, {:bad_timestamp, _}} =
             Cap.parse_claim(verbs: "write", docs: "d1", not_after: "not-a-date")
  end
end
