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

  # CX-bepn: revocations ride the same envelope (design §6).
  test "round-trip preserves an inlined revocation byte-faithfully" do
    {commit, cert} = fixture()
    {revoker_pub, revoker_priv} = Signing.generate_keypair()

    {:ok, rev} =
      Capability.revoke(
        %SigningContext{identity_uuid: "revoker", private_key: revoker_priv, public_key: revoker_pub},
        cert.id
      )

    encoded = Envelope.encode(commit, [cert], [rev])
    assert {:ok, %{certs: [decoded_cert], revocations: [decoded_rev]}} = Envelope.decode(encoded)

    assert decoded_cert == cert
    assert decoded_rev == rev
    assert :ok = Commonplace.Trust.Revocation.verify_id(decoded_rev)
    assert :ok = Commonplace.Trust.Revocation.verify_sig(decoded_rev)
  end

  test "an envelope with no \"revocations\" key decodes as [] (back-compat)" do
    {commit, cert} = fixture()
    {:ok, map} = Jason.decode(Envelope.encode(commit, [cert]))
    without_revocations = Jason.encode!(Map.delete(map, "revocations"))

    assert {:ok, %{revocations: []}} = Envelope.decode(without_revocations)
  end

  test "verify_revocations rejects a forged revocation signature" do
    {_commit, cert} = fixture()
    {revoker_pub, revoker_priv} = Signing.generate_keypair()

    {:ok, rev} =
      Capability.revoke(
        %SigningContext{identity_uuid: "revoker", private_key: revoker_priv, public_key: revoker_pub},
        cert.id
      )

    forged = %{rev | sig: :crypto.strong_rand_bytes(64)}
    assert :ok = Envelope.verify_revocations([rev])
    assert {:error, :invalid_revocation} = Envelope.verify_revocations([forged])
  end
end

defmodule Commonplace.Federation.EnvelopeForCommitTest do
  @moduledoc """
  `Envelope.for_commit/2`: the SERVING side builds an envelope that
  inlines the commit's full cert chain (leaf → root, following `proof`
  pointers), so a strict receiver never defers on a cert the sender had.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Federation.Envelope
  alias Commonplace.Store.{Commit, CommitStore}
  alias Commonplace.Trust.Capability

  # R4c carve-out: store_capability/2 delegates to TrustSideStore, so this
  # needs the full trio (a bare CommitStore has no companion by default).
  setup do
    dir = Path.join(System.tmp_dir!(), "cp_env_fc_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000)
    store = :"env_fc_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"env_fc_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"env_fc_tss_#{n}",
       pending_imports_name: :"env_fc_pi_#{n}"}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store}
  end

  defp ident(id) do
    {pub, priv} = Signing.generate_keypair()
    %{ctx: %SigningContext{identity_uuid: id, private_key: priv, public_key: pub},
      keyed: {id, pub}, priv: priv, pub: pub, signer: Signing.signer_id(id, pub)}
  end

  test "inlines the full chain leaf→root for a delegated commit", %{store: store} do
    root = ident("root")
    alice = ident("alice")

    {:ok, c_root} =
      Capability.delegate(root.ctx, alice.keyed, %{
        verbs: [:write, :delegate],
        scope: {:docs, ["d1"]},
        caveats: %{not_before: nil, not_after: nil}
      })

    bob = ident("bob")

    {:ok, c_leaf} =
      Capability.delegate(alice.ctx, bob.keyed, %{
        verbs: [:write],
        scope: {:docs, ["d1"]},
        caveats: %{not_before: nil, not_after: nil}
      }, c_root.id, parent: c_root)

    :ok = CommitStore.store_capability(store, c_root)
    :ok = CommitStore.store_capability(store, c_leaf)

    commit =
      Commit.new("d1", "p", nil, %{kind: :regular, capability_proof: c_leaf.id})
      |> Signing.sign_commit(bob.priv, bob.signer)

    encoded = Envelope.for_commit(store, commit)
    {:ok, %{commit: ^commit, certs: certs}} = Envelope.decode(encoded)

    assert Enum.map(certs, & &1.id) |> Enum.sort() == Enum.sort([c_root.id, c_leaf.id])
  end

  test "a commit with no capability_proof gets an empty cert list", %{store: store} do
    commit = Commit.new("d2", "p", nil, %{kind: :regular})
    assert {:ok, %{certs: []}} = store |> Envelope.for_commit(commit) |> Envelope.decode()
  end

  test "missing certs are skipped, present prefix still inlined", %{store: store} do
    root = ident("root")
    alice = ident("alice")

    {:ok, cert} =
      Capability.delegate(root.ctx, alice.keyed, %{
        verbs: [:write],
        scope: {:docs, ["d3"]},
        caveats: %{not_before: nil, not_after: nil}
      })

    # Cert NOT stored — serving side simply can't inline it.
    commit =
      Commit.new("d3", "p", nil, %{kind: :regular, capability_proof: cert.id})
      |> Signing.sign_commit(alice.priv, alice.signer)

    assert {:ok, %{certs: []}} = store |> Envelope.for_commit(commit) |> Envelope.decode()
  end

  test "inlines a known revocation filed against a cert in the chain (CX-bepn design §6)",
       %{store: store} do
    root = ident("root")
    alice = ident("alice")

    {:ok, cert} =
      Capability.delegate(root.ctx, alice.keyed, %{
        verbs: [:write],
        scope: {:docs, ["d4"]},
        caveats: %{not_before: nil, not_after: nil}
      })

    :ok = CommitStore.store_capability(store, cert)

    {:ok, rev} = Capability.revoke(root.ctx, cert.id)
    :ok = CommitStore.store_revocation(store, rev)

    commit =
      Commit.new("d4", "p", nil, %{kind: :regular, capability_proof: cert.id})
      |> Signing.sign_commit(alice.priv, alice.signer)

    encoded = Envelope.for_commit(store, commit)
    assert {:ok, %{revocations: [decoded_rev]}} = Envelope.decode(encoded)
    assert decoded_rev == rev
  end
end
