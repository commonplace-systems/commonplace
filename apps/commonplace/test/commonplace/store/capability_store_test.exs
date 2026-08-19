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

  # R4c carve-out: store_capability/2 and get_capability/2 now delegate to
  # this instance's Commonplace.Store.TrustSideStore companion, so the test
  # needs the full trio running (a bare CommitStore has no companion by
  # default — see CommitStore.init/1 — and store_capability would raise).
  # Distinct per-test names keep this isolated from every other trio in the
  # suite, notably the real production singleton the app boots at test start.
  setup do
    dir = Path.join(System.tmp_dir!(), "cap_store_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000)
    name = :"cap_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"cap_store_sup_#{n}",
       commit_store_name: name,
       trust_side_store_name: :"cap_store_tss_#{n}",
       pending_imports_name: :"cap_store_pi_#{n}"}
    )

    on_exit(fn -> File.rm_rf!(dir) end)

    {pub, priv} = Signing.generate_keypair()
    {apub, _} = Signing.generate_keypair()
    ctx = %SigningContext{identity_uuid: "root", private_key: priv, public_key: pub}

    {:ok, cap} =
      Capability.issue(ctx, {"alice", apub}, %{
        verbs: [:write],
        scope: {:docs, ["d1"]},
        caveats: %{not_before: nil, not_after: nil}
      })

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
