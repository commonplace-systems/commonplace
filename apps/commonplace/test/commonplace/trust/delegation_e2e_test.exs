defmodule Commonplace.Trust.DelegationE2ETest do
  @moduledoc """
  CX-tdkq.22f (phase 3): the issuance API end-to-end. A root delegates a
  narrowed capability down a chain; the leaf holder exercises it by
  signing a commit that carries the leaf CID; a strict node accepts the
  commit exactly within the granted {verbs, scope} and rejects outside —
  the full attenuation round-trip, including the peer-workspace-trust
  pattern (a root grants a peer-root a subtree's worth of write).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Store.{Commit, CommitStore}
  alias Commonplace.Trust
  alias Commonplace.Trust.Capability

  # R4c carve-out: store_capability/2 delegates to TrustSideStore, so this
  # needs the full trio (a bare CommitStore has no companion by default).
  setup do
    dir = Path.join(System.tmp_dir!(), "deleg_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000)
    name = :"deleg_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"deleg_sup_#{n}",
       commit_store_name: name,
       trust_side_store_name: :"deleg_tss_#{n}",
       pending_imports_name: :"deleg_pi_#{n}"}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  defp ident(id) do
    {pub, priv} = Signing.generate_keypair()

    %{
      id: id,
      pub: pub,
      priv: priv,
      ctx: %SigningContext{identity_uuid: id, private_key: priv, public_key: pub},
      keyed: {id, pub},
      signer: Signing.signer_id(id, pub)
    }
  end

  defp strict(root_pub) do
    %{accept_unsigned: false, trusted_identities: %{"root" => Signing.encode_key(root_pub)}}
  end

  defp commit_with(doc, leaf_cid, holder) do
    Commit.new(doc, "payload", nil, %{kind: :regular, capability_proof: leaf_cid})
    |> Signing.sign_commit(holder.priv, holder.signer)
  end

  test "root → alice → bob: bob exercises the twice-narrowed cap within scope", %{store: store} do
    root = ident("root")
    alice = ident("alice")
    bob = ident("bob")
    cfg = strict(root.pub)

    # root delegates {write, delegate} over {d1, d2} to alice.
    {:ok, c1} =
      Capability.delegate(root.ctx, alice.keyed, %{
        verbs: [:write, :delegate],
        scope: {:docs, ["d1", "d2"]},
        caveats: %{not_before: nil, not_after: nil}
      })

    :ok = CommitStore.store_capability(store, c1)

    # alice narrows to {write} over {d1} and delegates to bob.
    {:ok, c2} =
      Capability.delegate(
        alice.ctx,
        bob.keyed,
        %{verbs: [:write], scope: {:docs, ["d1"]}, caveats: %{not_before: nil, not_after: nil}},
        c1.id,
        parent: c1
      )

    :ok = CommitStore.store_capability(store, c2)

    # bob writes d1 (in scope) → accepted.
    ok_commit = commit_with("d1", c2.id, bob)
    assert :ok = Trust.authorized?(ok_commit, :write, {:doc, "d1"}, cfg, store)

    # bob tries d2 (alice already narrowed it away) → rejected.
    oos_commit = commit_with("d2", c2.id, bob)

    assert {:error, :capability_insufficient} =
             Trust.authorized?(oos_commit, :write, {:doc, "d2"}, cfg, store)

    # bob tries to :execute (never granted) → rejected.
    assert {:error, :capability_insufficient} =
             Trust.authorized?(ok_commit, :execute, {:doc, "d1"}, cfg, store)
  end

  test "delegate refuses to mint a child that widens the parent", %{store: _store} do
    root = ident("root")
    alice = ident("alice")
    {bpub, _} = Signing.generate_keypair()

    {:ok, parent} =
      Capability.delegate(root.ctx, alice.keyed, %{
        verbs: [:write],
        scope: {:docs, ["d1"]},
        caveats: %{not_before: nil, not_after: nil}
      })

    # alice can't grant bob :execute she doesn't hold.
    assert {:error, {:not_attenuation, _}} =
             Capability.delegate(
               alice.ctx,
               {"bob", bpub},
               %{
                 verbs: [:write, :execute],
                 scope: {:docs, ["d1"]},
                 caveats: %{not_before: nil, not_after: nil}
               },
               parent.id,
               parent: parent
             )
  end

  test "peer-workspace trust: root grants peer-root a doc-set, peer writes within it", %{
    store: store
  } do
    root = ident("root")
    peer = ident("peer-root")
    cfg = strict(root.pub)

    # jes-root delegates {write} over the federated doc-set to peer-X-root.
    {:ok, grant} =
      Capability.delegate(root.ctx, peer.keyed, %{
        verbs: [:write],
        scope: {:docs, ["fed-1", "fed-2"]},
        caveats: %{not_before: nil, not_after: nil}
      })

    :ok = CommitStore.store_capability(store, grant)

    in_scope = commit_with("fed-1", grant.id, peer)
    assert :ok = Trust.authorized?(in_scope, :write, {:doc, "fed-1"}, cfg, store)

    out_scope = commit_with("other-doc", grant.id, peer)

    assert {:error, :capability_insufficient} =
             Trust.authorized?(out_scope, :write, {:doc, "other-doc"}, cfg, store)
  end
end
