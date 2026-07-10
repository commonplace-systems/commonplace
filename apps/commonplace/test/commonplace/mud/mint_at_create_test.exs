defmodule Commonplace.MUD.MintAtCreateTest do
  @moduledoc """
  CX-j2wt — MINT-AT-CREATE: an ITEM-object is born already holding a NODE-held
  possession token, so it can never enter play token-less (the un-droppable-gift
  bug). Covers the two build gaps (`ChildMutation.create_zoned_child` for
  OBJECTS, `Facade.spawn`), the ROOMS-are-token-exempt distinction, two-axis
  orthogonality (the mint never touches the object meta), and the end-to-end
  lifecycle regression (@create-object → take → drop → take → give, always
  droppable by the current holder).

  Scaffold mirrors `Commonplace.MUD.DropGiveTest` (enforce gate + a real
  `Commonplace.Green.Bursar`).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Green.{Bursar, BursarClient}
  alias Commonplace.MUD.{ChildMutation, Schemas, Take, World}
  alias Commonplace.MUD.Schemas.{Object, Room}
  alias Commonplace.MUD.World.Facade
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_mintcreate_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"mintcreate_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"mintcreate_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"mintcreate_tss_#{n}",
       pending_imports_name: :"mintcreate_pi_#{n}"}
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

    %{store: store, node_ctx: node_ctx, node_identity: node_identity, root: root, players: players}
  end

  # ---- helpers (mirror DropGiveTest) ----

  defp mk_dir!(store, signing_ctx) do
    {:ok, uuid} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: signing_ctx)
    uuid
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

  defp mk_inventory!(store, signing_ctx), do: mk_dir!(store, signing_ctx)

  defp share!(store, root, room_uuid, signing_ctx) do
    add_dir_entry!(store, root, "room-#{String.slice(room_uuid, 0, 8)}", room_uuid, signing_ctx)
    room_uuid
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

  defp entry_names(store, dir_uuid) do
    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    schema |> Schema.entries() |> Map.keys()
  end

  defp fresh_identity do
    {pub, priv} = Signing.generate_keypair()
    id = UUID.uuid4()
    {id, %SigningContext{identity_uuid: id, public_key: pub, private_key: priv}}
  end

  # @create-object, but at the primitive: node-sign a new OBJECT under `room`.
  defp create_object!(store, node_ctx, room, name, container? \\ false) do
    obj_json = Schemas.encode_object(%Object{name: name, description: "(no description yet)", container?: container?})

    {:ok, uuid} =
      ChildMutation.create_zoned_child(room, name, Schemas.object_filename(), obj_json, store, signing_context: node_ctx)

    uuid
  end

  # ---- 1. mint-at-create: @create-object → node-held token immediately ----

  test "a newly @create-object'd object holds a NODE-held possession token immediately", %{
    store: store,
    node_ctx: node_ctx,
    node_identity: node_identity,
    root: root
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    item = create_object!(store, node_ctx, room, "lantern.obj")

    # The object entered play holding a real, node-held, permanent token —
    # WITHOUT anyone taking it first.
    assert {:held, %{holder: ^node_identity}} = BursarClient.query(Bursar, item)
    assert "lantern.obj" in entry_names(store, room)
  end

  # ---- 2. ROOMS are token-EXEMPT (zone-ownership, not tokens) ----

  test "a @create-room'd room does NOT get a possession token (rooms use zone-ownership)", %{
    store: store,
    node_ctx: node_ctx,
    root: root
  } do
    home = share!(store, root, mk_room!(store, node_ctx), node_ctx)

    {:ok, study} =
      ChildMutation.create_zoned_child(home, "study", Schemas.room_filename(), Schemas.encode_room(%Room{name: "Study", description: "a room"}), store, signing_context: node_ctx)

    # No possession token was minted for the room.
    assert :available = BursarClient.query(Bursar, study)
  end

  # ---- 3. Facade.spawn → node-held token ----

  test "Facade.spawn'd object holds a node-held token", %{
    store: store,
    node_ctx: node_ctx,
    node_identity: node_identity,
    root: root
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)

    ctx = %{
      signing_context: node_ctx,
      cert_cids: [],
      signer_id: Signing.signer_id(node_ctx.identity_uuid, node_ctx.public_key),
      player_uuid: UUID.uuid4(),
      player_name: "builder",
      current_room_uuid: room,
      inventory_uuid: mk_inventory!(store, node_ctx)
    }

    facade = Facade.new(ctx, room, [room], nil, store)
    assert {:ok, spawned} = Facade.spawn(facade, "totem")

    assert {:held, %{holder: ^node_identity}} = BursarClient.query(Bursar, spawned)
  end

  # ---- 4. ORTHOGONALITY: the mint never touches the object meta / availability ----
  #
  # A plain Object has NO distinct availability/reward field (the "availability"
  # axis is the Bursar token itself; the meta doc carries only type/display
  # fields). So orthogonality is proven by asserting the possession-token mint
  # left the object META byte-for-byte identical to what was encoded at create.
  test "mint-at-create leaves the object meta (the non-possession axis) untouched", %{
    store: store,
    node_ctx: node_ctx,
    root: root
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    original = %Object{name: "gilded chalice", description: "(no description yet)", aliases: ["chalice"]}
    obj_json = Schemas.encode_object(original)

    {:ok, item} =
      ChildMutation.create_zoned_child(room, "chalice.obj", Schemas.object_filename(), obj_json, store, signing_context: node_ctx)

    # token minted (possession axis)...
    assert {:held, _} = BursarClient.query(Bursar, item)

    # ...and the meta axis is intact: every declared field round-trips unchanged
    # (the mint wrote ONLY the Bursar token, never the meta doc).
    assert {:ok, loaded} = Schemas.load_object(item, store)
    assert loaded.name == original.name
    assert loaded.description == original.description
    assert loaded.aliases == original.aliases
    assert loaded.fixed == false
    assert loaded.container? == false
    # the two-axis trap: the reward/vein availability fields stay pristine nil.
    assert loaded.kind == "object"
    assert loaded.yield_type == nil
    assert loaded.yield_remaining == nil
  end

  # ---- 5. FULL LIFECYCLE regression: create → take → drop → take → give ----

  test "lifecycle: @create-object → take → drop → take → give, droppable by the current holder throughout", %{
    store: store,
    node_ctx: node_ctx,
    node_identity: node_identity,
    root: root
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    alice_inv = mk_inventory!(store, node_ctx)
    bob_inv = mk_inventory!(store, node_ctx)

    {alice_id, _} = fresh_identity()
    {bob_id, _} = fresh_identity()

    # CREATE — born node-held, sitting in the room (nobody took it yet).
    item = create_object!(store, node_ctx, room, "coin.obj")
    assert {:held, %{holder: ^node_identity}} = BursarClient.query(Bursar, item)

    # TAKE — node → alice.
    assert :ok = Take.take(item, "coin.obj", room, alice_inv, alice_id, store: store, root_uuid: root)
    assert {:held, %{holder: ^alice_id}} = BursarClient.query(Bursar, item)

    # DROP — the crux of CX-j2wt: a freshly-created-then-taken item is droppable
    # (the pre-fix token-less gift could NOT be dropped). alice → node.
    assert :ok = World.drop_item(item, "coin.obj", alice_inv, room, alice_id, store: store)
    assert "coin.obj" in entry_names(store, room)
    assert {:held, %{holder: ^node_identity}} = BursarClient.query(Bursar, item)

    # TAKE again — node → alice.
    assert :ok = Take.take(item, "coin.obj", room, alice_inv, alice_id, store: store, root_uuid: root)
    assert {:held, %{holder: ^alice_id}} = BursarClient.query(Bursar, item)

    # GIVE — alice → bob (token follows the item).
    assert :ok = World.give_item(item, "coin.obj", alice_inv, bob_inv, alice_id, bob_id, store: store)
    refute "coin.obj" in entry_names(store, alice_inv)
    assert "coin.obj" in entry_names(store, bob_inv)
    assert {:held, %{holder: ^bob_id}} = BursarClient.query(Bursar, item)
  end

  # ---- 6. CONTAINER regression: a MINTED container still accepts put/get ----
  #
  # A container is an `.obj` that BOTH holds a permanent possession token (now
  # minted at create) AND is a move endpoint when you `put`/`get ... from` it.
  # If the ephemeral move-lock shared the possession-token namespace (bare uuid),
  # every deposit into a token-holding container would `:busy` forever. This
  # pins the CX-j2wt move-lock/possession namespace separation.
  test "a minted CONTAINER still accepts put and get (move-lock ≠ possession token)", %{
    store: store,
    node_ctx: node_ctx,
    node_identity: node_identity,
    root: root
  } do
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    inv = mk_inventory!(store, node_ctx)

    # A container object, born holding a NODE-held possession token at its uuid.
    container = create_object!(store, node_ctx, room, "chest.obj", true)
    assert {:held, %{holder: ^node_identity}} = BursarClient.query(Bursar, container)

    # A plain item to move in and out of it.
    item = create_object!(store, node_ctx, room, "gem.obj")
    {player_id, _} = fresh_identity()
    assert :ok = Take.take(item, "gem.obj", room, inv, player_id, store: store, root_uuid: root)

    # PUT the gem INTO the container: the deposit move-locks the container dir.
    # Pre-fix this raced its own permanent possession token → :busy forever.
    assert :ok = World.deposit_item(item, "gem.obj", inv, container, player_id, store: store)
    assert "gem.obj" in entry_names(store, container)

    # GET it back OUT of the container: the take move-locks the container as the
    # SOURCE dir — the other half of the same collision.
    assert :ok = Take.take(item, "gem.obj", container, inv, player_id, store: store, root_uuid: root)
    assert "gem.obj" in entry_names(store, inv)
    refute "gem.obj" in entry_names(store, container)
  end
end
