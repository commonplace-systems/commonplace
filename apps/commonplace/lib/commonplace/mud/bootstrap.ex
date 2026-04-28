defmodule Commonplace.MUD.Bootstrap do
  @moduledoc """
  Idempotent v0 world seeding. Creates three rooms (start, forest-path,
  clearing), a cloak.obj in the start room, and a fountain.obj in the
  clearing on first run. Subsequent calls are no-ops.

  Layout:

      <root>/
        start/           __room.json + cloak.obj
        forest-path/     __room.json
        clearing/        __room.json + fountain.obj
        players/         (lazily created by PlayerSession)
  """

  alias Commonplace.MUD.Schemas
  alias Commonplace.MUD.Schemas.{Object, Room}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  def seed(root_uuid, store \\ CommitStoreClient) do
    {:ok, root_schema} = Schemas.load_dir_schema(root_uuid, store)

    case Schema.get_entry(root_schema, "start") do
      {:ok, _} -> {:ok, :already_seeded}
      :error -> do_seed(root_uuid, store)
    end
  end

  defp do_seed(root_uuid, store) do
    start_uuid = create_room(%Room{name: "The Start Room", description: "A cozy stone chamber. Exits lead north and east.", exits: %{}}, store)
    forest_uuid = create_room(%Room{name: "A Forest Path", description: "Tall oaks line a winding dirt path. The Start Room lies south.", exits: %{}}, store)
    clearing_uuid = create_room(%Room{name: "A Sunlit Clearing", description: "A grassy clearing dappled with sunlight. The Start Room lies west.", exits: %{}}, store)

    set_exits(start_uuid, %{"north" => forest_uuid, "east" => clearing_uuid}, store)
    set_exits(forest_uuid, %{"south" => start_uuid}, store)
    set_exits(clearing_uuid, %{"west" => start_uuid}, store)

    cloak_uuid = create_object(%Object{name: "cloak", aliases: ["cape", "black cloak"], description: "A heavy black cloak. It looks warm."}, store)
    fountain_uuid =
      create_object(
        %Object{
          name: "fountain",
          aliases: ["water"],
          description: "A stone fountain murmurs softly.",
          fixed: true,
          tick_interval_ms: 8_000,
          tick_message: "The fountain burbles softly."
        },
        store
      )

    add_dir_entry(start_uuid, "cloak.obj", cloak_uuid, store)
    add_dir_entry(clearing_uuid, "fountain.obj", fountain_uuid, store)

    add_dir_entry(root_uuid, "start", start_uuid, store)
    add_dir_entry(root_uuid, "forest-path", forest_uuid, store)
    add_dir_entry(root_uuid, "clearing", clearing_uuid, store)

    {:ok, :seeded}
  end

  defp create_room(room, store) do
    json = Schemas.encode_room(room)
    Schemas.create_dir_with_meta(Schemas.room_filename(), json, store)
  end

  defp create_object(obj, store) do
    json = Schemas.encode_object(obj)
    Schemas.create_dir_with_meta(Schemas.object_filename(), json, store)
  end

  defp set_exits(room_dir_uuid, exits, store) do
    {:ok, schema} = Schemas.load_dir_schema(room_dir_uuid, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.room_filename())
    {:ok, %Room{} = room} = Schemas.load_room(room_dir_uuid, store)
    json = Schemas.encode_room(%Room{room | exits: Map.merge(room.exits, exits)})
    :ok = Schemas.write_meta_doc(entry.node_id, json, store)
  end

  defp add_dir_entry(parent_uuid, name, child_uuid, store) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_directory(schema, name, child_uuid)
    update = Encoding.encode_update(schema)
    CommitStoreClient.create_chained_commit(store, parent_uuid, update)
    :ok
  end
end
