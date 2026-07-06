defmodule Commonplace.MUD.BootstrapTest do
  use ExUnit.Case

  alias Commonplace.MUD.{Bootstrap, Schemas, VerbSource}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  # CX-k8lq: bootstrap seeding must place movable objects (cloak,
  # fountain) exactly once per world, no matter how many times
  # `seed/2`/`repair/2` runs afterward (every login re-runs it). Rooms
  # and exits stay structural — ensure/repair on every call is correct
  # and must keep working (CX-93ea half-built-world case).

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_mud_bootstrap_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    root_uuid = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root_uuid, update, nil)

    %{store: store, root: root_uuid}
  end

  defp start_room_uuid(root_uuid, store) do
    {:ok, root_schema} = Schemas.load_dir_schema(root_uuid, store)
    {:ok, entry} = Schema.get_entry(root_schema, "start")
    entry.node_id
  end

  defp clearing_uuid(root_uuid, store) do
    {:ok, root_schema} = Schemas.load_dir_schema(root_uuid, store)
    {:ok, entry} = Schema.get_entry(root_schema, "clearing")
    entry.node_id
  end

  # Simulates a player TAKE: removes the object's entry from the room's
  # schema (as `World.move`/verbs.ex's `do_take` would when relocating
  # it into a player's inventory) without needing the full
  # PlayerSession/PubSub/Bursar stack.
  defp simulate_take(room_uuid, filename, store) do
    {:ok, schema} = Schemas.load_dir_schema(room_uuid, store)
    schema = Schema.remove_entry(schema, filename)
    update = Encoding.encode_update(schema)
    %Commonplace.Store.Commit{} = CommitStore.create_chained_commit(store, room_uuid, update)
    :ok
  end

  test "fresh world seeds rooms, exits, and objects fully once", ctx do
    assert {:ok, :ready} = Bootstrap.seed(ctx.root, ctx.store)

    start_uuid = start_room_uuid(ctx.root, ctx.store)
    {:ok, start_schema} = Schemas.load_dir_schema(start_uuid, ctx.store)
    assert {:ok, _} = Schema.get_entry(start_schema, "cloak.obj")

    clearing_uuid = clearing_uuid(ctx.root, ctx.store)
    {:ok, clearing_schema} = Schemas.load_dir_schema(clearing_uuid, ctx.store)
    assert {:ok, _} = Schema.get_entry(clearing_schema, "fountain.obj")

    {:ok, root_schema} = Schemas.load_dir_schema(ctx.root, ctx.store)
    assert {:ok, _} = Schema.get_entry(root_schema, ".mud-seeded")
  end

  test "taking the seeded cloak then re-seeding does not mint a duplicate", ctx do
    assert {:ok, :ready} = Bootstrap.seed(ctx.root, ctx.store)
    start_uuid = start_room_uuid(ctx.root, ctx.store)

    {:ok, start_schema} = Schemas.load_dir_schema(start_uuid, ctx.store)
    assert {:ok, cloak_entry} = Schema.get_entry(start_schema, "cloak.obj")
    original_cloak_uuid = cloak_entry.node_id

    :ok = simulate_take(start_uuid, "cloak.obj", ctx.store)

    {:ok, start_schema_after_take} = Schemas.load_dir_schema(start_uuid, ctx.store)
    assert :error = Schema.get_entry(start_schema_after_take, "cloak.obj")

    # A second login / repair run must NOT re-place the cloak.
    assert {:ok, :ready} = Bootstrap.seed(ctx.root, ctx.store)

    {:ok, start_schema_after_reseed} = Schemas.load_dir_schema(start_uuid, ctx.store)
    assert :error = Schema.get_entry(start_schema_after_reseed, "cloak.obj")

    # The original object document is untouched — it still exists,
    # just no longer filed under the room (it "moved" to inventory).
    assert {:ok, %Schemas.Object{name: "cloak"}} =
             Schemas.load_object(original_cloak_uuid, ctx.store)
  end

  test "a custom verb saved on a taken object survives a second login/reseed", ctx do
    assert {:ok, :ready} = Bootstrap.seed(ctx.root, ctx.store)
    start_uuid = start_room_uuid(ctx.root, ctx.store)

    {:ok, start_schema} = Schemas.load_dir_schema(start_uuid, ctx.store)
    assert {:ok, cloak_entry} = Schema.get_entry(start_schema, "cloak.obj")
    cloak_uuid = cloak_entry.node_id

    src = """
    defmodule Verb do
      def run(ctx), do: {:say, ctx, "The cloak swishes."}
    end
    """

    assert :ok = VerbSource.save_verb(cloak_uuid, "swish", src, ctx.store)
    assert {:ok, _mod} = VerbSource.compile_verb(cloak_uuid, "swish", ctx.store)

    :ok = simulate_take(start_uuid, "cloak.obj", ctx.store)

    # Second login re-runs the full seed/repair path.
    assert {:ok, :ready} = Bootstrap.seed(ctx.root, ctx.store)

    # No fresh, verb-less cloak shadows the original in the start room...
    {:ok, start_schema_after_reseed} = Schemas.load_dir_schema(start_uuid, ctx.store)
    assert :error = Schema.get_entry(start_schema_after_reseed, "cloak.obj")

    # ...and the player-authored verb on the ORIGINAL object still compiles.
    assert {:ok, _mod} = VerbSource.compile_verb(cloak_uuid, "swish", ctx.store)
  end

  test "rooms and exits are still ensured/repaired idempotently (CX-93ea stub world)", ctx do
    # Simulate PlayerSession's stub fallback: only `start` exists, with
    # the featureless placeholder description, no exits, no objects yet.
    json =
      Schemas.encode_room(%Schemas.Room{
        name: "The Start Room",
        description: "A featureless white room. The world has not been built out yet.",
        exits: %{}
      })

    {:ok, stub_room_uuid} = Schemas.create_dir_with_meta(Schemas.room_filename(), json, ctx.store)

    {:ok, root_schema} = Schemas.load_dir_schema(ctx.root, ctx.store)
    root_schema = Schema.add_directory(root_schema, "start", stub_room_uuid)
    update = Encoding.encode_update(root_schema)
    %Commonplace.Store.Commit{} = CommitStore.create_chained_commit(ctx.store, ctx.root, update)

    assert {:ok, :ready} = Bootstrap.repair(ctx.root, ctx.store)

    {:ok, start} = Schemas.load_room(stub_room_uuid, ctx.store)
    assert start.description == "A cozy stone chamber. Exits lead north and east."
    assert map_size(start.exits) == 2

    clearing_uuid = clearing_uuid(ctx.root, ctx.store)
    {:ok, clearing_schema} = Schemas.load_dir_schema(clearing_uuid, ctx.store)
    assert {:ok, _} = Schema.get_entry(clearing_schema, "fountain.obj")

    # Repeated repair stays idempotent for structural pieces too.
    assert {:ok, :ready} = Bootstrap.repair(ctx.root, ctx.store)
    {:ok, start_again} = Schemas.load_room(stub_room_uuid, ctx.store)
    assert start_again.description == "A cozy stone chamber. Exits lead north and east."
    assert map_size(start_again.exits) == 2
  end
end
