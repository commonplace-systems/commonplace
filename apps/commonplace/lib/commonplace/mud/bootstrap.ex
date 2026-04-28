defmodule Commonplace.MUD.Bootstrap do
  @moduledoc """
  Idempotent v0 world seeding/repair.

  `seed/2` (and its alias `repair/2`) ensures the three demo rooms
  (start, forest-path, clearing) exist with canonical descriptions and
  exits, plus the bootstrap objects (cloak in start, fountain in
  clearing) — creating any missing piece without clobbering existing
  state.

  Three states this function must handle idempotently:

    1. Empty world (fresh init) — create everything.
    2. Already-seeded world — no-ops on every check; cheap.
    3. Stub world — `start` exists with the featureless-room
       description left behind by `PlayerSession.ensure_start_room`'s
       fallback. Refresh start's description + exits, create the
       missing rooms/objects.

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

  @stub_descriptions [
    "A featureless white room. The world has not been built out yet."
  ]

  def seed(root_uuid, store \\ CommitStoreClient), do: repair(root_uuid, store)

  def repair(root_uuid, store \\ CommitStoreClient) do
    start_uuid =
      ensure_room(root_uuid, "start", %Room{
        name: "The Start Room",
        description: "A cozy stone chamber. Exits lead north and east.",
        exits: %{}
      }, store, refresh_if_stub: true)

    forest_uuid =
      ensure_room(root_uuid, "forest-path", %Room{
        name: "A Forest Path",
        description: "Tall oaks line a winding dirt path. The Start Room lies south.",
        exits: %{}
      }, store)

    clearing_uuid =
      ensure_room(root_uuid, "clearing", %Room{
        name: "A Sunlit Clearing",
        description: "A grassy clearing dappled with sunlight. The Start Room lies west.",
        exits: %{}
      }, store)

    merge_exits(start_uuid, %{"north" => forest_uuid, "east" => clearing_uuid}, store)
    merge_exits(forest_uuid, %{"south" => start_uuid}, store)
    merge_exits(clearing_uuid, %{"west" => start_uuid}, store)

    ensure_object(start_uuid, "cloak.obj", %Object{
      name: "cloak",
      aliases: ["cape", "black cloak"],
      description: "A heavy black cloak. It looks warm."
    }, store)

    ensure_object(clearing_uuid, "fountain.obj", %Object{
      name: "fountain",
      aliases: ["water"],
      description: "A stone fountain murmurs softly.",
      fixed: true,
      tick_interval_ms: 8_000,
      tick_message: "The fountain burbles softly."
    }, store)

    {:ok, :ready}
  end

  ## Private

  defp ensure_room(parent_uuid, name, %Room{} = canonical, store, opts \\ []) do
    refresh_if_stub = Keyword.get(opts, :refresh_if_stub, false)
    {:ok, parent_schema} = Schemas.load_dir_schema(parent_uuid, store)

    case Schema.get_entry(parent_schema, name) do
      {:ok, %Schema.Entry{node_id: room_uuid}} ->
        if refresh_if_stub do
          maybe_refresh_room(room_uuid, canonical, store)
        end

        room_uuid

      :error ->
        room_uuid =
          Schemas.create_dir_with_meta(
            Schemas.room_filename(),
            Schemas.encode_room(canonical),
            store
          )

        :ok = add_dir_entry(parent_uuid, name, room_uuid, store)
        room_uuid
    end
  end

  defp maybe_refresh_room(room_uuid, %Room{} = canonical, store) do
    case Schemas.load_room(room_uuid, store) do
      {:ok, %Room{description: desc} = current} when desc in @stub_descriptions ->
        merged = %Room{
          name: canonical.name,
          description: canonical.description,
          exits: current.exits,
          tick_interval_ms: current.tick_interval_ms,
          tick_message: current.tick_message
        }

        write_room(room_uuid, merged, store)

      _ ->
        :ok
    end
  end

  defp ensure_object(parent_uuid, filename, %Object{} = canonical, store) do
    {:ok, parent_schema} = Schemas.load_dir_schema(parent_uuid, store)

    case Schema.get_entry(parent_schema, filename) do
      {:ok, _} ->
        :ok

      :error ->
        obj_uuid =
          Schemas.create_dir_with_meta(
            Schemas.object_filename(),
            Schemas.encode_object(canonical),
            store
          )

        :ok = add_dir_entry(parent_uuid, filename, obj_uuid, store)
        :ok
    end
  end

  defp merge_exits(room_uuid, exits, store) do
    case Schemas.load_room(room_uuid, store) do
      {:ok, %Room{} = room} ->
        new_exits = Map.merge(exits, room.exits)
        write_room(room_uuid, %Room{room | exits: new_exits}, store)

      _ ->
        :ok
    end
  end

  defp write_room(room_dir_uuid, %Room{} = room, store) do
    {:ok, schema} = Schemas.load_dir_schema(room_dir_uuid, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.room_filename())
    :ok = Schemas.write_meta_doc(entry.node_id, Schemas.encode_room(room), store)
    :ok
  end

  defp add_dir_entry(parent_uuid, name, child_uuid, store) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_directory(schema, name, child_uuid)
    update = Encoding.encode_update(schema)
    CommitStoreClient.create_chained_commit(store, parent_uuid, update)
    :ok
  end
end
