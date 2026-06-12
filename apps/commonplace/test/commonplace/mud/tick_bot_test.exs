defmodule Commonplace.MUD.TickBotTest do
  use ExUnit.Case

  alias Commonplace.MUD.{Bootstrap, Schemas, TickBot, Topics}
  alias Commonplace.MUD.Schemas.{Object, Room}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_mud_tick_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    # Moves take green tokens (move #4): start a Bursar under its default
    # name so World.move's default route finds it (replaces the retired
    # :global MoveServer).
    case GenServer.whereis(Commonplace.Green.Bursar) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, bursar_pid} =
      Commonplace.Green.Bursar.start_link(
        root_uuid: UUID.uuid4(),
        store: store,
        sweep_interval: 60_000
      )

    on_exit(fn -> if Process.alive?(bursar_pid), do: GenServer.stop(bursar_pid) end)

    root_uuid = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root_uuid, update, nil)

    %{store: store, root: root_uuid}
  end

  defp start_tickbot(ctx) do
    name = :"tick_bot_#{:rand.uniform(1_000_000)}"

    {:ok, pid} =
      TickBot.start_link(
        name: name,
        store: ctx.store,
        root_uuid: ctx.root,
        heartbeat_ms: 999_999,
        auto_start: false
      )

    {pid, name}
  end

  defp add_dir_entry(parent, name, child, store) do
    {:ok, schema} = Schemas.load_dir_schema(parent, store)
    schema = Schema.add_directory(schema, name, child)
    update = Encoding.encode_update(schema)
    CommitStore.create_chained_commit(store, parent, update)
  end

  test "fountain in seeded clearing emits a burble on tick", ctx do
    {:ok, _} = Bootstrap.seed(ctx.root, ctx.store)
    {_pid, name} = start_tickbot(ctx)

    # Find the clearing's UUID so we can subscribe to its red channel
    {:ok, root_schema} = Schemas.load_dir_schema(ctx.root, ctx.store)
    {:ok, clearing} = Schema.get_entry(root_schema, "clearing")

    Topics.subscribe_room(clearing.node_id)

    # First tick fires immediately because last_tick is 0 → elapsed >= interval
    :ok = TickBot.tick_now(name)

    assert_receive {"red:" <> _, %{kind: :custom, text: "The fountain burbles softly."}}, 100
  end

  test "tick fires only once per interval window", ctx do
    {:ok, _} = Bootstrap.seed(ctx.root, ctx.store)
    {_pid, name} = start_tickbot(ctx)

    {:ok, root_schema} = Schemas.load_dir_schema(ctx.root, ctx.store)
    {:ok, clearing} = Schema.get_entry(root_schema, "clearing")
    Topics.subscribe_room(clearing.node_id)

    :ok = TickBot.tick_now(name)
    assert_receive {"red:" <> _, %{kind: :custom}}, 100

    # Immediate second tick: not enough wall-clock has passed → no fire
    :ok = TickBot.tick_now(name)
    refute_receive {"red:" <> _, %{kind: :custom}}, 50
  end

  test "objects without tick_interval_ms are ignored", ctx do
    # Build a tiny world: one room with an inert object
    obj_uuid =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: "rock", description: "A rock."}),
        ctx.store
      )

    room_uuid =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: "Cave", description: "Damp."}),
        ctx.store
      )

    add_dir_entry(room_uuid, "rock.obj", obj_uuid, ctx.store)
    add_dir_entry(ctx.root, "cave", room_uuid, ctx.store)

    {_pid, name} = start_tickbot(ctx)
    Topics.subscribe_room(room_uuid)

    :ok = TickBot.tick_now(name)
    refute_receive {"red:" <> _, _}, 50
  end

  test "room-level tick_interval_ms fires the room's own tick_message", ctx do
    room_uuid =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{
          name: "Wind Tunnel",
          description: "Air rushes past.",
          tick_interval_ms: 100,
          tick_message: "The wind howls."
        }),
        ctx.store
      )

    add_dir_entry(ctx.root, "tunnel", room_uuid, ctx.store)

    {_pid, name} = start_tickbot(ctx)
    Topics.subscribe_room(room_uuid)

    :ok = TickBot.tick_now(name)
    assert_receive {"red:" <> _, %{kind: :custom, text: "The wind howls."}}, 100
  end
end
