defmodule Commonplace.MUD.DropGiveTest do
  @moduledoc """
  CX-cj3t.2 — DROP/GIVE under enforce: the invoker-holder push
  (`Commonplace.MUD.HolderMove`, exercised via `World.drop_item/6` and
  `World.give_item/7`). Covers the happy paths, the token-not-held
  refusal (gate (a)), rollback on move failure, and the headline
  coupling proof: DROP + the TAKE-zone-gate (CX-1mz7, already shipped)
  jointly close the home-raid vulnerability.

  Setup mirrors `Commonplace.MUD.TakeTest`'s `Commonplace.Store.Supervisor`
  + `Commonplace.Green.Bursar` bring-up.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Document.ContentType
  alias Commonplace.Green.{Bursar, BursarClient}
  alias Commonplace.MUD.{Parser, Schemas, Take, Verbs, World}
  alias Commonplace.MUD.World.Facade
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

    dir = Path.join(System.tmp_dir!(), "cp_dropgive_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"dropgive_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"dropgive_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"dropgive_tss_#{n}",
       pending_imports_name: :"dropgive_pi_#{n}"}
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

  # ---- seed helpers (mirrors TakeTest) ----

  defp mk_dir!(store, signing_ctx) do
    {:ok, uuid} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: signing_ctx)
    uuid
  end

  defp share!(store, root, room_uuid, signing_ctx) do
    add_dir_entry!(store, root, "room-#{String.slice(room_uuid, 0, 8)}", room_uuid, signing_ctx)
    room_uuid
  end

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

  defp add_dir_entry!(store, parent_uuid, name, child_uuid, signing_ctx) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_directory(schema, name, child_uuid)
    update = Encoding.encode_update(schema)
    {metadata, commit_opts} = Commonplace.MUD.SignedWrite.opts_for(parent_uuid, store: store, signing_context: signing_ctx)

    case CommitStoreClient.create_chained_commit(store, parent_uuid, update, metadata, commit_opts) do
      {:error, _} = err -> raise "seed write failed: #{inspect(err)}"
      _commit -> :ok
    end
  end

  defp add_file_entry!(store, parent_uuid, name, child_uuid, signing_ctx) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_file(schema, name, child_uuid)
    update = Encoding.encode_update(schema)
    {metadata, commit_opts} = Commonplace.MUD.SignedWrite.opts_for(parent_uuid, store: store, signing_context: signing_ctx)

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

  # Seed a presence doc bound to `identity` and link it as a `.usr` entry
  # in `room_uuid` (node-signed, since the room is node-owned — a
  # visiting player's OWN presence write is a separate, already-covered
  # concern; here we only need the doc to exist with `bound_identity`
  # stamped so `give`'s `resolve_recipient_identity/2` can read it).
  # Built directly against the doc rather than via `Presence.create/5`
  # so binding to `identity` doesn't require `identity` itself to be an
  # authorized signer of the node-owned room.
  defp seed_presence!(store, room_uuid, name, identity, node_ctx) do
    fname = "#{name}.usr"
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :map, fname)
    doc = ContentType.set_key(doc, "name", name)
    doc = ContentType.set_key(doc, "type", "usr")
    doc = ContentType.set_key(doc, "bound_identity", identity)
    update = Encoding.encode_update(doc)
    {metadata, commit_opts} = Commonplace.MUD.SignedWrite.opts_for(uuid, store: store, signing_context: node_ctx)

    case CommitStoreClient.create_commit(store, uuid, update, nil, metadata, commit_opts) do
      {:error, _} = err -> raise "seed write failed: #{inspect(err)}"
      _commit -> :ok
    end

    add_file_entry!(store, room_uuid, fname, uuid, node_ctx)
    uuid
  end

  # Seed a presence doc with NO `bound_identity` (anonymous / legacy) —
  # `resolve_recipient_identity/2` will read nil for it, exercising the
  # GIVE fail-closed path (plan #6764 Q2).
  defp seed_presence_no_identity!(store, room_uuid, name, node_ctx) do
    fname = "#{name}.usr"
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :map, fname)
    doc = ContentType.set_key(doc, "name", name)
    doc = ContentType.set_key(doc, "type", "usr")
    update = Encoding.encode_update(doc)
    {metadata, commit_opts} = Commonplace.MUD.SignedWrite.opts_for(uuid, store: store, signing_context: node_ctx)

    case CommitStoreClient.create_commit(store, uuid, update, nil, metadata, commit_opts) do
      {:error, _} = err -> raise "seed write failed: #{inspect(err)}"
      _commit -> :ok
    end

    add_file_entry!(store, room_uuid, fname, uuid, node_ctx)
    uuid
  end

  # ---- 1. DROP happy path ----

  test "drop: an item held via prior take can be dropped into the current room", %{
    store: store,
    node_ctx: node_ctx,
    node_identity: node_identity,
    root: root
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    inventory = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "widget.obj")
    add_dir_entry!(store, room, "widget.obj", item, node_ctx)

    {player_id, _} = fresh_identity()
    assert :ok = Take.take(item, "widget.obj", room, inventory, player_id, store: store, root_uuid: root)

    assert :ok = World.drop_item(item, "widget.obj", inventory, room, player_id, store: store)

    refute "widget.obj" in entry_names(store, inventory)
    assert "widget.obj" in entry_names(store, room)
    assert {:held, %{holder: ^node_identity}} = BursarClient.query(Bursar, item)
  end

  # ---- 2. DROP without holding the token ----

  test "drop: a player who never took the item cannot drop it (token not theirs)", %{
    store: store,
    node_ctx: node_ctx,
    root: root
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    inventory = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "phantom.obj")
    # Seeded straight into the inventory, bypassing Take — the token
    # is still `:available` (or node-held), never transferred to the
    # "player".
    add_file_entry!(store, inventory, "phantom.obj", item, node_ctx)

    {player_id, _} = fresh_identity()

    assert {:error, :not_holder} =
             World.drop_item(item, "phantom.obj", inventory, room, player_id, store: store)

    assert "phantom.obj" in entry_names(store, inventory)
    refute "phantom.obj" in entry_names(store, room)
    assert :available = BursarClient.query(Bursar, item)
  end

  # ---- CX-5c78: PUT (deposit) into a curated node-owned container ----

  test "deposit: a visitor can put a held item into a curated (node-owned) container — elevates (was refused loot-only)", %{
    store: store,
    node_ctx: node_ctx,
    node_identity: node_identity,
    root: root
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    container = mk_object!(store, node_ctx, name: "reliquary.obj")
    add_dir_entry!(store, room, "reliquary.obj", container, node_ctx)
    inventory = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "coin.obj")
    add_dir_entry!(store, room, "coin.obj", item, node_ctx)

    # The visitor takes the coin (now holds its token), then deposits it into
    # the node-owned reliquary. Pre-fix `put` used the un-elevated World.move →
    # {:trust_rejected} (loot-only). Now it routes through the HolderMove
    # push-to-node path (like drop) → elevates → lands.
    {player_id, _} = fresh_identity()
    assert :ok = Take.take(item, "coin.obj", room, inventory, player_id, store: store, root_uuid: root)

    assert :ok = World.deposit_item(item, "coin.obj", inventory, container, player_id, store: store)

    refute "coin.obj" in entry_names(store, inventory)
    assert "coin.obj" in entry_names(store, container)
    # token now node-held → takeable-from-container (put/take symmetric).
    assert {:held, %{holder: ^node_identity}} = BursarClient.query(Bursar, item)
  end

  test "deposit: a visitor who never held the item cannot put it in a container (token not theirs)", %{
    store: store,
    node_ctx: node_ctx,
    root: root
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    container = mk_object!(store, node_ctx, name: "chest.obj")
    add_dir_entry!(store, room, "chest.obj", container, node_ctx)
    inventory = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "phantom.obj")
    # Seeded straight into inventory, bypassing Take — token never transferred.
    add_file_entry!(store, inventory, "phantom.obj", item, node_ctx)

    {player_id, _} = fresh_identity()

    assert {:error, :not_holder} =
             World.deposit_item(item, "phantom.obj", inventory, container, player_id, store: store)

    assert "phantom.obj" in entry_names(store, inventory)
    refute "phantom.obj" in entry_names(store, container)
    assert :available = BursarClient.query(Bursar, item)
  end

  # ---- 3. GIVE happy path ----

  test "give: an item held via prior take can be given to a recipient present in the room", %{
    store: store,
    node_ctx: node_ctx,
    root: root
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    giver_inv = mk_inventory!(store, node_ctx)
    recipient_inv = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "coin.obj")
    add_dir_entry!(store, room, "coin.obj", item, node_ctx)

    {giver_id, _} = fresh_identity()
    {recipient_id, _} = fresh_identity()

    assert :ok = Take.take(item, "coin.obj", room, giver_inv, giver_id, store: store, root_uuid: root)

    assert :ok =
             World.give_item(item, "coin.obj", giver_inv, recipient_inv, giver_id, recipient_id, store: store)

    refute "coin.obj" in entry_names(store, giver_inv)
    assert "coin.obj" in entry_names(store, recipient_inv)
    assert {:held, %{holder: ^recipient_id}} = BursarClient.query(Bursar, item)
  end

  # ---- 4. GIVE without holding the token ----

  test "give: a player who never took the item cannot give it away (token not theirs)", %{
    store: store,
    node_ctx: node_ctx
  } do
    giver_inv = mk_inventory!(store, node_ctx)
    recipient_inv = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "trinket.obj")
    add_file_entry!(store, giver_inv, "trinket.obj", item, node_ctx)

    {giver_id, _} = fresh_identity()
    {recipient_id, _} = fresh_identity()

    assert {:error, :not_holder} =
             World.give_item(item, "trinket.obj", giver_inv, recipient_inv, giver_id, recipient_id, store: store)

    assert "trinket.obj" in entry_names(store, giver_inv)
    refute "trinket.obj" in entry_names(store, recipient_inv)
    assert :available = BursarClient.query(Bursar, item)
  end

  # ---- 4b. FACADE give_from_inventory converges on the SAME chokepoint ----
  #
  # CX-j2wt: the safe-verb quest/gift method `Facade.give_from_inventory/3`
  # used to raw add_child_entry+unlink the tree entry into the recipient's
  # inventory WITHOUT transferring the possession token — the item showed in
  # the recipient's inventory but any drop/put said "you aren't carrying that"
  # (jes's live bug). It now routes through `World.give_item/7`, so the token
  # transfers giver → recipient exactly like the `give` command.

  test "give_from_inventory (facade): a held gift transfers its token to the recipient — the CX-j2wt fix (droppable, not a ghost)", %{
    store: store,
    node_ctx: node_ctx,
    root: root,
    players: players
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)

    # Giver: a fresh visitor who TAKES an item, so they hold its token.
    {giver_id, giver_ctx} = fresh_identity()
    giver_inv = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "coin.obj")
    add_dir_entry!(store, room, "coin.obj", item, node_ctx)
    assert :ok = Take.take(item, "coin.obj", room, giver_inv, giver_id, store: store, root_uuid: root)

    # Recipient bob: resolvable at players/bob/inventory AND present in the
    # room with a bound identity (so the token can transfer to them).
    bob = mk_home!(store, players, "bob", node_ctx)
    {bob_id, _} = fresh_identity()
    seed_presence!(store, room, "bob", bob_id, node_ctx)

    f =
      Facade.new(
        %{
          signing_context: giver_ctx,
          cert_cids: [],
          signer_id: nil,
          inventory_uuid: giver_inv,
          current_room_uuid: room,
          root_uuid: root,
          player_name: "alice"
        },
        item,
        [],
        {"verbs/x.safe.elx", "owner-x"},
        store
      )

    assert :ok = Facade.give_from_inventory(f, "coin", "bob")

    refute "coin.obj" in entry_names(store, giver_inv)
    assert "coin.obj" in entry_names(store, bob.inventory)
    # THE FIX: the recipient now HOLDS the token (was left with the giver).
    assert {:held, %{holder: ^bob_id}} = BursarClient.query(Bursar, item)
  end

  test "give_from_inventory (facade): gifting a token-less ghost is refused :not_carrying — no silent desynced deposit", %{
    store: store,
    node_ctx: node_ctx,
    root: root,
    players: players
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)

    # A visitor whose inventory dir CONTAINS an item they never held the
    # token for (the legacy desynced-ghost shape).
    {_giver_id, giver_ctx} = fresh_identity()
    giver_inv = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "ghost.obj")
    add_file_entry!(store, giver_inv, "ghost.obj", item, node_ctx)

    bob = mk_home!(store, players, "bob", node_ctx)
    {bob_id, _} = fresh_identity()
    seed_presence!(store, room, "bob", bob_id, node_ctx)

    f =
      Facade.new(
        %{
          signing_context: giver_ctx,
          cert_cids: [],
          signer_id: nil,
          inventory_uuid: giver_inv,
          current_room_uuid: room,
          root_uuid: root,
          player_name: "alice"
        },
        item,
        [],
        {"verbs/x.safe.elx", "owner-x"},
        store
      )

    # Refused at the token gate (the giver never held it), mapped to the
    # honest player-facing :not_carrying — NOT a silent ghost deposit.
    assert {:error, :not_carrying} = Facade.give_from_inventory(f, "ghost", "bob")

    # Nothing moved: the item stayed put and bob's inventory is untouched.
    assert "ghost.obj" in entry_names(store, giver_inv)
    refute "ghost.obj" in entry_names(store, bob.inventory)
    # Token never existed for this item, and none was minted by the refusal.
    assert :available = BursarClient.query(Bursar, item)
  end

  # ---- 5. Rollback on move failure ----

  test "drop: move failure after token transfer rolls the token back to the dropper", %{
    store: store,
    node_ctx: node_ctx,
    root: root
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    inventory = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "coin")
    add_dir_entry!(store, room, "trigger", item, node_ctx)

    {player_id, _} = fresh_identity()
    assert :ok = Take.take(item, "trigger", room, inventory, player_id, store: store, root_uuid: root)

    # collide: an entry named "coin" already lives in the destination room.
    other_item = mk_object!(store, node_ctx, name: "coin")
    add_file_entry!(store, room, "coin", other_item, node_ctx)
    # rename our held item's entry to "coin" in the inventory so the drop
    # attempts to write that colliding name at the destination.
    {:ok, inv_schema} = Schemas.load_dir_schema(inventory, store)
    inv_schema = Schema.remove_entry(inv_schema, "trigger")
    inv_schema = Schema.add_file(inv_schema, "coin", item)
    update = Encoding.encode_update(inv_schema)
    {metadata, commit_opts} = Commonplace.MUD.SignedWrite.opts_for(inventory, store: store, signing_context: node_ctx)

    case CommitStoreClient.create_chained_commit(store, inventory, update, metadata, commit_opts) do
      {:error, _} = err -> raise "seed write failed: #{inspect(err)}"
      _commit -> :ok
    end

    assert {:error, :collision} = World.drop_item(item, "coin", inventory, room, player_id, store: store)

    assert "coin" in entry_names(store, inventory)
    assert {:held, %{holder: ^player_id}} = BursarClient.query(Bursar, item)
  end

  # ---- 6. GIVE via full verb dispatch: presence-resolved recipient identity ----

  test "give: full verb dispatch resolves the recipient's identity from their presence doc", %{
    store: store,
    node_ctx: node_ctx,
    root: root,
    players: players
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    bob = mk_home!(store, players, "bob", node_ctx)
    alice_inv = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "ring.obj")
    add_dir_entry!(store, room, "ring.obj", item, node_ctx)

    {alice_id, alice_sc} = fresh_identity()
    {bob_id, _} = fresh_identity()

    assert :ok = Take.take(item, "ring.obj", room, alice_inv, alice_id, store: store, root_uuid: root)

    seed_presence!(store, room, "bob", bob_id, node_ctx)

    ctx = %{
      player_name: "alice",
      current_room_uuid: room,
      inventory_uuid: alice_inv,
      root_uuid: root,
      store: store,
      signing_context: alice_sc,
      cert_cids: [],
      signer_id: Signing.signer_id(alice_id, alice_sc.public_key)
    }

    cmd = %Parser.Command{verb: "give", args: "ring to bob", argv: ["ring", "to", "bob"]}
    assert {:reply, msg} = Verbs.dispatch(cmd, ctx)
    assert msg =~ "You give"

    refute "ring.obj" in entry_names(store, alice_inv)
    assert "ring.obj" in entry_names(store, bob.inventory)
    assert {:held, %{holder: ^bob_id}} = BursarClient.query(Bursar, item)
  end

  # ---- 7. THE COUPLING PROOF: DROP + TAKE-zone-gate close the home-raid ----

  test "coupling proof: a visitor cannot take a dropped item from another player's home, but the owner can", %{
    store: store,
    node_ctx: node_ctx,
    root: root,
    players: players
  } do
    alice = mk_home!(store, players, "alice", node_ctx)
    bob = mk_home!(store, players, "bob", node_ctx)

    shared_room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    item = mk_object!(store, node_ctx, name: "gem.obj")
    add_dir_entry!(store, shared_room, "gem.obj", item, node_ctx)

    {alice_id, _} = fresh_identity()
    {bob_id, _} = fresh_identity()

    # Alice takes the gem from the shared room into her own inventory,
    # then drops it in her own home.
    assert :ok =
             Take.take(item, "gem.obj", shared_room, alice.inventory, alice_id, store: store, root_uuid: root)

    assert :ok = World.drop_item(item, "gem.obj", alice.inventory, alice.home, alice_id, store: store)
    assert "gem.obj" in entry_names(store, alice.home)

    # Bob (a visitor) cannot take it from Alice's home — the TAKE-zone-gate refuses.
    assert {:error, :not_takeable_here} =
             Take.take(item, "gem.obj", alice.home, bob.inventory, bob_id, store: store, root_uuid: root)

    assert "gem.obj" in entry_names(store, alice.home)

    # Alice CAN take it back from her own home.
    assert :ok =
             Take.take(item, "gem.obj", alice.home, alice.inventory, alice_id, store: store, root_uuid: root)

    refute "gem.obj" in entry_names(store, alice.home)
    assert "gem.obj" in entry_names(store, alice.inventory)
    assert {:held, %{holder: ^alice_id}} = BursarClient.query(Bursar, item)
  end

  # ---- 8. CX-1mz7 Q2 (plan #6764): GIVE fails closed on an unresolvable
  # recipient identity — never transfer the possession token to a nil/void
  # holder. The giver keeps BOTH the item and its token. ----

  test "give: fails closed when the recipient's presence has no bound_identity", %{
    store: store,
    node_ctx: node_ctx,
    root: root,
    players: players
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    bob = mk_home!(store, players, "bob", node_ctx)
    alice_inv = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "amulet.obj")
    add_dir_entry!(store, room, "amulet.obj", item, node_ctx)

    {alice_id, alice_sc} = fresh_identity()
    assert :ok = Take.take(item, "amulet.obj", room, alice_inv, alice_id, store: store, root_uuid: root)

    # Bob is present, but his presence doc carries NO bound_identity ->
    # resolve_recipient_identity/2 returns nil -> the enforce push guard
    # refuses BEFORE any token transfer or tree write.
    seed_presence_no_identity!(store, room, "bob", node_ctx)

    ctx = %{
      player_name: "alice",
      current_room_uuid: room,
      inventory_uuid: alice_inv,
      root_uuid: root,
      store: store,
      signing_context: alice_sc,
      cert_cids: [],
      signer_id: Signing.signer_id(alice_id, alice_sc.public_key)
    }

    cmd = %Parser.Command{verb: "give", args: "amulet to bob", argv: ["amulet", "to", "bob"]}
    assert {:error, _msg} = Verbs.dispatch(cmd, ctx)

    # Fail-closed: item stays with the giver; the token was NEVER moved
    # (Alice still holds it — nothing lost to the void).
    assert "amulet.obj" in entry_names(store, alice_inv)
    refute "amulet.obj" in entry_names(store, bob.inventory)
    assert {:held, %{holder: ^alice_id}} = BursarClient.query(Bursar, item)
  end
end
