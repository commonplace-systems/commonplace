defmodule Commonplace.MUD.InteractableElevationTest do
  @moduledoc """
  CX-gjpi (C)/(2) — the object-owner-authority ELEVATION: under
  strict+enforce, a NON-OWNER visiting player can trigger a curated
  (node-owned) object's own safe-verb effect (spin/pull/press), because
  the guarded write elevates to the OBJECT-OWNER's authority (node, v1)
  INSIDE `write_guarded`, after the reach check. Only-when-needed: the
  owner's own writes stay invoker-signed; a NON-node-owned object stays
  refused (no elevation) until (b) resolves a player-owner.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.MUD.{Schemas, VerbSource}
  alias Commonplace.MUD.World.Facade
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.Document.ContentType
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_elev_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"elev_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"elev_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"elev_tss_#{n}",
       pending_imports_name: :"elev_pi_#{n}"}
    )

    old = %{
      data_dir: Application.get_env(:commonplace, :data_dir),
      trust: Application.get_env(:commonplace, :trust),
      knob: Application.get_env(:commonplace, :local_write_gate)
    }

    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      for {k, v} <- old do
        key = %{data_dir: :data_dir, trust: :trust, knob: :local_write_gate}[k]
        if is_nil(v), do: Application.delete_env(:commonplace, key), else: Application.put_env(:commonplace, key, v)
      end

      File.rm_rf!(dir)
    end)

    {:ok, node_ctx} = NodeIdentity.signing_context()
    {:ok, node_identity} = NodeIdentity.identity()

    %{store: store, node_ctx: node_ctx, node_identity: node_identity}
  end

  # A visitor: a signed identity holding NO cert over anything. Carries the
  # session-ctx keys the facade touches (player_uuid for World.tell, etc.).
  defp visitor_ctx do
    {pub, priv} = Signing.generate_keypair()
    id = UUID.uuid4()
    ctx = %SigningContext{identity_uuid: id, public_key: pub, private_key: priv}

    %{
      signing_context: ctx,
      cert_cids: [],
      signer_id: Signing.signer_id(id, pub),
      player_uuid: UUID.uuid4(),
      player_name: "visitor",
      current_room_uuid: UUID.uuid4(),
      inventory_uuid: UUID.uuid4()
    }
  end

  defp obj_meta_uuid(obj_dir, store) do
    {:ok, sch} = Schemas.load_dir_schema(obj_dir, store)
    {:ok, e} = Schema.get_entry(sch, Schemas.object_filename())
    e.node_id
  end

  defp state_value(obj_dir, store, key), do: state_value(obj_dir, store, Schemas.object_filename(), key)

  defp state_value(dir, store, filename, key) do
    {:ok, sch} = Schemas.load_dir_schema(dir, store)
    {:ok, e} = Schema.get_entry(sch, filename)
    {:ok, doc} = DocBuilder.reconstruct_doc(store, e.node_id)
    case Jason.decode(ContentType.get_content(doc)) do
      {:ok, %{"state" => %{^key => v}}} -> v
      _ -> nil
    end
  end

  # CX-e12a — churn `dir`'s schema with a non-node-signed presence-style entry,
  # so its LATEST commit (and thus `node_owned?/3`) is no longer node-owned —
  # exactly what a player entering/leaving a room does to the room DIR. The
  # `signer_ctx` must be pinned trusted so the churn write itself lands under
  # enforce (mirroring however presence is authorized in production).
  defp presence_churn(dir, entry_name, signer_ctx, store) do
    {:ok, schema} = Schemas.load_dir_schema(dir, store)
    churned = Schema.add_file(schema, entry_name, UUID.uuid4())
    update = Encoding.encode_update(churned)

    result =
      CommitStoreClient.create_chained_commit(store, dir, update, %{kind: :regular},
        signing_context: signer_ctx
      )

    refute match?({:error, _}, result), "presence churn write must land: #{inspect(result)}"
    :ok
  end

  test "non-owner visitor spins a NODE-OWNED object → put_state ELEVATES + lands node-signed", %{
    store: store,
    node_ctx: node_ctx,
    node_identity: node_identity
  } do
    # a curated (NODE-OWNED) object with a put_state safe-verb, all node-signed
    obj_json = Schemas.encode_object(%Schemas.Object{name: "orrery", description: "A brass orrery."})
    {:ok, obj_dir} = Schemas.create_dir_with_meta(Schemas.object_filename(), obj_json, store, signing_context: node_ctx)

    body = "Commonplace.MUD.World.Facade.put_state(world, \"spun\", true)"
    :ok = VerbSource.save_safe_verb(obj_dir, "spin", body, [obj_dir], store, signing_context: node_ctx)

    assert state_value(obj_dir, store, "spun") == nil

    # a NON-owner visitor invokes it. owner_grant = {object} (the default a
    # verb gets on its own host). Under enforce the visitor's own put_state
    # would be {:trust_rejected}, but the object is node-owned → elevate.
    v = visitor_ctx()
    facade = %{Facade.new(v, obj_dir, [obj_dir], nil, store) | host_kind: :object}

    assert {:ok, _} = VerbSource.run_safe_verb(obj_dir, "spin", [obj_dir], facade, %{}, store)

    # the write LANDED (elevation worked) and is NODE-signed (owner authority).
    assert state_value(obj_dir, store, "spun") == true
    {:ok, commit} = CommitStore.latest_commit(store, obj_meta_uuid(obj_dir, store))
    assert {:ok, ^node_identity, _} = Signing.parse_signer_id(commit.signer_id)
  end

  test "non-owner visitor on a PLAYER-OWNED object is NOT elevated (stays refused until (b))", %{
    store: store
  } do
    # A PLAYER-owned object: dir + meta + verb all authored by the player
    # (pinned so their writes land under enforce). node_owned?(dir) = false
    # → no node elevation for a visitor.
    {ppub, ppriv} = Signing.generate_keypair()
    pid = UUID.uuid4()
    player_ctx = %SigningContext{identity_uuid: pid, public_key: ppub, private_key: ppriv}

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{pid => Signing.encode_key(ppub)}
    })

    obj_json = Schemas.encode_object(%Schemas.Object{name: "totem", description: "A player's totem."})
    {:ok, obj_dir} = Schemas.create_dir_with_meta(Schemas.object_filename(), obj_json, store, signing_context: player_ctx)
    body = "Commonplace.MUD.World.Facade.put_state(world, \"spun\", true)"
    :ok = VerbSource.save_safe_verb(obj_dir, "spin", body, [obj_dir], store, signing_context: player_ctx)

    before = state_value(obj_dir, store, "spun")

    # a visitor invokes spin → object is player-owned (dir not node-signed) →
    # no elevation → invoker-signed → refused at the gate → state unchanged.
    v = visitor_ctx()
    facade = %{Facade.new(v, obj_dir, [obj_dir], nil, store) | host_kind: :object}
    VerbSource.run_safe_verb(obj_dir, "spin", [obj_dir], facade, %{}, store)

    assert state_value(obj_dir, store, "spun") == before
  end

  # --- CX-e12a: ROOM-host state writes survive a presence-churned dir ---

  test "ROOM-verb put_state ELEVATES on the __room.json child even when the room DIR is presence-churned (non-node-owned)",
       %{store: store, node_ctx: node_ctx, node_identity: node_identity} do
    # a curated (NODE-OWNED) room: dir + __room.json meta, node-signed.
    room_json = Schemas.encode_room(%Schemas.Room{name: "The Convergence", description: "A round obsidian chamber."})
    {:ok, room_dir} = Schemas.create_dir_with_meta(Schemas.room_filename(), room_json, store, signing_context: node_ctx)

    # an "offer"-style ROOM verb that put_states (the Convergence pattern).
    body = "Commonplace.MUD.World.Facade.put_state(world, \"charge\", 1)"
    :ok = VerbSource.save_safe_verb(room_dir, "offer", body, [room_dir], store, signing_context: node_ctx)

    # A pinned "presence" identity churns the room DIR schema (player enters):
    # the room dir's LATEST commit is now NON-node-signed → node_owned?(dir)
    # is false — the exact live condition that dropped offers.
    {ppub, ppriv} = Signing.generate_keypair()
    pres_id = UUID.uuid4()
    pres_ctx = %SigningContext{identity_uuid: pres_id, public_key: ppub, private_key: ppriv}

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{pres_id => Signing.encode_key(ppub)}
    })

    presence_churn(room_dir, "sable.usr", pres_ctx, store)

    # sanity: the dir is now non-node-owned, but the __room.json child is not.
    {:ok, room_commit} = CommitStore.latest_commit(store, room_dir)
    refute match?({:ok, ^node_identity, _}, Signing.parse_signer_id(room_commit.signer_id))

    assert state_value(room_dir, store, Schemas.room_filename(), "charge") == nil

    # A NON-owner visitor offers. PRE-FIX: elevation was judged on the churned
    # dir → :none → invoker-signed → {:trust_rejected} → state dropped.
    # POST-FIX: authority is judged on the node-owned __room.json child →
    # elevate → node writes → the offer PERSISTS.
    v = visitor_ctx()
    facade = %{Facade.new(v, room_dir, [room_dir], "offer", store) | host_kind: :room}

    assert {:ok, _} = VerbSource.run_safe_verb(room_dir, "offer", [room_dir], facade, %{}, store)

    assert state_value(room_dir, store, Schemas.room_filename(), "charge") == 1

    # and the state write landed NODE-signed (owner authority), not visitor-signed.
    {:ok, sch} = Schemas.load_dir_schema(room_dir, store)
    {:ok, e} = Schema.get_entry(sch, Schemas.room_filename())
    {:ok, state_commit} = CommitStore.latest_commit(store, e.node_id)
    assert {:ok, ^node_identity, _} = Signing.parse_signer_id(state_commit.signer_id)
  end

  test "ROOM-verb put_state on a PLAYER-OWNED room is NOT elevated for a visitor (no escalation past reach)",
       %{store: store} do
    # A player-owned room: dir + __room.json authored by the player → the
    # __room.json child is NOT node-owned, so a visitor gets no elevation even
    # after the target-based fix. Confirms the fix doesn't open an escalation.
    {ppub, ppriv} = Signing.generate_keypair()
    pid = UUID.uuid4()
    player_ctx = %SigningContext{identity_uuid: pid, public_key: ppub, private_key: ppriv}

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{pid => Signing.encode_key(ppub)}
    })

    room_json = Schemas.encode_room(%Schemas.Room{name: "Someone's Home", description: "A private room."})
    {:ok, room_dir} = Schemas.create_dir_with_meta(Schemas.room_filename(), room_json, store, signing_context: player_ctx)
    body = "Commonplace.MUD.World.Facade.put_state(world, \"charge\", 1)"
    :ok = VerbSource.save_safe_verb(room_dir, "offer", body, [room_dir], store, signing_context: player_ctx)

    before = state_value(room_dir, store, Schemas.room_filename(), "charge")

    v = visitor_ctx()
    facade = %{Facade.new(v, room_dir, [room_dir], "offer", store) | host_kind: :room}
    VerbSource.run_safe_verb(room_dir, "offer", [room_dir], facade, %{}, store)

    # player-owned child → no elevation → invoker-signed → refused → unchanged.
    assert state_value(room_dir, store, Schemas.room_filename(), "charge") == before
  end
end
