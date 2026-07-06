defmodule Commonplace.MUD.SectionAutoExtendTest do
  @moduledoc """
  CX-qat5.5 — new-room cert coverage (auto-extend-on-create). Exercises
  `Commonplace.MUD.Sections.auto_extend_for_new_room/3` directly against
  a strict, named commit-store trio (mirrors
  `Commonplace.MUD.SectionOwnershipTest`'s setup): a node-issued root
  section cert covering a "context room" gets reissued wider to also
  cover a freshly-dug room; a delegation off that root is left alone; a
  cert issued by a DIFFERENT (non-node) trusted root is left alone (red
  event instead); a disconnected room (no context) is a no-op; and a
  reissued cert's caveat window is copied, never extended.

  Candidate-cert discovery walks the context room's own commit log for
  `metadata.capability_proof` CIDs (see the moduledoc on
  `auto_extend_for_new_room/3` for why — there is no scope-based
  capability enumeration in the store), so every scenario below first
  lands a real, authorized commit on the context room using the cert
  under test, exactly as an owner's ordinary section edit would.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.Sections
  alias Commonplace.Store.{CommitStore, CommitStoreClient, SecretStore}

  setup do
    n = :rand.uniform(1_000_000_000)

    data_dir = Path.join(System.tmp_dir!(), "cp_qat5_5_data_#{n}")
    File.mkdir_p!(data_dir)

    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, data_dir)

    store_dir = Path.join(System.tmp_dir!(), "cp_qat5_5_store_#{n}")
    File.mkdir_p!(store_dir)
    store_name = :"qat5_5_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: store_dir,
       name: :"qat5_5_sup_#{n}",
       commit_store_name: store_name,
       trust_side_store_name: :"qat5_5_tss_#{n}",
       pending_imports_name: :"qat5_5_pi_#{n}"}
    )

    secrets_dir = Path.join(System.tmp_dir!(), "cp_qat5_5_secrets_#{n}")
    File.mkdir_p!(secrets_dir)
    secrets_name = :"qat5_5_secrets_#{n}"
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

      if Process.alive?(secrets_pid), do: GenServer.stop(secrets_pid)
      File.rm_rf!(data_dir)
      File.rm_rf!(store_dir)
      File.rm_rf!(secrets_dir)
    end)

    # --- the node's own signing identity (this is the ONLY issuer whose
    # certs may be auto-extended, per decision 1).
    {:ok, node_ctx} = NodeIdentity.signing_context()
    {:ok, node_identity} = NodeIdentity.identity()

    # --- a second, independent trusted root — NOT the node — to prove
    # a non-node-issued cert is skipped (decision 1's negative case).
    {other_root_pub, other_root_priv} = Signing.generate_keypair()

    other_root_ctx = %SigningContext{
      identity_uuid: "other-root",
      private_key: other_root_priv,
      public_key: other_root_pub
    }

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{
        node_identity => Signing.encode_key(node_ctx.public_key),
        "other-root" => Signing.encode_key(other_root_pub)
      }
    })

    Application.put_env(:commonplace, :local_write_gate, :enforce)

    # --- the context room (created by the node) + an owner keypair that
    # section certs will be issued to.
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
      other_root_ctx: other_root_ctx,
      context_room: context_room,
      owner: %{uuid: owner_uuid, pub: owner_pub, ctx: owner_ctx}
    }
  end

  defp room_update(body) do
    doc = Yelixer.Doc.new() |> ContentType.create(:text, "__room.json")
    doc = ContentType.insert_text(doc, 0, body)
    Yelixer.Encoding.encode_update(doc)
  end

  # Lands an authorized owner commit on `context_room` under `cap`, so
  # the cert's CID shows up in the room's commit log for candidate
  # discovery to find.
  defp land_owner_commit(store, context_room, cap, owner_ctx, body) do
    CommitStoreClient.create_chained_commit(
      store,
      context_room,
      room_update(body),
      %{kind: :regular, capability_proof: cap.id},
      signing_context: owner_ctx
    )
  end

  test "(a) node-issued root cert covering the context room is reissued to also cover the new room",
       %{store: store, node_ctx: node_ctx, context_room: context_room, owner: owner} do
    assert {:ok, root_cap} =
             Sections.issue_section(node_ctx, {owner.uuid, owner.pub}, [context_room],
               store: store,
               verbs: [:write]
             )

    assert %Commonplace.Store.Commit{} =
             land_owner_commit(store, context_room, root_cap, owner.ctx, "owner's edit")

    new_room = UUID.uuid4()

    CommitStore.create_commit(store, new_room, room_update("freshly dug"), nil, %{},
      signing_context: node_ctx
    )

    assert {:ok, results} = Sections.auto_extend_for_new_room(new_room, context_room, store: store)
    assert [{:reissued, cap_id, new_cap}] = results
    assert cap_id == root_cap.id
    assert new_cap.claim.scope == {:docs, Enum.sort([context_room, new_room])}
    assert new_cap.claim.verbs == root_cap.claim.verbs
    assert new_cap.proof == nil
    assert {node_identity_uuid, _pub} = new_cap.issuer
    assert {:ok, ^node_identity_uuid} = NodeIdentity.identity()

    # The owner's write to the NEW room now passes authorization using
    # the reissued cert as capability_proof — the actual acceptance bar
    # for this bead (a strict store, not just cert-shape assertions).
    assert owner_commit =
             CommitStoreClient.create_chained_commit(
               store,
               new_room,
               room_update("owner decorates the new room"),
               %{kind: :regular, capability_proof: new_cap.id},
               signing_context: owner.ctx
             )

    assert %Commonplace.Store.Commit{} = owner_commit
    assert {:ok, _} = CommitStore.get_commit(store, owner_commit.id)
  end

  test "(b) an attenuated delegation off a node-issued root is NOT auto-extended",
       %{store: store, node_ctx: node_ctx, context_room: context_room, owner: owner} do
    assert {:ok, root_cap} =
             Sections.issue_section(node_ctx, {owner.uuid, owner.pub}, [context_room],
               store: store,
               verbs: [:write, :delegate]
             )

    assert %Commonplace.Store.Commit{} =
             land_owner_commit(store, context_room, root_cap, owner.ctx, "owner's edit")

    {sub_pub, sub_priv} = Signing.generate_keypair()
    sub_uuid = UUID.uuid4()
    sub_ctx = %SigningContext{identity_uuid: sub_uuid, private_key: sub_priv, public_key: sub_pub}

    assert {:ok, deleg_cap} =
             Sections.delegate_section(owner.ctx, {sub_uuid, sub_pub}, [context_room],
               store: store,
               parent: root_cap,
               verbs: [:write]
             )

    assert %Commonplace.Store.Commit{} =
             CommitStoreClient.create_chained_commit(
               store,
               context_room,
               room_update("sub-delegate's edit"),
               %{kind: :regular, capability_proof: deleg_cap.id},
               signing_context: sub_ctx
             )

    new_room = UUID.uuid4()

    CommitStore.create_commit(store, new_room, room_update("freshly dug"), nil, %{},
      signing_context: node_ctx
    )

    assert {:ok, results} = Sections.auto_extend_for_new_room(new_room, context_room, store: store)

    assert {:reissued, root_cap_id, _new_cap} =
             Enum.find(results, &match?({:reissued, _, _}, &1))

    assert root_cap_id == root_cap.id

    assert {:skipped, deleg_cap_id, :delegation} =
             Enum.find(results, &match?({:skipped, _, :delegation}, &1))

    assert deleg_cap_id == deleg_cap.id
  end

  test "(c) a cert issued by a non-node (but otherwise trusted) root is skipped with a red event, no reissue",
       %{store: store, other_root_ctx: other_root_ctx, context_room: context_room, owner: owner} do
    assert {:ok, other_cap} =
             Sections.issue_section(other_root_ctx, {owner.uuid, owner.pub}, [context_room],
               store: store,
               verbs: [:write]
             )

    assert %Commonplace.Store.Commit{} =
             land_owner_commit(store, context_room, other_cap, owner.ctx, "owner's edit via other root")

    new_room = UUID.uuid4()
    Commonplace.Dataflow.PubSub.subscribe_red(new_room)

    assert {:ok, results} = Sections.auto_extend_for_new_room(new_room, context_room, store: store)
    assert [{:skipped, cap_id, :non_node_issuer}] = results
    assert cap_id == other_cap.id

    assert_receive {"red:" <> ^new_room, {:trust, :section_extend_skipped, meta}}, 500
    assert meta.cap_id == other_cap.id
    assert meta.new_uuid == new_room
    assert meta.reason == :non_node_issuer

    # Nothing was minted covering the new room — a get_capability lookup
    # of the reissue this WOULD have produced (same shape as scenario a)
    # cannot exist because no reissue happened; assert the new room's
    # commit log is untouched by any :capability-carrying commit besides
    # the one we create ourselves below.
    refute Enum.any?(
             CommitStoreClient.commit_log(store, new_room, limit: 100),
             &match?(%{metadata: %{capability_proof: _}}, &1)
           )
  end

  test "(d) a disconnected room (no section context) is never auto-extended", %{store: store} do
    new_room = UUID.uuid4()
    assert {:ok, :no_context} = Sections.auto_extend_for_new_room(new_room, nil, store: store)
  end

  test "(e) the reissued cert's caveat window is copied verbatim, never extended",
       %{store: store, node_ctx: node_ctx, context_room: context_room, owner: owner} do
    not_before = DateTime.add(DateTime.utc_now(), -60, :second)
    not_after = DateTime.add(DateTime.utc_now(), 3600, :second)

    assert {:ok, root_cap} =
             Sections.issue_section(node_ctx, {owner.uuid, owner.pub}, [context_room],
               store: store,
               verbs: [:write],
               not_before: not_before,
               not_after: not_after
             )

    assert %Commonplace.Store.Commit{} =
             land_owner_commit(store, context_room, root_cap, owner.ctx, "owner's edit")

    new_room = UUID.uuid4()

    CommitStore.create_commit(store, new_room, room_update("freshly dug"), nil, %{},
      signing_context: node_ctx
    )

    assert {:ok, [{:reissued, _cap_id, new_cap}]} =
             Sections.auto_extend_for_new_room(new_room, context_room, store: store)

    assert DateTime.compare(new_cap.claim.caveats.not_before, not_before) == :eq
    assert DateTime.compare(new_cap.claim.caveats.not_after, not_after) == :eq
  end
end
