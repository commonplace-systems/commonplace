defmodule Commonplace.MUD.TakeTest do
  @moduledoc """
  CX-ix9n — TAKE under enforce: the push-not-pull elevated node
  transfer (`Commonplace.MUD.Take`). Covers the unblock, the
  fixed-scenery guard (via `Verbs.dispatch`), the single-winner token
  race, the identity-bound-holder forge check, rollback on move
  failure, and the no-elevation-without-node-ownership guard.

  Setup mirrors `VerbsSafeDispatchTest`'s `Commonplace.Store.Supervisor`
  + `Commonplace.Green.Bursar` bring-up (needed for both the green-token
  possession layer and the `Move`-backed tree relocation).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Green.{Bursar, BursarClient}
  alias Commonplace.MUD.{Parser, SignedWrite, Schemas, Take, Verbs, World}
  alias Commonplace.MUD.Schemas.{Object, Room}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_take_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"take_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"take_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"take_tss_#{n}",
       pending_imports_name: :"take_pi_#{n}"}
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
    on_exit(fn -> if Process.alive?(bursar_pid), do: GenServer.stop(bursar_pid) end)

    {:ok, node_ctx} = NodeIdentity.signing_context()
    {:ok, node_identity} = NodeIdentity.identity()

    # CX-1mz7 zone-gate: a real world root with a `players/` dir, so the
    # source room can be POSITIVELY classified (shared-curated vs own home).
    # Rooms linked under `root` (not under `players/`) are shared-curated.
    root = mk_dir!(store, node_ctx)
    players = mk_dir!(store, node_ctx)
    add_dir_entry!(store, root, "players", players, node_ctx)

    %{
      store: store,
      node_ctx: node_ctx,
      node_identity: node_identity,
      root: root,
      players: players
    }
  end

  # ---- seed helpers ----

  # A bare dir (no meta) — used for the world root, the players dir, and
  # inventories.
  defp mk_dir!(store, signing_ctx) do
    {:ok, uuid} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: signing_ctx)
    uuid
  end

  # Link `room_uuid` as a SHARED-CURATED room: a direct dir child of the
  # world `root` (i.e. reachable from root NOT via `players/`).
  defp share!(store, root, room_uuid, signing_ctx) do
    add_dir_entry!(store, root, "room-#{String.slice(room_uuid, 0, 8)}", room_uuid, signing_ctx)
    room_uuid
  end

  # Provision `players/<name>/` as an OWNED HOME ROOM (a dir carrying a room
  # meta) with an `inventory/` subdir, mirroring Citizenship.ensure's shape.
  # Returns %{home: home_room_uuid, inventory: inventory_uuid}. The home dir
  # IS the player's home room; its `inventory` entry is what the zone-gate
  # matches to identify the taker structurally.
  defp mk_home!(store, players_uuid, name, signing_ctx) do
    home = mk_room!(store, signing_ctx, "#{name}'s Home")
    inv = mk_dir!(store, signing_ctx)
    add_dir_entry!(store, home, "inventory", inv, signing_ctx)
    add_dir_entry!(store, players_uuid, name, home, signing_ctx)
    %{home: home, inventory: inv}
  end

  defp mk_room!(store, signing_ctx, name \\ "The Yard") do
    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: name, description: "a plain place"}),
        store,
        signing_context: signing_ctx
      )

    uuid
  end

  defp mk_inventory!(store, signing_ctx) do
    {:ok, uuid} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: signing_ctx)
    uuid
  end

  defp mk_object!(store, signing_ctx, opts) do
    name = Keyword.get(opts, :name, "widget")
    fixed = Keyword.get(opts, :fixed, false)

    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: name, fixed: fixed}),
        store,
        signing_context: signing_ctx
      )

    uuid
  end

  # CX-cj3t.1.1 container-take: mirrors mk_object! but sets container?: true
  # (the same flag containers_test.exs / output_test.exs build against).
  defp mk_container!(store, signing_ctx, opts) do
    name = Keyword.get(opts, :name, "box")

    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: name, container?: true}),
        store,
        signing_context: signing_ctx
      )

    uuid
  end

  defp add_dir_entry!(store, parent_uuid, name, child_uuid, signing_ctx) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_directory(schema, name, child_uuid)
    update = Encoding.encode_update(schema)
    {metadata, commit_opts} = SignedWrite.opts_for(parent_uuid, store: store, signing_context: signing_ctx)

    case CommitStoreClient.create_chained_commit(store, parent_uuid, update, metadata, commit_opts) do
      {:error, _} = err -> raise "seed write failed: #{inspect(err)}"
      _commit -> :ok
    end
  end

  defp add_file_entry!(store, parent_uuid, name, child_uuid, signing_ctx) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_file(schema, name, child_uuid)
    update = Encoding.encode_update(schema)
    {metadata, commit_opts} = SignedWrite.opts_for(parent_uuid, store: store, signing_context: signing_ctx)

    case CommitStoreClient.create_chained_commit(store, parent_uuid, update, metadata, commit_opts) do
      {:error, _} = err -> raise "seed write failed: #{inspect(err)}"
      _commit -> :ok
    end
  end

  defp entry_names(store, dir_uuid) do
    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    schema |> Schema.entries() |> Map.keys()
  end

  defp fresh_identity do
    {pub, priv} = Signing.generate_keypair()
    id = UUID.uuid4()
    ctx = %SigningContext{identity_uuid: id, public_key: pub, private_key: priv}
    {id, ctx}
  end

  # ---- 1. THE UNBLOCK ----

  test "under enforce, a taker with no authority over the dirs takes a node-owned item", %{
    store: store,
    node_ctx: node_ctx,
    root: root
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    inventory = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "widget.obj")
    add_dir_entry!(store, room, "widget.obj", item, node_ctx)

    {taker_id, _taker_ctx} = fresh_identity()

    assert :ok = Take.take(item, "widget.obj", room, inventory, taker_id, store: store, root_uuid: root)

    refute "widget.obj" in entry_names(store, room)
    assert "widget.obj" in entry_names(store, inventory)

    assert {:held, %{holder: ^taker_id}} = BursarClient.query(Bursar, item)
  end

  # ---- 2. Fixed scenery ----

  test "fixed object refuses take, no token transfer, item stays", %{store: store, node_ctx: node_ctx} do
    room = mk_room!(store, node_ctx)
    inventory = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "statue", fixed: true)
    add_dir_entry!(store, room, "statue.obj", item, node_ctx)

    {taker_id, taker_sc} = fresh_identity()

    ctx = %{
      player_name: "taker",
      current_room_uuid: room,
      inventory_uuid: inventory,
      store: store,
      signing_context: taker_sc,
      cert_cids: [],
      signer_id: Signing.signer_id(taker_id, taker_sc.public_key)
    }

    cmd = %Parser.Command{verb: "take", args: "statue", argv: ["statue"]}
    assert {:error, msg} = Verbs.dispatch(cmd, ctx)
    assert msg =~ "fixed in place"

    assert "statue.obj" in entry_names(store, room)
    refute "statue.obj" in entry_names(store, inventory)
    assert :available = BursarClient.query(Bursar, item)
  end

  # ---- 3. Double-take single-winner ----

  test "two concurrent takes of the same item: exactly one wins, the other is refused", %{
    store: store,
    node_ctx: node_ctx,
    root: root
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    inv_a = mk_inventory!(store, node_ctx)
    inv_b = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "gem")
    add_dir_entry!(store, room, "gem", item, node_ctx)

    {id_a, _} = fresh_identity()
    {id_b, _} = fresh_identity()

    task_a = Task.async(fn -> Take.take(item, "gem", room, inv_a, id_a, store: store, root_uuid: root) end)
    task_b = Task.async(fn -> Take.take(item, "gem", room, inv_b, id_b, store: store, root_uuid: root) end)

    result_a = Task.await(task_a)
    result_b = Task.await(task_b)

    results = [result_a, result_b]
    losing_reasons = [{:error, :taken}, {:error, :item_unavailable}, {:error, :gone}]

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 in losing_reasons)) == 1

    winner_id = if result_a == :ok, do: id_a, else: id_b
    winner_inv = if result_a == :ok, do: inv_a, else: inv_b
    loser_inv = if result_a == :ok, do: inv_b, else: inv_a

    refute "gem" in entry_names(store, room)
    assert "gem" in entry_names(store, winner_inv)
    refute "gem" in entry_names(store, loser_inv)

    assert {:held, %{holder: ^winner_id}} = BursarClient.query(Bursar, item)
  end

  # ---- 4. Identity-bound holder is not forgeable ----

  test "after A takes, B cannot forge a transfer claiming to be the holder", %{
    store: store,
    node_ctx: node_ctx,
    root: root
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    inv_a = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "ring")
    add_dir_entry!(store, room, "ring", item, node_ctx)

    {id_a, _} = fresh_identity()
    {id_b, _} = fresh_identity()

    assert :ok = Take.take(item, "ring", room, inv_a, id_a, store: store, root_uuid: root)

    # B claims to be the holder (impersonating A as authenticated_as B —
    # the from_holder param doesn't match the authenticated caller).
    assert {:error, :holder_mismatch} =
             BursarClient.transfer(Bursar, item, id_a, id_b, authenticated_as: id_b)

    assert {:held, %{holder: ^id_a}} = BursarClient.query(Bursar, item)
  end

  # ---- 5. Rollback on move failure ----

  test "move failure after token transfer rolls the token back to the node", %{
    store: store,
    node_ctx: node_ctx,
    node_identity: node_identity,
    root: root
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    inventory = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "coin")
    add_dir_entry!(store, room, "coin", item, node_ctx)

    # collide: an entry named "coin" already lives in the dest inventory.
    other_item = mk_object!(store, node_ctx, name: "coin")
    add_file_entry!(store, inventory, "coin", other_item, node_ctx)

    {taker_id, _} = fresh_identity()

    assert {:error, :collision} = Take.take(item, "coin", room, inventory, taker_id, store: store, root_uuid: root)

    # item entry unchanged in the room.
    assert "coin" in entry_names(store, room)

    # the token rolled back to the node.
    assert {:held, %{holder: ^node_identity}} = BursarClient.query(Bursar, item)
  end

  # ---- 6. Non-node-owned dir -> no elevation ----

  test "a non-node-owned room refuses take with no elevation, no token movement", %{store: store} do
    {other_id, other_ctx} = fresh_identity()

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{other_id => Signing.encode_key(other_ctx.public_key)}
    })

    room = mk_room!(store, other_ctx)
    node_ctx = elem(NodeIdentity.signing_context(), 1)
    inventory = mk_inventory!(store, node_ctx)
    item = mk_object!(store, other_ctx, name: "trinket")
    add_dir_entry!(store, room, "trinket", item, other_ctx)

    {taker_id, _} = fresh_identity()

    assert {:error, :not_takeable_here} = Take.take(item, "trinket", room, inventory, taker_id, store: store)

    assert "trinket" in entry_names(store, room)
    assert :available = BursarClient.query(Bursar, item)
  end

  # ---- 7. CX-cj3t.1.1: do_get_from routed through the reviewed take
  # primitive — the crown-from-vault beat ----

  test "container-take under enforce: get item from an unlocked node-owned container", %{
    store: store,
    node_ctx: node_ctx,
    root: root
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    inventory = mk_inventory!(store, node_ctx)
    container = mk_container!(store, node_ctx, name: "wooden box")
    add_dir_entry!(store, room, "wooden box", container, node_ctx)
    item = mk_object!(store, node_ctx, name: "crown")
    add_dir_entry!(store, container, "crown.obj", item, node_ctx)

    {taker_id, taker_sc} = fresh_identity()

    ctx = %{
      player_name: "taker",
      current_room_uuid: room,
      inventory_uuid: inventory,
      root_uuid: root,
      store: store,
      signing_context: taker_sc,
      cert_cids: [],
      signer_id: Signing.signer_id(taker_id, taker_sc.public_key)
    }

    cmd = %Parser.Command{verb: "get", args: "crown from wooden box", argv: ["crown", "from", "wooden", "box"]}
    assert {:reply, msg} = Verbs.dispatch(cmd, ctx)
    assert msg =~ "You get crown from wooden box."

    refute "crown.obj" in entry_names(store, container)
    assert "crown.obj" in entry_names(store, inventory)

    assert {:held, %{holder: ^taker_id}} = BursarClient.query(Bursar, item)
  end

  test "container-take under enforce: locked container without the key still refuses", %{
    store: store,
    node_ctx: node_ctx
  } do
    room = mk_room!(store, node_ctx)
    inventory = mk_inventory!(store, node_ctx)
    container = mk_container!(store, node_ctx, name: "wooden box")
    add_dir_entry!(store, room, "wooden box", container, node_ctx)
    item = mk_object!(store, node_ctx, name: "crown")
    add_dir_entry!(store, container, "crown.obj", item, node_ctx)

    :ok =
      World.set_meta(container, Schemas.object_filename(), "state", %{"locked" => true}, store,
        signing_context: node_ctx
      )

    {taker_id, taker_sc} = fresh_identity()

    ctx = %{
      player_name: "taker",
      current_room_uuid: room,
      inventory_uuid: inventory,
      store: store,
      signing_context: taker_sc,
      cert_cids: [],
      signer_id: Signing.signer_id(taker_id, taker_sc.public_key)
    }

    cmd = %Parser.Command{verb: "get", args: "crown from wooden box", argv: ["crown", "from", "wooden", "box"]}
    assert {:error, msg} = Verbs.dispatch(cmd, ctx)
    assert msg =~ "is locked"

    assert "crown.obj" in entry_names(store, container)
    refute "crown.obj" in entry_names(store, inventory)
    assert :available = BursarClient.query(Bursar, item)
  end

  test "fixed-guard chokepoint: Take.take refuses a fixed item directly, bypassing the verb layer", %{
    store: store,
    node_ctx: node_ctx
  } do
    room = mk_room!(store, node_ctx)
    inventory = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "statue2", fixed: true)
    add_dir_entry!(store, room, "statue2.obj", item, node_ctx)

    {taker_id, _} = fresh_identity()

    assert {:error, :fixed} = Take.take(item, "statue2.obj", room, inventory, taker_id, store: store)

    assert "statue2.obj" in entry_names(store, room)
    refute "statue2.obj" in entry_names(store, inventory)
    assert :available = BursarClient.query(Bursar, item)
  end

  # ---- 8. CX-ix9n LIVE-FIX regression: elevation keys on the ITEM's
  # node-ownership, NOT the source room schema's. A room schema is re-chained
  # by player PRESENCE writes (a `.usr` add signed by the entering player), so
  # its latest-commit signer flips to that player when occupied — which
  # (pre-fix) wrongly refused every take in a populated room. Items and
  # inventories are never presence-re-chained, so they are the reliable oracle.
  test "take elevates even when the room schema was re-chained by a non-node presence write", %{
    store: store,
    node_ctx: node_ctx,
    root: root
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    inventory = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "vault key.obj")
    add_dir_entry!(store, room, "vault key.obj", item, node_ctx)

    # A player walks in: their presence `.usr` add re-chains the ROOM schema
    # signed by THEM (not the node). Pin that identity so the write lands under
    # enforce, exactly as a presence-carve-authorized write does live.
    {pres_id, pres_sc} = fresh_identity()

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{pres_id => Signing.encode_key(pres_sc.public_key)}
    })

    add_file_entry!(store, room, "#{pres_id}.usr", UUID.uuid4(), pres_sc)

    # The room schema's latest commit is now the PLAYER's, not the node — the
    # exact condition that (pre-fix) flipped node_owned?(room) to false.
    {:ok, room_commit} = CommitStoreClient.latest_commit(store, room)
    assert {:ok, ^pres_id, _} = Signing.parse_signer_id(room_commit.signer_id)

    {taker_id, _} = fresh_identity()

    # Pre-fix this refused (:not_takeable_here); the item-keyed gate elevates.
    assert :ok = Take.take(item, "vault key.obj", room, inventory, taker_id, store: store, root_uuid: root)
    refute "vault key.obj" in entry_names(store, room)
    assert "vault key.obj" in entry_names(store, inventory)
    assert {:held, %{holder: ^taker_id}} = BursarClient.query(Bursar, item)
  end

  # CX-ix9n LIVE-FIX regression, CONTAINER variant: the same item-keyed gate
  # must make container-take (`get X from Y`) work when the SOURCE container's
  # schema is not node-owned (re-chained by a non-node write — a prior put/get,
  # or occupancy of its room). The item-keyed elevation ignores the source
  # container's chain state entirely, so a node-owned item in a re-chained
  # container is still takeable.
  test "container-take elevates even when the container schema was re-chained by a non-node write", %{
    store: store,
    node_ctx: node_ctx,
    root: root
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    inventory = mk_inventory!(store, node_ctx)
    container = mk_container!(store, node_ctx, name: "wooden box")
    add_dir_entry!(store, room, "wooden box", container, node_ctx)
    item = mk_object!(store, node_ctx, name: "crown")
    add_dir_entry!(store, container, "crown.obj", item, node_ctx)

    # Re-chain the CONTAINER schema with a non-node signer (as a put/get would).
    {other_id, other_sc} = fresh_identity()

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{other_id => Signing.encode_key(other_sc.public_key)}
    })

    add_file_entry!(store, container, "marker", UUID.uuid4(), other_sc)
    {:ok, cc} = CommitStoreClient.latest_commit(store, container)
    assert {:ok, ^other_id, _} = Signing.parse_signer_id(cc.signer_id)

    {taker_id, taker_sc} = fresh_identity()

    ctx = %{
      player_name: "taker",
      current_room_uuid: room,
      inventory_uuid: inventory,
      root_uuid: root,
      store: store,
      signing_context: taker_sc,
      cert_cids: [],
      signer_id: Signing.signer_id(taker_id, taker_sc.public_key)
    }

    cmd = %Parser.Command{verb: "get", args: "crown from wooden box", argv: ["crown", "from", "wooden", "box"]}
    assert {:reply, msg} = Verbs.dispatch(cmd, ctx)
    assert msg =~ "You get crown from wooden box."
    refute "crown.obj" in entry_names(store, container)
    assert "crown.obj" in entry_names(store, inventory)
    assert {:held, %{holder: ^taker_id}} = BursarClient.query(Bursar, item)
  end

  # ---- 9. CX-1mz7 TAKE-zone-gate: the anti-home-raid allowlist ----
  #
  # The DROP/GIVE hard prereq. Once DROP lands, a player can place a
  # node-owned item into a home; without this gate a visitor could then
  # take it. The gate is a fail-closed POSITIVE allowlist: takeable IFF the
  # source room is shared-curated OR the taker's own home; anything else
  # (another's home, an unreachable/unrecognized room, no world root) is
  # refused BEFORE any elevation or token movement.

  test "zone-gate: a visitor CANNOT take a node-owned item from ANOTHER player's home", %{
    store: store,
    node_ctx: node_ctx,
    root: root,
    players: players
  } do
    # Alice's home holds a node-owned item (as if she dropped it there).
    alice = mk_home!(store, players, "alice", node_ctx)
    item = mk_object!(store, node_ctx, name: "sword")
    add_dir_entry!(store, alice.home, "sword", item, node_ctx)

    # Bob (a distinct player, with his own home) stands in Alice's home and
    # tries to take. node-ownership of item + Bob's inventory both pass — the
    # ZONE-gate is what refuses (Alice's home is neither shared nor Bob's).
    bob = mk_home!(store, players, "bob", node_ctx)
    {bob_id, _} = fresh_identity()

    assert {:error, :not_takeable_here} =
             Take.take(item, "sword", alice.home, bob.inventory, bob_id, store: store, root_uuid: root)

    assert "sword" in entry_names(store, alice.home)
    assert :available = BursarClient.query(Bursar, item)
  end

  test "zone-gate: a player CAN take a node-owned item from their OWN home", %{
    store: store,
    node_ctx: node_ctx,
    root: root,
    players: players
  } do
    alice = mk_home!(store, players, "alice", node_ctx)
    item = mk_object!(store, node_ctx, name: "trinket")
    add_dir_entry!(store, alice.home, "trinket", item, node_ctx)
    {alice_id, _} = fresh_identity()

    assert :ok =
             Take.take(item, "trinket", alice.home, alice.inventory, alice_id, store: store, root_uuid: root)

    refute "trinket" in entry_names(store, alice.home)
    assert "trinket" in entry_names(store, alice.inventory)
    assert {:held, %{holder: ^alice_id}} = BursarClient.query(Bursar, item)
  end

  test "zone-gate: fail-closed — a take with NO world root is refused even from a shared room", %{
    store: store,
    node_ctx: node_ctx,
    root: root
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    inventory = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "orb")
    add_dir_entry!(store, room, "orb", item, node_ctx)
    {taker_id, _} = fresh_identity()

    # No :root_uuid opt -> the location cannot be POSITIVELY classified -> refuse.
    assert {:error, :not_takeable_here} = Take.take(item, "orb", room, inventory, taker_id, store: store)
    assert "orb" in entry_names(store, room)
    assert :available = BursarClient.query(Bursar, item)
  end

  test "zone-gate: fail-closed — a room not reachable from the world root is refused", %{
    store: store,
    node_ctx: node_ctx,
    root: root
  } do
    # An orphan room that exists but was NEVER linked under the world root,
    # and an inventory that belongs to no registered player home.
    room = mk_room!(store, node_ctx)
    inventory = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "relic")
    add_dir_entry!(store, room, "relic", item, node_ctx)
    {taker_id, _} = fresh_identity()

    assert {:error, :not_takeable_here} =
             Take.take(item, "relic", room, inventory, taker_id, store: store, root_uuid: root)

    assert "relic" in entry_names(store, room)
    assert :available = BursarClient.query(Bursar, item)
  end
end
