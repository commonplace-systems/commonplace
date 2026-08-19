defmodule Commonplace.MUD.SectionsTest do
  @moduledoc """
  CX-fg1e — DIRECT unit coverage for `Commonplace.MUD.Sections`, filling
  gaps `SectionOwnershipTest` / `SectionAutoExtendTest` leave open:

    * `reject_execute/1` — the unconditional `:execute`-forbidden guard on
      `issue_section/4` AND `delegate_section/4` (the module's headline
      security rider: section ownership is never the seam that grants
      execute authority). Neither existing test file mints with
      `:execute` in `verbs`, so this hard-reject path was never exercised.
    * the CX-cl65 `{:subtree, _}` / `{:presence, _}` skip in
      `auto_extend_for_new_room/3`'s candidate walk — `section_cert?/1`
      must recognize a non-`{:docs, _}` scoped cert BEFORE
      `scope_uuids/1` (which is `{:docs}`-only and would crash on
      anything else) ever sees it. `SectionAutoExtendTest` only ever
      lands `{:docs, _}` section certs as `capability_proof`, so this
      guard has never actually been hit by a candidate walk.
    * `delegate_section/4` called with no `:parent` opt at all ->
      `{:error, :missing_parent_capability}`, fails BEFORE any mint.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.Sections
  alias Commonplace.Store.{CommitStore, CommitStoreClient, SecretStore}
  alias Commonplace.Trust.Capability

  setup do
    n = :rand.uniform(1_000_000_000)

    data_dir = Path.join(System.tmp_dir!(), "cp_sections_data_#{n}")
    File.mkdir_p!(data_dir)

    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, data_dir)

    store_dir = Path.join(System.tmp_dir!(), "cp_sections_store_#{n}")
    File.mkdir_p!(store_dir)
    store_name = :"sections_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: store_dir,
       name: :"sections_sup_#{n}",
       commit_store_name: store_name,
       trust_side_store_name: :"sections_tss_#{n}",
       pending_imports_name: :"sections_pi_#{n}"}
    )

    secrets_dir = Path.join(System.tmp_dir!(), "cp_sections_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets_name = :"sections_secrets_#{n}"
    {:ok, secrets_pid} = SecretStore.start_link(data_dir: secrets_dir, name: secrets_name)

    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)

    on_exit(fn ->
      Application.put_env(:commonplace, :data_dir, prior_data_dir || "tmp/test_data")

      case old_trust do
        nil -> Application.delete_env(:commonplace, :trust)
        v -> Application.put_env(:commonplace, :trust, v)
      end

      case old_knob do
        nil -> Application.delete_env(:commonplace, :local_write_gate)
        v -> Application.put_env(:commonplace, :local_write_gate, v)
      end

      if Process.alive?(secrets_pid),
        do:
          (try do
             GenServer.stop(secrets_pid)
           catch
             (:exit, _ -> :ok)
           end)

      File.rm_rf!(data_dir)
      File.rm_rf!(store_dir)
      File.rm_rf!(secrets_dir)
    end)

    {:ok, node_ctx} = NodeIdentity.signing_context()
    {:ok, node_identity} = NodeIdentity.identity()

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{node_identity => Signing.encode_key(node_ctx.public_key)}
    })

    Application.put_env(:commonplace, :local_write_gate, :enforce)

    context_room = UUID.uuid4()

    CommitStore.create_commit(store_name, context_room, room_update("context room"), nil, %{},
      signing_context: node_ctx
    )

    {owner_pub, owner_priv} = Signing.generate_keypair()
    owner_uuid = UUID.uuid4()

    owner_ctx = %SigningContext{
      identity_uuid: owner_uuid,
      private_key: owner_priv,
      public_key: owner_pub
    }

    %{
      store: store_name,
      node_ctx: node_ctx,
      node_identity: node_identity,
      context_room: context_room,
      owner: %{uuid: owner_uuid, pub: owner_pub, ctx: owner_ctx}
    }
  end

  defp room_update(body) do
    doc = Yelixer.Doc.new() |> ContentType.create(:text, "__room.json")
    doc = ContentType.insert_text(doc, 0, body)
    Yelixer.Encoding.encode_update(doc)
  end

  # Lands a node-signed commit on `context_room` carrying `cid` as its
  # `capability_proof` metadata — this is ALL `candidate_certs/2` needs to
  # discover a candidate (it walks the log for the metadata key and
  # resolves each CID via `get_capability/2`; it never re-checks whether
  # that cert actually AUTHORIZED the commit). Signing as `node_ctx` (a
  # trusted identity) keeps this decoupled from whatever authority the
  # cert itself grants, so a `{:subtree,_}`/`{:presence,_}` cert can be
  # planted as a candidate without needing real subtree-carve plumbing.
  defp land_candidate_commit!(store, context_room, cid, node_ctx, body) do
    CommitStoreClient.create_chained_commit(
      store,
      context_room,
      room_update(body),
      %{kind: :regular, capability_proof: cid},
      signing_context: node_ctx
    )
  end

  # ---- reject_execute/1 — issue_section ----

  test "issue_section: refuses to mint when :execute is in verbs, no cert is minted or stored", %{
    store: store,
    node_ctx: node_ctx,
    context_room: context_room,
    owner: owner
  } do
    assert {:error, :execute_forbidden_in_section_cert} =
             Sections.issue_section(node_ctx, {owner.uuid, owner.pub}, [context_room],
               store: store,
               verbs: [:write, :execute]
             )
  end

  test "issue_section: :execute alone (no :write) is still refused — the guard is unconditional",
       %{
         store: store,
         node_ctx: node_ctx,
         context_room: context_room,
         owner: owner
       } do
    assert {:error, :execute_forbidden_in_section_cert} =
             Sections.issue_section(node_ctx, {owner.uuid, owner.pub}, [context_room],
               store: store,
               verbs: [:execute]
             )
  end

  # ---- reject_execute/1 — delegate_section ----

  test "delegate_section: refuses to mint an :execute-scoped delegation even under a [:write, :delegate] parent",
       %{
         store: store,
         node_ctx: node_ctx,
         context_room: context_room,
         owner: owner
       } do
    assert {:ok, root_cap} =
             Sections.issue_section(node_ctx, {owner.uuid, owner.pub}, [context_room],
               store: store,
               verbs: [:write, :delegate]
             )

    {sub_pub, _sub_priv} = Signing.generate_keypair()
    sub_uuid = UUID.uuid4()

    assert {:error, :execute_forbidden_in_section_cert} =
             Sections.delegate_section(owner.ctx, {sub_uuid, sub_pub}, [context_room],
               store: store,
               parent: root_cap,
               verbs: [:write, :execute]
             )
  end

  # ---- delegate_section without a :parent opt ----

  test "delegate_section: missing :parent opt fails closed before any mint attempt", %{
    store: store,
    owner: owner,
    context_room: context_room
  } do
    {sub_pub, _sub_priv} = Signing.generate_keypair()
    sub_uuid = UUID.uuid4()

    assert {:error, :missing_parent_capability} =
             Sections.delegate_section(owner.ctx, {sub_uuid, sub_pub}, [context_room],
               store: store,
               verbs: [:write]
             )
  end

  # ---- CX-cl65: {:subtree, _} candidate is skipped, never fed to scope_uuids/1 ----

  test "auto_extend_for_new_room: a {:subtree, _} candidate cert is skipped as :not_section_cert, no crash",
       %{
         store: store,
         node_ctx: node_ctx,
         context_room: context_room,
         owner: owner
       } do
    some_root = UUID.uuid4()

    assert {:ok, subtree_cap} =
             Capability.issue(
               node_ctx,
               {owner.uuid, owner.pub},
               %{verbs: [:write], scope: {:subtree, some_root}, caveats: %{}},
               nil,
               store: store
             )

    assert :ok = CommitStoreClient.store_capability(store, subtree_cap)

    assert %Commonplace.Store.Commit{} =
             land_candidate_commit!(
               store,
               context_room,
               subtree_cap.id,
               node_ctx,
               "subtree-proof commit"
             )

    new_room = UUID.uuid4()

    CommitStore.create_commit(store, new_room, room_update("freshly dug"), nil, %{},
      signing_context: node_ctx
    )

    # Must not crash (the CX-cl65 regression: scope_uuids/1 pattern-matches
    # {:docs,_} only and would raise on this shape if fed to it directly).
    assert {:ok, results} =
             Sections.auto_extend_for_new_room(new_room, context_room, store: store)

    assert [{:skipped, cap_id, :not_section_cert}] = results
    assert cap_id == subtree_cap.id
  end

  test "auto_extend_for_new_room: a {:presence, _} candidate cert is likewise skipped as :not_section_cert, no crash",
       %{
         store: store,
         node_ctx: node_ctx,
         context_room: context_room,
         owner: owner
       } do
    assert {:ok, presence_cap} =
             Capability.issue(
               node_ctx,
               {owner.uuid, owner.pub},
               %{verbs: [:write], scope: {:presence, owner.uuid}, caveats: %{}},
               nil,
               store: store
             )

    assert :ok = CommitStoreClient.store_capability(store, presence_cap)

    assert %Commonplace.Store.Commit{} =
             land_candidate_commit!(
               store,
               context_room,
               presence_cap.id,
               node_ctx,
               "presence-proof commit"
             )

    new_room = UUID.uuid4()

    CommitStore.create_commit(store, new_room, room_update("freshly dug"), nil, %{},
      signing_context: node_ctx
    )

    assert {:ok, results} =
             Sections.auto_extend_for_new_room(new_room, context_room, store: store)

    assert [{:skipped, cap_id, :not_section_cert}] = results
    assert cap_id == presence_cap.id
  end

  test "auto_extend_for_new_room: a {:subtree,_} candidate alongside a real {:docs,_} section cert — the docs cert still reissues, the subtree cert is skipped, and neither crashes the other",
       %{
         store: store,
         node_ctx: node_ctx,
         context_room: context_room,
         owner: owner
       } do
    assert {:ok, root_cap} =
             Sections.issue_section(node_ctx, {owner.uuid, owner.pub}, [context_room],
               store: store,
               verbs: [:write]
             )

    assert %Commonplace.Store.Commit{} =
             CommitStoreClient.create_chained_commit(
               store,
               context_room,
               room_update("owner's edit"),
               %{kind: :regular, capability_proof: root_cap.id},
               signing_context: owner.ctx
             )

    some_root = UUID.uuid4()

    assert {:ok, subtree_cap} =
             Capability.issue(
               node_ctx,
               {owner.uuid, owner.pub},
               %{verbs: [:write], scope: {:subtree, some_root}, caveats: %{}},
               nil,
               store: store
             )

    assert :ok = CommitStoreClient.store_capability(store, subtree_cap)

    assert %Commonplace.Store.Commit{} =
             land_candidate_commit!(
               store,
               context_room,
               subtree_cap.id,
               node_ctx,
               "subtree-proof commit"
             )

    new_room = UUID.uuid4()

    CommitStore.create_commit(store, new_room, room_update("freshly dug"), nil, %{},
      signing_context: node_ctx
    )

    assert {:ok, results} =
             Sections.auto_extend_for_new_room(new_room, context_room, store: store)

    assert {:reissued, reissued_id, _new_cap} = Enum.find(results, &match?({:reissued, _, _}, &1))
    assert reissued_id == root_cap.id

    assert {:skipped, skipped_id, :not_section_cert} =
             Enum.find(results, &match?({:skipped, _, :not_section_cert}, &1))

    assert skipped_id == subtree_cap.id
  end

  # ---- build_claim: :ttl_seconds computes a relative not_after ----

  test "issue_section: :ttl_seconds mints a caveat window relative to now (no explicit :not_after given)",
       %{
         store: store,
         node_ctx: node_ctx,
         context_room: context_room,
         owner: owner
       } do
    before_call = DateTime.utc_now()

    assert {:ok, cap} =
             Sections.issue_section(node_ctx, {owner.uuid, owner.pub}, [context_room],
               store: store,
               verbs: [:write],
               ttl_seconds: 3600
             )

    assert cap.claim.caveats.not_after != nil
    # Roughly 3600s out from mint time — generous bounds against test flakiness.
    assert DateTime.diff(cap.claim.caveats.not_after, before_call) in 3595..3605
  end
end
