defmodule Commonplace.Trust.ExecuteCapabilityNamedStoreTest do
  @moduledoc """
  CX-ziye: Gate-B's capability path on a NAMED NON-DEFAULT store.

  Before the fix, two store-threading defects made this path CRASH (never
  grant/deny) on any non-default store:

    1. `Trust.walk_contributors/4` called the 4-arity `authorized?/4`,
       dropping the `store` it was given — the capability path always fell
       to the default (`Commonplace.Store.CommitStoreClient`, a module
       alias with no registered process behind it in local mode);
    2. `VerifyChain.build_chain/4` called bare
       `CommitStore.get_capability/2`, bypassing `CommitStoreClient`'s
       alias normalization.

  The default store was unaffected (which is why the rest of the corpus
  stayed green). These pins exercise the END-TO-END Gate-B walk
  (`Trust.authorized_to_execute?/3`) against a Store.Supervisor trio with
  custom names — the exact configuration that used to crash with
  `GenServer.call(Commonplace.Store.CommitStoreClient, :get_db, _)`
  (no such process). Discovery context: the pin-7 DEVIATION block in
  `test/commonplace/store/local_write_gate_test.exs` (now upgraded).

  Setup mirrors AuthorizedCapabilityTest / ExecuteBaselineTest.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Trust
  alias Commonplace.Trust.Capability

  # Full trio with NON-DEFAULT names — the capability path needs the
  # TrustSideStore companion, and the non-default `name` is the point of
  # this regression test.
  setup do
    dir = Path.join(System.tmp_dir!(), "cp_exec_cap_named_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000)
    name = :"exec_cap_named_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"exec_cap_named_sup_#{n}",
       commit_store_name: name,
       trust_side_store_name: :"exec_cap_named_tss_#{n}",
       pending_imports_name: :"exec_cap_named_pi_#{n}"}
    )

    on_exit(fn -> File.rm_rf!(dir) end)

    # root (locally-pinned anchor) delegates to alice.
    {root_pub, root_priv} = Signing.generate_keypair()

    root_ctx = %SigningContext{
      identity_uuid: "root",
      private_key: root_priv,
      public_key: root_pub
    }

    {alice_pub, alice_priv} = Signing.generate_keypair()

    alice_ctx = %SigningContext{
      identity_uuid: "alice",
      private_key: alice_priv,
      public_key: alice_pub
    }

    # cfg passed EXPLICITLY to authorized_to_execute?/3 — no app env, so
    # commit creation stays under the permissive default write gate.
    cfg = %{
      accept_unsigned: false,
      trusted_identities: %{"root" => Signing.encode_key(root_pub)}
    }

    %{store: name, root_ctx: root_ctx, alice_pub: alice_pub, alice_ctx: alice_ctx, cfg: cfg}
  end

  defp claim(verbs, docs),
    do: %{verbs: verbs, scope: {:docs, docs}, caveats: %{not_before: nil, not_after: nil}}

  defp put_signed(store, uuid, body, proof_cid, ctx) do
    doc = Yelixer.Doc.new() |> ContentType.create(:text, "code.ex")
    doc = ContentType.insert_text(doc, 0, body)
    update = Yelixer.Encoding.encode_update(doc)

    CommitStore.create_commit(
      store,
      uuid,
      update,
      nil,
      %{kind: :regular, capability_proof: proof_cid},
      signing_context: ctx
    )
  end

  test "GRANTS: a delegated :execute capability authorizes the Gate-B walk on a named store",
       %{store: store, root_ctx: root_ctx, alice_pub: alice_pub, alice_ctx: alice_ctx, cfg: cfg} do
    uuid = UUID.uuid4()

    {:ok, leaf} =
      Capability.issue(root_ctx, {"alice", alice_pub}, claim([:write, :execute], [uuid]))

    :ok = CommitStore.store_capability(store, leaf)
    put_signed(store, uuid, "defmodule Ok do\nend", leaf.id, alice_ctx)

    assert :ok = Trust.authorized_to_execute?(store, uuid, cfg)
  end

  test "DENIES (no crash): a :write-only capability fails the Gate-B walk on a named store",
       %{store: store, root_ctx: root_ctx, alice_pub: alice_pub, alice_ctx: alice_ctx, cfg: cfg} do
    uuid = UUID.uuid4()

    {:ok, leaf} = Capability.issue(root_ctx, {"alice", alice_pub}, claim([:write], [uuid]))
    :ok = CommitStore.store_capability(store, leaf)
    put_signed(store, uuid, "defmodule Nope do\nend", leaf.id, alice_ctx)

    assert {:error, {:untrusted_contributor, _, :capability_insufficient}} =
             Trust.authorized_to_execute?(store, uuid, cfg)
  end

  test "FAIL-CLOSED (no crash): a missing/unfetchable capability denies on a named store",
       %{store: store, alice_ctx: alice_ctx, cfg: cfg} do
    uuid = UUID.uuid4()

    # capability_proof references a CID that was never stored — the walk
    # must deny with {:error, ...}, never raise.
    put_signed(store, uuid, "defmodule Gone do\nend", <<9::256>>, alice_ctx)

    assert {:error, {:untrusted_contributor, _, :awaiting_capability}} =
             Trust.authorized_to_execute?(store, uuid, cfg)
  end
end
