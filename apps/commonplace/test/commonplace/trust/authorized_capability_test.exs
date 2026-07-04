defmodule Commonplace.Trust.AuthorizedCapabilityTest do
  @moduledoc """
  CX-tdkq.22d (phase 3): the `authorized?` phase-3 body. The seam is
  unchanged; the body gains a capability-chain path:

    (a) degenerate fast-path — signer is a locally-pinned trusted
        identity → authorized (the flat allowlist = implicit unattenuated
        root; R1/R2 behavior preserved);
    (b) else, if the commit carries metadata.capability_proof, the cert
        path: ⭐ commit-author binding (the commit must be signed by the
        leaf cert's audience key — else attaching someone else's chain is
        capability theft), verify_chain against the locally-anchored root
        keys, and the effective capability must grant {verb, scope};
    (c) else — the existing unsigned/untrusted logic.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Store.{Commit, CommitStore}
  alias Commonplace.Trust
  alias Commonplace.Trust.Capability

  # R4c carve-out: store_capability/2 delegates to TrustSideStore, so this
  # needs the full trio (a bare CommitStore has no companion by default).
  setup do
    dir = Path.join(System.tmp_dir!(), "authcap_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000)
    name = :"authcap_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"authcap_sup_#{n}",
       commit_store_name: name,
       trust_side_store_name: :"authcap_tss_#{n}",
       pending_imports_name: :"authcap_pi_#{n}"}
    )

    on_exit(fn -> File.rm_rf!(dir) end)

    # root (locally-pinned anchor) delegates to alice.
    {root_pub, root_priv} = Signing.generate_keypair()
    root_ctx = %SigningContext{identity_uuid: "root", private_key: root_priv, public_key: root_pub}
    {alice_pub, alice_priv} = Signing.generate_keypair()
    alice_signer = Signing.signer_id("alice", alice_pub)

    cfg = %{accept_unsigned: false, trusted_identities: %{"root" => Signing.encode_key(root_pub)}}

    %{store: name, root_ctx: root_ctx, root_pub: root_pub,
      alice_pub: alice_pub, alice_priv: alice_priv, alice_signer: alice_signer, cfg: cfg}
  end

  defp claim(verbs, docs, caveats \\ %{not_before: nil, not_after: nil}),
    do: %{verbs: verbs, scope: {:docs, docs}, caveats: caveats}

  # A commit on `doc_uuid` carrying capability_proof, signed by `priv` as `signer`.
  defp signed_commit(doc_uuid, leaf_cid, priv, signer) do
    Commit.new(doc_uuid, "payload", nil, %{kind: :regular, capability_proof: leaf_cid})
    |> Signing.sign_commit(priv, signer)
  end

  test "accepts a commit by a delegated holder for an in-scope verb", c do
    {:ok, leaf} =
      Capability.issue(c.root_ctx, {"alice", c.alice_pub}, claim([:write], ["doc-x"]))
    :ok = CommitStore.store_capability(c.store, leaf)

    commit = signed_commit("doc-x", leaf.id, c.alice_priv, c.alice_signer)
    assert :ok = Trust.authorized?(commit, :write, {:doc, "doc-x"}, c.cfg, c.store)
  end

  test "rejects when the requested doc is outside the cap's scope", c do
    {:ok, leaf} =
      Capability.issue(c.root_ctx, {"alice", c.alice_pub}, claim([:write], ["doc-x"]))
    :ok = CommitStore.store_capability(c.store, leaf)

    commit = signed_commit("doc-y", leaf.id, c.alice_priv, c.alice_signer)
    assert {:error, :capability_insufficient} =
             Trust.authorized?(commit, :write, {:doc, "doc-y"}, c.cfg, c.store)
  end

  test "rejects when the requested verb isn't granted", c do
    {:ok, leaf} =
      Capability.issue(c.root_ctx, {"alice", c.alice_pub}, claim([:write], ["doc-x"]))
    :ok = CommitStore.store_capability(c.store, leaf)

    commit = signed_commit("doc-x", leaf.id, c.alice_priv, c.alice_signer)
    assert {:error, :capability_insufficient} =
             Trust.authorized?(commit, :execute, {:doc, "doc-x"}, c.cfg, c.store)
  end

  test "⭐ rejects capability theft — commit signed by someone OTHER than the leaf audience", c do
    {:ok, leaf} =
      Capability.issue(c.root_ctx, {"alice", c.alice_pub}, claim([:write], ["doc-x"]))
    :ok = CommitStore.store_capability(c.store, leaf)

    # Mallory attaches Alice's valid leaf CID to her OWN commit (signed by Mallory's key).
    {_mpub, mpriv} = Signing.generate_keypair()
    mallory_signer = Signing.signer_id("mallory", elem(Signing.generate_keypair(), 0))
    stolen = signed_commit("doc-x", leaf.id, mpriv, mallory_signer)

    assert {:error, :capability_author_mismatch} =
             Trust.authorized?(stolen, :write, {:doc, "doc-x"}, c.cfg, c.store)
  end

  test "defers with :awaiting_capability when the cert isn't present yet", c do
    commit = signed_commit("doc-x", <<9::256>>, c.alice_priv, c.alice_signer)
    assert {:error, :awaiting_capability} =
             Trust.authorized?(commit, :write, {:doc, "doc-x"}, c.cfg, c.store)
  end

  test "rejects a chain whose root isn't locally anchored", c do
    # A cert chain rooted at a stranger key (not in trusted_identities).
    {s_pub, s_priv} = Signing.generate_keypair()
    stranger = %SigningContext{identity_uuid: "stranger", private_key: s_priv, public_key: s_pub}
    {:ok, leaf} = Capability.issue(stranger, {"alice", c.alice_pub}, claim([:write], ["doc-x"]))
    :ok = CommitStore.store_capability(c.store, leaf)

    commit = signed_commit("doc-x", leaf.id, c.alice_priv, c.alice_signer)
    assert {:error, :untrusted_root} =
             Trust.authorized?(commit, :write, {:doc, "doc-x"}, c.cfg, c.store)
  end

  describe "degenerate fast-path + R1/R2 preservation" do
    test "a pinned-trusted signer is authorized with no cert (unattenuated root)", c do
      commit =
        Commit.new("doc-z", "p", nil)
        |> Signing.sign_commit(c.root_ctx.private_key, Signing.signer_id("root", c.root_pub))

      assert :ok = Trust.authorized?(commit, :write, {:doc, "doc-z"}, c.cfg, c.store)
    end

    test "an unsigned commit in strict mode still rejects (unchanged)", c do
      commit = Commit.new("doc-z", "p", nil)
      assert {:error, :unsigned} = Trust.authorized?(commit, :write, {:doc, "doc-z"}, c.cfg, c.store)
    end

    test "an unknown signer with no cert rejects in strict mode (unchanged)", c do
      commit = signed_commit_no_proof("doc-z", c.alice_priv, c.alice_signer)
      assert {:error, {:untrusted_signer, "alice"}} =
               Trust.authorized?(commit, :write, {:doc, "doc-z"}, c.cfg, c.store)
    end
  end

  defp signed_commit_no_proof(doc_uuid, priv, signer) do
    Commit.new(doc_uuid, "payload", nil) |> Signing.sign_commit(priv, signer)
  end
end
