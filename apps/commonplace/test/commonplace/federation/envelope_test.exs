defmodule Commonplace.Federation.EnvelopeTest do
  @moduledoc """
  Phase C, federate-for-real (CX-orfw): the federation wire format.

  An envelope carries one commit plus the capability certs a strict
  receiver needs to verify it (inlined for availability — the receiver
  stores certs BEFORE importing the commit, so `VerifyChain` finds the
  chain locally). The codec must be FAITHFUL: `Commit.verify_id/1` and
  `Capability.verify_id/1` must pass on the decoded values, which is
  exactly what a JSON-mangled metadata map would break (D12 — payloads
  travel as base64(term_to_binary), decoded with [:safe]).
  """
  use ExUnit.Case, async: true

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Federation.Envelope
  alias Commonplace.Store.Commit
  alias Commonplace.Trust.Capability

  defp fixture do
    {root_pub, root_priv} = Signing.generate_keypair()
    {agent_pub, _agent_priv} = Signing.generate_keypair()

    root_ctx = %SigningContext{
      identity_uuid: "root-id",
      private_key: root_priv,
      public_key: root_pub
    }

    {:ok, cert} =
      Capability.delegate(root_ctx, {"agent-id", agent_pub}, %{
        verbs: [:write],
        scope: {:docs, ["doc-1"]},
        caveats: %{not_before: nil, not_after: nil}
      })

    commit =
      Commit.new("doc-1", <<1, 2, 3>>, nil, %{kind: :regular, capability_proof: cert.id})
      |> Signing.sign_commit(root_priv, Signing.signer_id("root-id", root_pub))

    {commit, cert}
  end

  test "round-trip preserves the commit and certs byte-faithfully" do
    {commit, cert} = fixture()

    encoded = Envelope.encode(commit, [cert])
    assert is_binary(encoded)

    assert {:ok, %{commit: decoded_commit, certs: [decoded_cert]}} = Envelope.decode(encoded)

    assert decoded_commit == commit
    assert decoded_cert == cert

    # The fidelity claims that matter to the gate:
    assert :ok = Commit.verify_id(decoded_commit)
    assert Capability.verify_id(decoded_cert)
    assert decoded_commit.signature == commit.signature
  end

  test "round-trip with no certs" do
    {commit, _} = fixture()
    assert {:ok, %{commit: decoded, certs: []}} = commit |> Envelope.encode([]) |> Envelope.decode()
    assert decoded == commit
  end

  test "tampered payload bytes are rejected, not crashed on" do
    {commit, cert} = fixture()
    encoded = Envelope.encode(commit, [cert])

    {:ok, map} = Jason.decode(encoded)
    tampered = Jason.encode!(%{map | "commit" => "AAAA" <> String.slice(map["commit"], 4..-1//1)})

    assert {:error, _} = Envelope.decode(tampered)
  end

  test "a payload that is valid term_to_binary but not a Commit is rejected" do
    bogus =
      Jason.encode!(%{
        "v" => 1,
        "commit" => Base.encode64(:erlang.term_to_binary({:not, :a, :commit})),
        "certs" => []
      })

    assert {:error, :bad_payload} = Envelope.decode(bogus)
  end

  test "non-JSON and unknown-version envelopes are rejected" do
    assert {:error, _} = Envelope.decode("not json at all")

    {commit, _} = fixture()
    {:ok, map} = commit |> Envelope.encode([]) |> Jason.decode()
    assert {:error, :unsupported_version} = Envelope.decode(Jason.encode!(%{map | "v" => 99}))
  end
end
