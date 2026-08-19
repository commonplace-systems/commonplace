defmodule Commonplace.Trust.VerifyChainRevocationTest do
  @moduledoc """
  CX-bepn: `VerifyChain`'s per-link revocation check (design §1/§3/§7.6).

  Pins from docs/plans/2026-07-06-capability-revocation-design.md §8:
  the revoker-authority matrix (path-issuer / audience self-renunciation
  / stranger-inert with telemetry), transitivity, the EARLY-ARRIVAL case
  (§7.6 — a revocation stored before its target cert's chain is known
  must still deny once the chain lands), store-threading on a named
  store, and two-store no-leak (§1's no-global-set requirement).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Trust.{Capability, VerifyChain}

  defp start_store(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    name = :"#{prefix}_store_#{n}"

    start_supervised!(
      Supervisor.child_spec(
        {Commonplace.Store.Supervisor,
         data_dir: dir,
         name: :"#{prefix}_sup_#{n}",
         commit_store_name: name,
         trust_side_store_name: :"#{prefix}_tss_#{n}",
         pending_imports_name: :"#{prefix}_pi_#{n}"},
        id: name
      )
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    name
  end

  setup do
    %{store: start_store("vcrev")}
  end

  defp ident(id) do
    {pub, priv} = Signing.generate_keypair()

    %{
      ctx: %SigningContext{identity_uuid: id, private_key: priv, public_key: pub},
      keyed: {id, pub},
      pub: pub,
      priv: priv
    }
  end

  defp claim(verbs, docs),
    do: %{verbs: verbs, scope: {:docs, docs}, caveats: %{not_before: nil, not_after: nil}}

  defp put_cap(store, cap),
    do:
      (
        :ok = CommitStore.store_capability(store, cap)
        cap
      )

  defp put_rev(store, rev),
    do:
      (
        :ok = CommitStore.store_revocation(store, rev)
        rev
      )

  # A 2-link chain: root --delegate--> alice --delegate--> bob (leaf).
  defp two_link_chain(store) do
    root = ident("root")
    alice = ident("alice")
    bob = ident("bob")

    {:ok, parent} = Capability.issue(root.ctx, alice.keyed, claim([:write, :delegate], ["d1"]))
    put_cap(store, parent)

    {:ok, leaf} =
      Capability.issue(alice.ctx, bob.keyed, claim([:write], ["d1"]), parent.id, parent: parent)

    put_cap(store, leaf)

    %{root: root, alice: alice, bob: bob, parent: parent, leaf: leaf}
  end

  test "GRANTS: an un-revoked chain verifies normally", %{store: store} do
    %{root: root, leaf: leaf} = two_link_chain(store)
    assert {:ok, _eff} = VerifyChain.verify_chain(leaf.id, MapSet.new([root.pub]), store)
  end

  test "authority matrix: path-issuer (parent's issuer) can revoke the leaf", %{store: store} do
    %{root: root, alice: alice, leaf: leaf} = two_link_chain(store)

    # alice issued (is the path-issuer of) leaf's parent link — alice is
    # an ancestor delegator on leaf's own proof path.
    {:ok, rev} = Capability.revoke(alice.ctx, leaf.id)
    put_rev(store, rev)

    assert {:error, :revoked} = VerifyChain.verify_chain(leaf.id, MapSet.new([root.pub]), store)
  end

  test "authority matrix: the root issuer (ancestor delegator) can revoke the leaf", %{
    store: store
  } do
    %{root: root, leaf: leaf} = two_link_chain(store)

    {:ok, rev} = Capability.revoke(root.ctx, leaf.id)
    put_rev(store, rev)

    assert {:error, :revoked} = VerifyChain.verify_chain(leaf.id, MapSet.new([root.pub]), store)
  end

  test "authority matrix: the cert's own audience can self-renounce", %{store: store} do
    %{root: root, bob: bob, leaf: leaf} = two_link_chain(store)

    {:ok, rev} = Capability.revoke(bob.ctx, leaf.id)
    put_rev(store, rev)

    assert {:error, :revoked} = VerifyChain.verify_chain(leaf.id, MapSet.new([root.pub]), store)
  end

  test "authority matrix: a stranger's revocation is inert, with a telemetry counter", %{
    store: store
  } do
    %{root: root, leaf: leaf} = two_link_chain(store)
    stranger = ident("stranger")

    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {:revocation_ignored_handler, ref},
      [:commonplace, :trust, :revocation, :ignored],
      fn _event, _meas, meta, _cfg -> send(parent, {:ignored_fired, ref, meta}) end,
      nil
    )

    {:ok, rev} = Capability.revoke(stranger.ctx, leaf.id)
    put_rev(store, rev)

    assert {:ok, _eff} = VerifyChain.verify_chain(leaf.id, MapSet.new([root.pub]), store)
    assert_receive {:ignored_fired, ^ref, meta}, 500
    assert meta.cap_id == leaf.id
    assert meta.revoker_pubkey == stranger.pub

    :telemetry.detach({:revocation_ignored_handler, ref})
  end

  test "forged record is inert: an authorized-pubkey revocation with a bad/missing signature does not revoke",
       %{store: store} do
    # Defense-in-depth pin (Fable review): the verifier re-checks the
    # record's own id+sig, so a record that merely DECLARES an
    # authorized revoker_pubkey — without a valid signature from that
    # key — cannot revoke. All current ingress paths verify before
    # storing; this pin makes the verifier safe even against a future
    # path that forgets.
    %{root: root, leaf: leaf} = two_link_chain(store)

    forged_unsigned = Commonplace.Trust.Revocation.new(leaf.id, root.pub)
    put_rev(store, forged_unsigned)

    bad_sig = %{forged_unsigned | sig: :crypto.strong_rand_bytes(64)}
    put_rev(store, bad_sig)

    assert {:ok, _eff} = VerifyChain.verify_chain(leaf.id, MapSet.new([root.pub]), store)
  end

  test "transitivity: revoking the PARENT denies the leaf chain through it, free-by-construction",
       %{store: store} do
    %{root: root, alice: alice, parent: parent, leaf: leaf} = two_link_chain(store)

    # alice is the parent cert's own audience — self-renunciation of the
    # PARENT link, not the leaf.
    {:ok, rev} = Capability.revoke(alice.ctx, parent.id)
    put_rev(store, rev)

    assert {:error, :revoked} = VerifyChain.verify_chain(leaf.id, MapSet.new([root.pub]), store)
  end

  test "EARLY-ARRIVAL (§7.6): a revocation stored BEFORE its target cert still denies once the chain lands",
       %{store: store} do
    root = ident("root")
    alice = ident("alice")

    # The revocation record is minted and stored FIRST, naming a CID that
    # doesn't exist in this store yet — simulating out-of-order
    # federation arrival. Only internal self-consistency is checkable at
    # that point (Revocation.verify_id/verify_sig) — no authority check
    # happens here, and none should: there is no chain to check against.
    future_cert =
      Capability.new({"root", root.pub}, alice.keyed, claim([:write], ["d1"]))

    {:ok, rev} = Capability.revoke(root.ctx, future_cert.id)
    put_rev(store, rev)

    # ... time passes, the cert itself finally lands (federation
    # catch-up, a delayed peer, etc).
    signed_cert = Capability.sign(future_cert, root.priv)
    put_cap(store, signed_cert)

    # VerifyChain now has the full chain in hand and re-validates
    # authority at THIS verify — root is the cert's own issuer, an
    # authorized revoker. The early-arriving revocation must still deny.
    assert {:error, :revoked} =
             VerifyChain.verify_chain(signed_cert.id, MapSet.new([root.pub]), store)
  end

  test "store-threading: revocation check on a NAMED (non-default) store", %{store: store} do
    %{root: root, alice: alice, leaf: leaf} = two_link_chain(store)
    {:ok, rev} = Capability.revoke(alice.ctx, leaf.id)
    put_rev(store, rev)

    # `store` here is a custom-named trio (never the bare default alias)
    # — this pin exercises exactly the CX-ziye store-threading shape:
    # the revocation get must consult THIS store, not silently fall back
    # to the default `CommitStoreClient` alias.
    assert {:error, :revoked} = VerifyChain.verify_chain(leaf.id, MapSet.new([root.pub]), store)
  end

  test "two-store no-leak: a revocation written in store A denies in A and does NOT leak to store B" do
    store_a = start_store("vcrev_a")
    store_b = start_store("vcrev_b")

    root = ident("root")
    alice = ident("alice")

    {:ok, cert} = Capability.issue(root.ctx, alice.keyed, claim([:write], ["d1"]))
    put_cap(store_a, cert)
    put_cap(store_b, cert)

    {:ok, rev} = Capability.revoke(root.ctx, cert.id)
    put_rev(store_a, rev)

    assert {:error, :revoked} = VerifyChain.verify_chain(cert.id, MapSet.new([root.pub]), store_a)
    assert {:ok, _eff} = VerifyChain.verify_chain(cert.id, MapSet.new([root.pub]), store_b)
  end
end
