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
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.Document.ContentType

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

  defp state_value(obj_dir, store, key) do
    {:ok, doc} = DocBuilder.reconstruct_doc(store, obj_meta_uuid(obj_dir, store))
    case Jason.decode(ContentType.get_content(doc)) do
      {:ok, %{"state" => %{^key => v}}} -> v
      _ -> nil
    end
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
end
