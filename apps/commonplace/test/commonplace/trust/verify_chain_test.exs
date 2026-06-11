defmodule Commonplace.Trust.VerifyChainTest do
  @moduledoc """
  CX-tdkq.22c (phase 3): the capability chain verifier. Walks a cert
  chain leaf→root, returning the EFFECTIVE (intersected) capability, or
  an error. Per link: signature valid, full-pubkey key-link to the
  parent, `:delegate` on every non-leaf, monotonic narrowing, caveat
  window honored; root issuer ∈ locally-anchored keys.

  The two load-bearing bindings: the key-link is FULL 32-byte pubkey
  (the fingerprint is forgeable), and the root anchor is checked against
  the pinned full pubkey, not just "identity present."
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Trust.{Capability, VerifyChain}

  setup do
    dir = Path.join(System.tmp_dir!(), "vchain_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"vchain_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  defp ident(id) do
    {pub, priv} = Signing.generate_keypair()
    {{id, pub}, %SigningContext{identity_uuid: id, private_key: priv, public_key: pub}, pub}
  end

  defp claim(verbs, docs, caveats \\ %{not_before: nil, not_after: nil}) do
    %{verbs: verbs, scope: {:docs, docs}, caveats: caveats}
  end

  defp put(store, cap), do: (:ok = CommitStore.store_capability(store, cap); cap)

  test "1-link root cert: effective capability returned", %{store: store} do
    {root, root_ctx, root_pub} = ident("root")
    {alice, _, _} = ident("alice")
    {:ok, cap} = Capability.issue(root_ctx, alice, claim([:write, :delegate], ["d1", "d2"]))
    put(store, cap)

    assert {:ok, eff} = VerifyChain.verify_chain(cap.id, MapSet.new([root_pub]), store)
    assert MapSet.new(eff.verbs) == MapSet.new([:write, :delegate])
    assert eff.scope == {:docs, ["d1", "d2"]}
    _ = root
  end

  test "2-link delegation: effective = intersection down the chain", %{store: store} do
    {root, root_ctx, root_pub} = ident("root")
    {alice, alice_ctx, _} = ident("alice")
    {bob, _, _} = ident("bob")

    {:ok, parent} = Capability.issue(root_ctx, alice, claim([:write, :delegate], ["d1", "d2"]))
    put(store, parent)
    {:ok, child} =
      Capability.issue(alice_ctx, bob, claim([:write], ["d1"]), parent.id, parent: parent)
    put(store, child)

    assert {:ok, eff} = VerifyChain.verify_chain(child.id, MapSet.new([root_pub]), store)
    assert eff.verbs == [:write]
    assert eff.scope == {:docs, ["d1"]}
    _ = {root, bob}
  end

  test "rejects a missing cert with :awaiting_capability", %{store: store} do
    {root_pub, _} = Signing.generate_keypair()
    assert {:error, :awaiting_capability} =
             VerifyChain.verify_chain(<<7::256>>, MapSet.new([root_pub]), store)
  end

  test "rejects an unknown root (issuer not anchored)", %{store: store} do
    {_root, root_ctx, _} = ident("root")
    {alice, _, _} = ident("alice")
    {:ok, cap} = Capability.issue(root_ctx, alice, claim([:write], ["d1"]))
    put(store, cap)
    {stranger_pub, _} = Signing.generate_keypair()

    assert {:error, :untrusted_root} =
             VerifyChain.verify_chain(cap.id, MapSet.new([stranger_pub]), store)
  end

  test "rejects a broken key-link (child.issuer != parent.audience)", %{store: store} do
    {_root, root_ctx, root_pub} = ident("root")
    {alice, _alice_ctx, _} = ident("alice")
    {bob, _, _} = ident("bob")
    # parent delegates to ALICE, but the child is issued by a DIFFERENT key
    # (an impostor) that claims identity "alice".
    {imp, imp_ctx, _} = ident("alice")
    {:ok, parent} = Capability.issue(root_ctx, alice, claim([:write, :delegate], ["d1"]))
    put(store, parent)
    # Issue child from the impostor key — bypass the mint ⊆ check by not
    # passing :parent; it's the verifier's key-link that must catch this.
    {:ok, child} = Capability.issue(imp_ctx, bob, claim([:write], ["d1"]), parent.id)
    put(store, child)

    assert {:error, :broken_key_link} =
             VerifyChain.verify_chain(child.id, MapSet.new([root_pub]), store)
    _ = imp
  end

  test "rejects a non-leaf cert lacking :delegate", %{store: store} do
    {_root, root_ctx, root_pub} = ident("root")
    {alice, alice_ctx, _} = ident("alice")
    {bob, _, _} = ident("bob")
    # parent grants :write only (NOT :delegate) but alice delegates anyway.
    {:ok, parent} = Capability.issue(root_ctx, alice, claim([:write], ["d1"]))
    put(store, parent)
    {:ok, child} = Capability.issue(alice_ctx, bob, claim([:write], ["d1"]), parent.id)
    put(store, child)

    assert {:error, :delegation_not_permitted} =
             VerifyChain.verify_chain(child.id, MapSet.new([root_pub]), store)
  end

  test "rejects a child that exceeds the parent (narrowing violation)", %{store: store} do
    {_root, root_ctx, root_pub} = ident("root")
    {alice, alice_ctx, _} = ident("alice")
    {bob, _, _} = ident("bob")
    {:ok, parent} = Capability.issue(root_ctx, alice, claim([:write, :delegate], ["d1"]))
    put(store, parent)
    # Child widens scope to d2 — bypass mint check (no :parent), verifier must catch.
    {:ok, child} = Capability.issue(alice_ctx, bob, claim([:write], ["d1", "d2"]), parent.id)
    put(store, child)

    assert {:error, :not_attenuation} =
             VerifyChain.verify_chain(child.id, MapSet.new([root_pub]), store)
  end

  test "rejects an expired cert", %{store: store} do
    {_root, root_ctx, root_pub} = ident("root")
    {alice, _, _} = ident("alice")
    past = DateTime.add(DateTime.utc_now(), -3600, :second)
    {:ok, cap} =
      Capability.issue(root_ctx, alice, claim([:write], ["d1"], %{not_before: nil, not_after: past}))
    put(store, cap)

    assert {:error, :expired} = VerifyChain.verify_chain(cap.id, MapSet.new([root_pub]), store)
  end

  test "rejects a forged signature", %{store: store} do
    {_root, root_ctx, root_pub} = ident("root")
    {alice, _, _} = ident("alice")
    {:ok, cap} = Capability.issue(root_ctx, alice, claim([:write], ["d1"]))
    # Corrupt the sig after issue.
    forged = %{cap | sig: :crypto.strong_rand_bytes(64)}
    put(store, forged)

    assert {:error, :invalid_signature} =
             VerifyChain.verify_chain(forged.id, MapSet.new([root_pub]), store)
  end
end
