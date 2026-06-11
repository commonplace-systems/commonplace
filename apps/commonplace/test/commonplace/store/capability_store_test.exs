defmodule Commonplace.Store.CapabilityStoreTest do
  @moduledoc """
  CX-tdkq.22b (phase 3): content-addressed cert storage in CubDB,
  mirroring the attestation store. A cert is an immutable CID-pinned
  value — `{:capability, cid} → cert` — never a CRDT doc (certs never
  merge; the CID entry enforces value-not-state for free).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Trust.Capability

  setup do
    dir = Path.join(System.tmp_dir!(), "cap_store_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"cap_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)

    {pub, priv} = Signing.generate_keypair()
    {apub, _} = Signing.generate_keypair()
    ctx = %SigningContext{identity_uuid: "root", private_key: priv, public_key: pub}
    {:ok, cap} =
      Capability.issue(ctx, {"alice", apub},
        %{verbs: [:write], scope: {:docs, ["d1"]}, caveats: %{not_before: nil, not_after: nil}})

    %{store: name, cap: cap}
  end

  test "store + get a cert by CID round-trips", %{store: store, cap: cap} do
    assert :ok = CommitStore.store_capability(store, cap)
    assert {:ok, fetched} = CommitStore.get_capability(store, cap.id)
    assert fetched.id == cap.id
    assert fetched.sig == cap.sig
    assert :ok = Capability.verify_id(fetched)
    assert :ok = Capability.verify_sig(fetched)
  end

  test "get of an absent CID returns :none", %{store: store} do
    assert :none = CommitStore.get_capability(store, <<0::256>>)
  end

  test "storing is idempotent for the same CID", %{store: store, cap: cap} do
    assert :ok = CommitStore.store_capability(store, cap)
    assert :ok = CommitStore.store_capability(store, cap)
    assert {:ok, _} = CommitStore.get_capability(store, cap.id)
  end
end
