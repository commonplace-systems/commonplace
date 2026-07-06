defmodule Commonplace.Trust.ExecuteRevocationCacheTest do
  @moduledoc """
  CX-bepn design §4 — "the watermark catch," the load-bearing pin: a
  revocation changes effective authority WITHOUT touching
  `trusted_identities`, so `Trust`'s execute-clean cache MUST
  self-invalidate on a new revocation, or Gate B would keep honoring a
  revoked contributor's cert indefinitely. `cfg_fingerprint` folds in
  `revocation_set_hash(store)` (a per-store watermark row) precisely so
  this works without a global in-memory revocation set (§1).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Trust
  alias Commonplace.Trust.Capability

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_exec_rev_cache_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    name = :"exec_rev_cache_store_#{n}"
    tss = :"exec_rev_cache_tss_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"exec_rev_cache_sup_#{n}",
       commit_store_name: name,
       trust_side_store_name: tss,
       pending_imports_name: :"exec_rev_cache_pi_#{n}"}
    )

    on_exit(fn -> File.rm_rf!(dir) end)

    {root_pub, root_priv} = Signing.generate_keypair()
    root_ctx = %SigningContext{identity_uuid: "root", private_key: root_priv, public_key: root_pub}

    {alice_pub, alice_priv} = Signing.generate_keypair()
    alice_ctx = %SigningContext{identity_uuid: "alice", private_key: alice_priv, public_key: alice_pub}

    cfg = %{accept_unsigned: false, trusted_identities: %{"root" => Signing.encode_key(root_pub)}}

    %{store: name, trust_side_store: tss, root_ctx: root_ctx, alice_pub: alice_pub, alice_ctx: alice_ctx, cfg: cfg}
  end

  # A synchronous call to BOTH mailboxes barriers the fire-and-forget
  # put_execute_clean cast (CommitStore -> TrustSideStore, R4c carve-out)
  # — same pattern as ExecuteBaselineTest.
  defp barrier(store, trust_side_store) do
    :sys.get_state(store)
    :sys.get_state(trust_side_store)
  end

  defp claim(verbs, docs), do: %{verbs: verbs, scope: {:docs, docs}, caveats: %{not_before: nil, not_after: nil}}

  defp code_update(body) do
    Yelixer.Doc.new()
    |> ContentType.create(:text, "code.ex")
    |> ContentType.insert_text(0, body)
    |> Yelixer.Encoding.encode_update()
  end

  defp put_chained(store, uuid, body, proof_cid, ctx) do
    CommitStore.create_chained_commit(store, uuid, code_update(body), %{kind: :regular, capability_proof: proof_cid},
      signing_context: ctx
    )
  end

  test "cached-clean doc -> revoke contributor's cert -> next execute re-walks and denies",
       %{
         store: store,
         trust_side_store: tss,
         root_ctx: root_ctx,
         alice_pub: alice_pub,
         alice_ctx: alice_ctx,
         cfg: cfg
       } do
    uuid = UUID.uuid4()

    {:ok, leaf} = Capability.issue(root_ctx, {"alice", alice_pub}, claim([:write, :execute], [uuid]))
    :ok = CommitStore.store_capability(store, leaf)

    %Commonplace.Store.Commit{} = put_chained(store, uuid, "defmodule Ok do\nend", leaf.id, alice_ctx)
    %Commonplace.Store.Commit{} =
      put_chained(store, uuid, "defmodule Ok do\n  def a, do: 1\nend", leaf.id, alice_ctx)

    # A snapshot signed by the ROOT-pinned identity so it clears the
    # walk's OWN authorized?/5 check unattenuated (verify_against_pinned
    # accepts any verb) — a snapshot needs a cache row to demonstrate
    # the watermark invalidation this test pins.
    {:ok, parent} = CommitStore.latest_commit(store, uuid)

    :ok =
      CommitStore.create_commit(store, uuid, code_update("final"), parent.id, %{kind: :snapshot},
        signing_context: root_ctx
      )
      |> case do
        %Commonplace.Store.Commit{} -> :ok
        other -> other
      end

    assert :ok = Trust.authorized_to_execute?(store, uuid, cfg)
    barrier(store, tss)

    # Sanity: a cached-clean verdict now exists under the CURRENT
    # fingerprint (revocation_set_hash == 0, no revocations yet).
    fp0 =
      :erlang.phash2(
        {cfg.trusted_identities, Commonplace.Store.CommitStoreClient.revocation_set_hash(store)}
      )

    {:ok, snap} = CommitStore.latest_commit(store, uuid)
    assert {:ok, true} = CommitStore.get_execute_clean(store, fp0, snap.id)

    # Revoke alice's leaf cert — the ROOT issuer is an authorized revoker
    # (§2: issuer on the revoked cert's own proof path).
    {:ok, rev} = Capability.revoke(root_ctx, leaf.id)
    :ok = CommitStore.store_revocation(store, rev)

    # The watermark changed, so the fingerprint changed, so the OLD
    # cached-true row (under fp0) is simply never consulted again — the
    # walk under the NEW fingerprint re-validates from scratch and finds
    # the now-revoked contributor.
    assert {:error, {:untrusted_contributor, _, :revoked}} =
             Trust.authorized_to_execute?(store, uuid, cfg)
  end
end
