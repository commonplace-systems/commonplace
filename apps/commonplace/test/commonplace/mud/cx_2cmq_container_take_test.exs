defmodule Commonplace.MUD.Cx2cmqContainerTakeTest do
  @moduledoc """
  CX-2cmq — containers were "roach motels": a visitor can put an item into a
  container in a foreign zone but never take it back out. This pins the
  intended policy (commonplace-plan #8006): open-by-default SYMMETRIC extraction
  that ELEVATES to node authority ONLY for a node-owned/curated container
  (mirror of CX-5c78's deposit-elevate), while a citizen's own container stays
  on the normal zone-write path (a visitor cannot extract without a grant).

  Enforce harness mirrors DropGiveTest / TakeTest.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Green.{Bursar, BursarClient}
  alias Commonplace.MUD.{Citizenship, Schemas, Take, World}
  alias Commonplace.MUD.Schemas.{Object, Room}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_2cmq_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"cx2cmq_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"cx2cmq_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"cx2cmq_tss_#{n}",
       pending_imports_name: :"cx2cmq_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)
    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      restore = fn key, v ->
        if is_nil(v), do: Application.delete_env(:commonplace, key), else: Application.put_env(:commonplace, key, v)
      end

      restore.(:data_dir, old_data_dir)
      restore.(:trust, old_trust)
      restore.(:local_write_gate, old_knob)
      File.rm_rf!(dir)
    end)

    case GenServer.whereis(Bursar) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, bursar_pid} = Bursar.start_link(root_uuid: UUID.uuid4(), store: store, sweep_interval: 60_000)
    on_exit(fn -> if Process.alive?(bursar_pid), do: (try do GenServer.stop(bursar_pid) catch (:exit, _ -> :ok) end) end)

    {:ok, node_ctx} = NodeIdentity.signing_context()
    {:ok, node_id} = NodeIdentity.identity()

    root = mk_dir!(store, node_ctx)
    players = mk_dir!(store, node_ctx)
    add_dir_entry!(store, root, "players", players, node_ctx)

    %{store: store, node_ctx: node_ctx, node_id: node_id, root: root, players: players}
  end

  test "CURATED container: a visitor can withdraw an item they deposited (symmetric, no roach-motel)", %{
    store: store,
    node_ctx: node_ctx,
    root: root
  } do
    # A curated room reachable from root (NOT under players/), with a
    # node-owned container in it.
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    shelf = mk_container!(store, node_ctx, "shelf")
    add_dir_entry!(store, room, "shelf.obj", shelf, node_ctx)

    # A visitor with a node-owned inventory.
    {visitor_id, _} = fresh_identity()
    visitor_inv = mk_inventory!(store, node_ctx)

    # An item in the room; visitor takes it (token → visitor), then deposits
    # it into the shelf (token → node), then withdraws it.
    item = mk_object!(store, node_ctx, "key")
    add_dir_entry!(store, room, "key.obj", item, node_ctx)

    assert :ok = Take.take(item, "key.obj", room, visitor_inv, visitor_id, store: store, root_uuid: root)

    assert :ok =
             World.deposit_item(item, "key.obj", visitor_inv, shelf, visitor_id,
               store: store, root_uuid: root)

    assert "key.obj" in entry_names(store, shelf), "sanity: item deposited into the shelf"

    # THE WITHDRAWAL — currently the roach-motel denial.
    result = Take.take(item, "key.obj", shelf, visitor_inv, visitor_id, store: store, root_uuid: root)
    assert result == :ok, "visitor could not withdraw from a curated container: #{inspect(result)}"

    assert "key.obj" in entry_names(store, visitor_inv)
    refute "key.obj" in entry_names(store, shelf)
  end

  test "PLAYER-HOME container: a visitor CANNOT withdraw (stays denied — correct, not over-elevated)", %{
    store: store,
    node_ctx: node_ctx,
    root: root,
    players: players
  } do
    # fable's home + a container fable owns, inside players/fable (pruned from
    # the curated-reachable set).
    fable_home = mk_room!(store, node_ctx, "Fable's Loft")
    add_dir_entry!(store, players, "fable", fable_home, node_ctx)
    shelf = mk_container!(store, node_ctx, "shelf")
    add_dir_entry!(store, fable_home, "shelf.obj", shelf, node_ctx)

    {visitor_id, _} = fresh_identity()
    visitor_inv = mk_inventory!(store, node_ctx)

    # An item already sitting in fable's container, node-held.
    item = mk_object!(store, node_ctx, "gem")
    add_dir_entry!(store, shelf, "gem.obj", item, node_ctx)

    result = Take.take(item, "gem.obj", shelf, visitor_inv, visitor_id, store: store, root_uuid: root)
    refute result == :ok, "visitor should NOT extract from a citizen's home container: #{inspect(result)}"
  end

  test "CITIZEN-HOME container: visitor deposit is now DENIED (symmetric-closed) — the roach-motel is dissolved", %{
    store: store,
    node_ctx: node_ctx,
    root: root,
    players: players
  } do
    fable_home = mk_room!(store, node_ctx, "Fable's Loft")
    add_dir_entry!(store, players, "fable", fable_home, node_ctx)
    shelf = mk_container!(store, node_ctx, "shelf")
    add_dir_entry!(store, fable_home, "shelf.obj", shelf, node_ctx)

    # A curated room the visitor can legitimately take from, to obtain an item.
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    {visitor_id, _} = fresh_identity()
    visitor_inv = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, "key")
    add_dir_entry!(store, room, "key.obj", item, node_ctx)
    assert :ok = Take.take(item, "key.obj", room, visitor_inv, visitor_id, store: store, root_uuid: root)

    # Deposit INTO fable's citizen-home container is REFUSED (over-elevation
    # closed) — so no item can be stranded. Symmetric with the withdraw denial
    # in the test above: a container a visitor can't take from, they can't put
    # into either. The item stays in the visitor's own inventory.
    deposit =
      World.deposit_item(item, "key.obj", visitor_inv, shelf, visitor_id, store: store, root_uuid: root)

    refute deposit == :ok, "deposit into a citizen-home container should be refused, got #{inspect(deposit)}"
    refute "key.obj" in entry_names(store, shelf), "nothing should land in the citizen container"
    assert "key.obj" in entry_names(store, visitor_inv), "the item stays with the visitor (not eaten)"
  end

  test "CX-cogd (FIX): a citizen deposits/drops/gives an :available economy item from their OWN home — acquire-on-:available", %{
    store: store,
    node_ctx: node_ctx,
    node_id: node_id,
    root: root
  } do
    # A curated container the citizen does NOT own (forces the elevated path).
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    shelf = mk_container!(store, node_ctx, "shelf")
    add_dir_entry!(store, room, "shelf.obj", shelf, node_ctx)

    # A real citizen: home + {:subtree,home}[:write] cert (the live provisioning).
    {owner_id, owner_ctx} = fresh_identity()
    {:ok, %{cert_cids: cids, home_room_uuid: home}} =
      Citizenship.ensure(owner_id, owner_ctx.public_key, "owner", root, store)

    owner_opts = [store: store, root_uuid: root, signing_context: owner_ctx, cert_cids: cids]

    # Node-minted economy items (sig=NODE) with NO token (tok=:available) sitting
    # in the citizen's own writable home — the exact live shape of fable's ingots.
    ingot = mk_object!(store, node_ctx, "iron ingot")
    add_file_entry!(store, home, "iron ingot.obj", ingot, node_ctx)
    ore = mk_object!(store, node_ctx, "iron ore")
    add_file_entry!(store, home, "iron ore.obj", ore, node_ctx)
    coin = mk_object!(store, node_ctx, "tarnished-coin")
    add_file_entry!(store, home, "tarnished-coin.obj", coin, node_ctx)

    # DEPOSIT into the curated shelf → succeeds, item ends NODE-held (extractable).
    assert :ok = World.deposit_item(ingot, "iron ingot.obj", home, shelf, owner_id, owner_opts)
    assert "iron ingot.obj" in entry_names(store, shelf)
    assert {:held, %{holder: ^node_id}} = BursarClient.query(Bursar, ingot)

    # DROP into the room → succeeds.
    assert :ok = World.drop_item(ore, "iron ore.obj", home, room, owner_id, owner_opts)
    assert "iron ore.obj" in entry_names(store, room)

    # GIVE to a recipient → succeeds, ends RECIPIENT-held.
    {recipient_id, _} = fresh_identity()
    recipient_inv = mk_dir!(store, node_ctx)
    assert :ok = World.give_item(coin, "tarnished-coin.obj", home, recipient_inv, owner_id, recipient_id, owner_opts)
    assert "tarnished-coin.obj" in entry_names(store, recipient_inv)
    assert {:held, %{holder: ^recipient_id}} = BursarClient.query(Bursar, coin)
  end

  test "CX-cogd (ANTI-RAID): an item HELD BY ANOTHER player is still refused :not_holder — never acquired out from under its holder", %{
    store: store,
    node_ctx: node_ctx,
    root: root
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    shelf = mk_container!(store, node_ctx, "shelf")
    add_dir_entry!(store, room, "shelf.obj", shelf, node_ctx)

    {raider_id, _} = fresh_identity()
    inv = mk_inventory!(store, node_ctx)

    # An item whose token is HELD BY SOMEONE ELSE, sitting in the raider's inv
    # (the desynced-ghost shape). Acquiring it would be a raid — must refuse.
    {victim_id, _} = fresh_identity()
    item = mk_object!(store, node_ctx, "stolen gem")
    add_file_entry!(store, inv, "stolen gem.obj", item, node_ctx)
    {:ok, _} = BursarClient.acquire(Bursar, item, victim_id, authenticated_as: victim_id)

    result = World.deposit_item(item, "stolen gem.obj", inv, shelf, raider_id, store: store, root_uuid: root)
    assert result == {:error, :not_holder}, "a token held by another player must NOT be acquirable: #{inspect(result)}"
    assert {:held, %{holder: ^victim_id}} = BursarClient.query(Bursar, item), "victim keeps the token"
  end

  # ---- helpers ----

  defp add_file_entry!(store, parent_uuid, name, child_uuid, ctx) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_file(schema, name, child_uuid)
    {metadata, commit_opts} = Commonplace.MUD.SignedWrite.opts_for(parent_uuid, store: store, signing_context: ctx)

    case Commonplace.Store.CommitStoreClient.create_chained_commit(store, parent_uuid, Encoding.encode_update(schema), metadata, commit_opts) do
      {:error, _} = err -> raise "seed write failed: #{inspect(err)}"
      _ -> :ok
    end
  end

  defp mk_dir!(store, ctx) do
    {:ok, uuid} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: ctx)
    uuid
  end

  defp mk_room!(store, ctx, name \\ "The Yard") do
    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: name, description: "a place"}),
        store,
        signing_context: ctx
      )

    uuid
  end

  defp mk_object!(store, ctx, name) do
    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: name}),
        store,
        signing_context: ctx
      )

    uuid
  end

  defp mk_container!(store, ctx, name) do
    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: name, container?: true}),
        store,
        signing_context: ctx
      )

    uuid
  end

  defp mk_inventory!(store, ctx), do: mk_dir!(store, ctx)

  defp share!(store, root, room_uuid, ctx) do
    add_dir_entry!(store, root, "room-#{String.slice(room_uuid, 0, 8)}", room_uuid, ctx)
    room_uuid
  end

  defp add_dir_entry!(store, parent_uuid, name, child_uuid, ctx) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_directory(schema, name, child_uuid)
    {metadata, commit_opts} = Commonplace.MUD.SignedWrite.opts_for(parent_uuid, store: store, signing_context: ctx)

    case Commonplace.Store.CommitStoreClient.create_chained_commit(store, parent_uuid, Encoding.encode_update(schema), metadata, commit_opts) do
      {:error, _} = err -> raise "seed write failed: #{inspect(err)}"
      _ -> :ok
    end
  end

  defp entry_names(store, dir_uuid) do
    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    schema |> Schema.entries() |> Map.keys()
  end

  defp fresh_identity do
    {pub, priv} = Signing.generate_keypair()
    id = UUID.uuid4()
    {id, %SigningContext{identity_uuid: id, public_key: pub, private_key: priv}}
  end
end
