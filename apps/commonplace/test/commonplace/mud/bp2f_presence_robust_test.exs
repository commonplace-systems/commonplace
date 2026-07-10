defmodule Commonplace.MUD.Bp2fPresenceRobustTest do
  @moduledoc """
  CX-bp2f / A2 — the presence-robust elevation oracle for the 3 deferred callers
  (move_object / spawn / consume). Before A2 they judged node-ownership on the
  room DIR, which a player entering churns non-node-signed → elevation wrongly
  denied for any OCCUPIED room. A2 redirects the authority to the room's
  presence-untouched `__room.json` META anchor (like put_state/set_attr). Pins:
  (1) an occupied (churned) room now ELEVATES; (2) an absent room-meta
  FAIL-CLOSES (never a vacuous elevate); (3) one-of-N metas missing → :none (the
  all-or-nothing / no-all-but-one invariant).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.MUD.Schemas
  alias Commonplace.MUD.World.Facade
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bp2f_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"bp2f_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"bp2f_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"bp2f_tss_#{n}",
       pending_imports_name: :"bp2f_pi_#{n}"}
    )

    old = %{
      data_dir: Application.get_env(:commonplace, :data_dir),
      trust: Application.get_env(:commonplace, :trust),
      gate: Application.get_env(:commonplace, :local_write_gate)
    }

    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      for {k, v} <- old do
        key = %{data_dir: :data_dir, trust: :trust, gate: :local_write_gate}[k]
        if is_nil(v), do: Application.delete_env(:commonplace, key), else: Application.put_env(:commonplace, key, v)
      end

      File.rm_rf!(dir)
    end)

    {:ok, node_ctx} = NodeIdentity.signing_context()
    %{store: store, node_ctx: node_ctx}
  end

  defp curated_room(name, store, node_ctx) do
    json = Schemas.encode_room(%Schemas.Room{name: name, description: "a room"})
    {:ok, room} = Schemas.create_dir_with_meta(Schemas.room_filename(), json, store, signing_context: node_ctx)
    room
  end

  # a visitor holding no cert, whose current room is `room`
  defp visitor_in(room) do
    {pub, priv} = Signing.generate_keypair()
    id = UUID.uuid4()
    ctx = %SigningContext{identity_uuid: id, public_key: pub, private_key: priv}

    %{
      signing_context: ctx,
      cert_cids: [],
      signer_id: Signing.signer_id(id, pub),
      player_uuid: UUID.uuid4(),
      player_name: "visitor",
      current_room_uuid: room,
      inventory_uuid: UUID.uuid4()
    }
  end

  # churn the room dir non-node-signed (a player entering) — node_owned?(dir) false
  defp enter(room, store) do
    {ppub, ppriv} = Signing.generate_keypair()
    pid = UUID.uuid4()
    pctx = %SigningContext{identity_uuid: pid, public_key: ppub, private_key: ppriv}
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{pid => Signing.encode_key(ppub)}})

    {:ok, schema} = Schemas.load_dir_schema(room, store)
    update = Encoding.encode_update(Schema.add_file(schema, "ghost.usr", UUID.uuid4()))
    r = CommitStoreClient.create_chained_commit(store, room, update, %{kind: :regular}, signing_context: pctx)
    refute match?({:error, _}, r), "presence churn must land"
    :ok
  end

  defp entry_count(room, store) do
    {:ok, sch} = Schemas.load_dir_schema(room, store)
    sch |> Schema.list_entries() |> length()
  end

  test "spawn in an OCCUPIED (churned) room ELEVATES on the room meta (the CX-bp2f fix)", %{store: store, node_ctx: node_ctx} do
    room = curated_room("Hall", store, node_ctx)
    before = entry_count(room, store)
    enter(room, store)

    v = visitor_in(room)
    facade = Facade.new(v, room, [room], nil, store)

    # before A2 this failed: the churned dir → node_owned?(dir) false → no
    # elevation → invoker(visitor)-signed → gate reject. Now it elevates on
    # the presence-untouched room meta.
    assert {:ok, _uuid} = Facade.spawn(facade, "widget")
    # the new object entry landed (+1 over the ghost.usr churn)
    assert entry_count(room, store) > before + 1
  end

  test "spawn in a room with NO meta FAILS CLOSED (absent anchor → :none, never vacuous elevate)", %{store: store, node_ctx: node_ctx} do
    # a bare node dir, no __room.json → room_meta_authority → nil → :none
    {:ok, bare} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: node_ctx)

    v = visitor_in(bare)
    facade = Facade.new(v, bare, [bare], nil, store)

    assert {:error, _} = Facade.spawn(facade, "widget")
  end

  test "move where the DEST room has no meta → :none (one-of-N missing, no all-but-one pass)", %{store: store, node_ctx: node_ctx} do
    src = curated_room("Source", store, node_ctx)
    {:ok, dest_bare} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: node_ctx)

    # node places an object in src (node-signed, no elevation needed)
    node_ctx_map = %{
      signing_context: node_ctx,
      cert_cids: [],
      signer_id: Signing.signer_id(node_ctx.identity_uuid, node_ctx.public_key),
      player_uuid: UUID.uuid4(),
      player_name: "node",
      current_room_uuid: src,
      inventory_uuid: UUID.uuid4()
    }

    {:ok, obj} = Facade.spawn(Facade.new(node_ctx_map, src, [src], nil, store), "totem")

    # a visitor tries to move it src → dest_bare. src.meta is node-owned, but
    # dest_bare.meta is nil → authority [src.meta, nil] → node_owned?(nil)=false
    # → :none → invoker-signed → gate reject. The missing dest meta denies the
    # WHOLE set (not dropped-so-src-passes).
    v = visitor_in(src)
    facade = %{Facade.new(v, obj, [obj, src, dest_bare], nil, store) | host_kind: :object}

    assert {:error, _} = Facade.move_object(facade, dest_bare)
    # the object did not move into dest (a bare dir has no entries)
    assert entry_count(dest_bare, store) == 0
  end
end
