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
        .mud-seeded/     seed-once marker (see CX-k8lq)

  CX-k8lq: rooms/exits are STRUCTURAL — keyed by name under a fixed
  parent, they never move, so re-running `ensure_room`/`merge_exits`
  every call (including every login) stays correct and idempotent.
  Bootstrap objects (cloak, fountain) are MOVABLE — once a player TAKEs
  one, it leaves its seed room's schema entirely, so "is this filename
  present in the room" is no longer a valid "does the world have one of
  these" check; re-running it would mint a duplicate and orphan any
  player-authored state (verbs) on the original. Movable-object seeding
  therefore runs at most ONCE per world, gated on the `@seed_marker`
  entry under `root_uuid` — present means "movable objects already
  placed, do not re-place them", regardless of where those objects have
  since wandered.
  """

  alias Commonplace.MUD.Schemas
  alias Commonplace.MUD.Schemas.{Object, Room}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  @stub_descriptions [
    "A featureless white room. The world has not been built out yet."
  ]

  # CX-k8lq: seed-once marker for movable bootstrap objects. A plain
  # entry under the world root — its mere presence means "movable
  # objects have already been placed for this world, do not place them
  # again". Named with a leading dot + no extension so it never matches
  # room-name lookups (`ensure_room`/`ensure_start_room` key on exact
  # name) or `.obj`/`.usr` suffix filters used elsewhere to list room
  # contents/players.
  @seed_marker ".mud-seeded"

  def seed(root_uuid, store \\ CommitStoreClient), do: repair(root_uuid, store)

  # CX-93ea: every step is a `with` link now — a rejected write (trust
  # gate under `:enforce`, or any other create_commit error) stops the
  # seed/repair sequence at that step and returns `{:error, reason}`
  # instead of silently reporting `{:ok, :ready}` over a half-built
  # world. No rollback of steps that already landed (append-only store,
  # no rollback exists) — a mid-sequence denial can leave some
  # rooms/objects created and others not; re-running `repair/2` is
  # idempotent and will pick up where it left off.
  def repair(root_uuid, store \\ CommitStoreClient) do
    with {:ok, start_uuid} <-
           ensure_room(root_uuid, "start", %Room{
             name: "The Start Room",
             description: "A cozy stone chamber. Exits lead north and east.",
             exits: %{}
           }, store, refresh_if_stub: true),
         {:ok, forest_uuid} <-
           ensure_room(root_uuid, "forest-path", %Room{
             name: "A Forest Path",
             description: "Tall oaks line a winding dirt path. The Start Room lies south.",
             exits: %{}
           }, store),
         {:ok, clearing_uuid} <-
           ensure_room(root_uuid, "clearing", %Room{
             name: "A Sunlit Clearing",
             description: "A grassy clearing dappled with sunlight. The Start Room lies west.",
             exits: %{}
           }, store),
         :ok <- merge_exits(start_uuid, %{"north" => forest_uuid, "east" => clearing_uuid}, store),
         :ok <- merge_exits(forest_uuid, %{"south" => start_uuid}, store),
         :ok <- merge_exits(clearing_uuid, %{"west" => start_uuid}, store),
         :ok <- ensure_movable_objects_once(root_uuid, start_uuid, clearing_uuid, store) do
      {:ok, :ready}
    end
  end

  ## Private

  # CX-k8lq: place the seed-once movable objects (cloak, fountain) IFF
  # the world has never been seeded before. Checked against a marker
  # under `root_uuid`, not against "is the object still in its seed
  # room" — the latter is exactly the bug (a taken cloak reads as
  # "missing" and gets re-minted). Once objects are placed, the marker
  # is written so every subsequent call (every login, every repair) is
  # a single cheap entry lookup that no-ops.
  defp ensure_movable_objects_once(root_uuid, start_uuid, clearing_uuid, store) do
    {:ok, root_schema} = Schemas.load_dir_schema(root_uuid, store)

    case Schema.get_entry(root_schema, @seed_marker) do
      {:ok, _entry} ->
        :ok

      :error ->
        with :ok <-
               ensure_object(start_uuid, "cloak.obj", %Object{
                 name: "cloak",
                 aliases: ["cape", "black cloak"],
                 description: "A heavy black cloak. It looks warm."
               }, store),
             :ok <-
               ensure_object(clearing_uuid, "fountain.obj", %Object{
                 name: "fountain",
                 aliases: ["water"],
                 description: "A stone fountain murmurs softly.",
                 fixed: true,
                 tick_interval_ms: 8_000,
                 tick_message: "The fountain burbles softly."
               }, store) do
          mark_seeded(root_uuid, store)
        end
    end
  end

  defp mark_seeded(root_uuid, store) do
    with {:ok, marker_uuid} <- Schemas.create_dir_with_meta(nil, nil, store) do
      add_dir_entry(root_uuid, @seed_marker, marker_uuid, store)
    end
  end

  defp ensure_room(parent_uuid, name, %Room{} = canonical, store, opts \\ []) do
    refresh_if_stub = Keyword.get(opts, :refresh_if_stub, false)
    {:ok, parent_schema} = Schemas.load_dir_schema(parent_uuid, store)

    case Schema.get_entry(parent_schema, name) do
      {:ok, %Schema.Entry{node_id: room_uuid}} ->
        if refresh_if_stub do
          case maybe_refresh_room(room_uuid, canonical, store) do
            :ok -> {:ok, room_uuid}
            {:error, _} = err -> err
          end
        else
          {:ok, room_uuid}
        end

      :error ->
        with {:ok, room_uuid} <-
               Schemas.create_dir_with_meta(
                 Schemas.room_filename(),
                 Schemas.encode_room(canonical),
                 store
               ),
             :ok <- add_dir_entry(parent_uuid, name, room_uuid, store) do
          {:ok, room_uuid}
        end
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
        with {:ok, obj_uuid} <-
               Schemas.create_dir_with_meta(
                 Schemas.object_filename(),
                 Schemas.encode_object(canonical),
                 store
               ) do
          add_dir_entry(parent_uuid, filename, obj_uuid, store)
        end
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
    Schemas.write_meta_doc(entry.node_id, Schemas.encode_room(room), store)
  end

  defp add_dir_entry(parent_uuid, name, child_uuid, store) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_directory(schema, name, child_uuid)
    update = Encoding.encode_update(schema)

    case CommitStoreClient.create_chained_commit(store, parent_uuid, update) do
      {:error, _} = err -> err
      _commit -> :ok
    end
  end
end
