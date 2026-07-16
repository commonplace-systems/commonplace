defmodule Commonplace.MUD.SeedWorld do
  @moduledoc """
  CX-lr73 (self-hosting slice 2, part A) — the MUD seed world (3 rooms +
  exits, the cloak/fountain bootstrap objects, the iron vein, the
  iron-ingot recipe) as an IMPORTED data bundle instead of Elixir
  literals.

  The content itself lives in `priv/mud_seed_world.json`, loaded at
  COMPILE time (`@external_resource` + `File.read!` + `Jason.decode!`
  into module attributes) — a malformed bundle fails the BUILD, not a
  runtime call, and there is no runtime file dependency (the compiled
  beam carries the content). `import/2` is the idempotent IMPORTER this
  module now owns; `Commonplace.MUD.Bootstrap.repair/2` just calls it —
  the content itself moved here wholesale from `Bootstrap` (this module
  is now also the sole owner of the seed-once/idempotence machinery
  those literals depended on: `ensure_room`/`maybe_refresh_room`,
  `ensure_object`/`ensure_movable_objects_once`/`mark_seeded`,
  `ensure_vein`, `ensure_recipes`/`ensure_child_dir`/`ensure_recipe`,
  `merge_exits`/`write_room`, `add_dir_entry`).

  ## Two deliberate fixes over the pre-CX-lr73 behavior

  1. **Node-signing (CX-g5lb(a)/(b), CX-nd49).** Every write this module
     makes is node-signed when a node identity is available
     (`Commonplace.Crypto.NodeIdentity.signing_context/0`), so seeding
     lands under `local_write_gate: :enforce` — previously only the vein
     and recipe writes were node-signed; the rooms/exits and the
     cloak/fountain objects were unsigned and would be refused under
     `:enforce`. Falls back to unsigned (today's permissive-test
     behavior) if no node signer resolves.

  2. **Phase decoupling (CX-g5lb(b)).** The four content phases — rooms
     + exits, movable objects, the vein, the recipes — are each
     resolved INDEPENDENTLY (by looking up a room's uuid by name under
     `root_uuid` fresh, never by threading a prior phase's return
     value) and ALL FOUR RUN even if an earlier phase errored. Previously
     a `with`-chain meant a denied room-exit write (say) skipped vein and
     recipe seeding entirely — an exit-write denial could no longer skip
     the smith/mine loop's seeding. `import/2` still honors CX-93ea's
     honest-error contract: it returns `{:ok, :ready}` only if every
     phase was clean, else the FIRST phase's error (append-only store,
     no rollback — whatever landed, landed; re-running `import/2` is
     idempotent and picks up where it left off, same as `Bootstrap.repair/2`
     always was).

  ## Idempotence keys (byte-identical to pre-CX-lr73 `Bootstrap`)

    * Rooms — presence of the entry-name under `root_uuid`; `start`
      additionally refreshes a STUB description (CX-93ea).
    * Movable objects (cloak, fountain) — the `@seed_marker` once-gate
      under `root_uuid` (CX-k8lq: a taken object must never be
      re-minted).
    * The vein — presence-under-name in its room (structural, `fixed:
      true`, never wanders).
    * The recipe — presence-under-name in `root/__recipes/`.
  """

  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.MUD.Schemas
  alias Commonplace.MUD.Schemas.{Object, Recipe, Room}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  @external_resource Path.join([__DIR__, "..", "..", "..", "priv", "mud_seed_world.json"])
  @seed_bundle @external_resource |> File.read!() |> Jason.decode!()

  @rooms Map.fetch!(@seed_bundle, "rooms")
  @objects Map.fetch!(@seed_bundle, "objects")
  @veins Map.fetch!(@seed_bundle, "veins")
  @recipes Map.fetch!(@seed_bundle, "recipes")

  # CX-k8lq: seed-once marker for movable bootstrap objects — moved
  # verbatim from `Bootstrap` (see that module's moduledoc, "Layout").
  @seed_marker ".mud-seeded"

  @stub_descriptions [
    "A featureless white room. The world has not been built out yet."
  ]

  @doc """
  Idempotently import the seed-world bundle under `root_uuid`. Runs all
  four content phases (rooms+exits, movable objects, veins, recipes)
  regardless of any individual phase's outcome; returns `{:ok, :ready}`
  iff all four were clean, else the FIRST phase's `{:error, reason}`.
  """
  @spec import(String.t(), GenServer.server()) :: {:ok, :ready} | {:error, term()}
  def import(root_uuid, store \\ CommitStoreClient) do
    node_opts = node_opts()

    run_phases([
      fn -> ensure_rooms_and_exits(root_uuid, store, node_opts) end,
      fn -> ensure_movable_objects_once(root_uuid, store, node_opts) end,
      fn -> ensure_veins(root_uuid, store, node_opts) end,
      fn -> ensure_recipes(root_uuid, store, node_opts) end
    ])
  end

  # CX-g5lb(b): the generic phase-decoupling runner — every thunk is
  # invoked UNCONDITIONALLY (a plain `Enum.map`, not a `with`/reduce_while
  # that would short-circuit), so one phase's `{:error, _}` can never
  # skip a later phase. Returns `{:ok, :ready}` iff every phase was
  # clean, else the FIRST phase's error (CX-93ea's honest-error
  # contract, generalized across phases instead of within one). Public
  # (`@doc false`) so the decoupling contract itself is unit-testable
  # with synthetic thunks, independent of any real write/trust plumbing.
  @doc false
  @spec run_phases([(-> :ok | {:ok, term()} | {:error, term()})]) ::
          {:ok, :ready} | {:error, term()}
  def run_phases(phase_thunks) do
    results = Enum.map(phase_thunks, & &1.())

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, :ready}
      error -> error
    end
  end

  ## Node-signing (CX-g5lb(a)/(b), CX-nd49)

  defp node_opts do
    case NodeIdentity.signing_context() do
      {:ok, ctx} -> [signing_context: ctx, cert_cids: []]
      _ -> []
    end
  end

  ## Phase 1: rooms + exits

  defp ensure_rooms_and_exits(root_uuid, store, node_opts) do
    with {:ok, uuids} <- ensure_all_rooms(root_uuid, store, node_opts) do
      merge_all_exits(uuids, store, node_opts)
    end
  end

  defp ensure_all_rooms(root_uuid, store, node_opts) do
    Enum.reduce_while(@rooms, {:ok, %{}}, fn {key, spec}, {:ok, acc} ->
      opts = if spec["refresh_if_stub"], do: [refresh_if_stub: true], else: []

      case ensure_room(root_uuid, key, room_from_spec(spec), store, node_opts, opts) do
        {:ok, uuid} -> {:cont, {:ok, Map.put(acc, key, uuid)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp room_from_spec(spec) do
    %Room{
      name: Map.fetch!(spec, "name"),
      description: Map.fetch!(spec, "description"),
      exits: %{}
    }
  end

  defp merge_all_exits(uuids, store, node_opts) do
    Enum.reduce_while(@rooms, :ok, fn {key, spec}, :ok ->
      with {:ok, room_uuid} <- Map.fetch(uuids, key),
           exits <- resolve_exits(Map.get(spec, "exits", %{}), uuids) do
        case merge_exits(room_uuid, exits, store, node_opts) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      else
        :error -> {:cont, :ok}
      end
    end)
  end

  defp resolve_exits(exits_spec, uuids) do
    exits_spec
    |> Enum.map(fn {dir, room_key} -> {dir, Map.get(uuids, room_key)} end)
    |> Enum.reject(fn {_dir, uuid} -> is_nil(uuid) end)
    |> Map.new()
  end

  defp ensure_room(parent_uuid, name, %Room{} = canonical, store, node_opts, opts) do
    refresh_if_stub = Keyword.get(opts, :refresh_if_stub, false)
    {:ok, parent_schema} = Schemas.load_dir_schema(parent_uuid, store)

    case Schema.get_entry(parent_schema, name) do
      {:ok, %Schema.Entry{node_id: room_uuid}} ->
        if refresh_if_stub do
          case maybe_refresh_room(room_uuid, canonical, store, node_opts) do
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
                 store,
                 node_opts
               ),
             :ok <- add_dir_entry(parent_uuid, name, room_uuid, store, node_opts) do
          {:ok, room_uuid}
        end
    end
  end

  defp maybe_refresh_room(room_uuid, %Room{} = canonical, store, node_opts) do
    case Schemas.load_room(room_uuid, store) do
      {:ok, %Room{description: desc} = current} when desc in @stub_descriptions ->
        merged = %Room{
          name: canonical.name,
          description: canonical.description,
          exits: current.exits,
          tick_interval_ms: current.tick_interval_ms,
          tick_message: current.tick_message
        }

        write_room(room_uuid, merged, store, node_opts)

      _ ->
        :ok
    end
  end

  defp merge_exits(room_uuid, exits, store, node_opts) do
    case Schemas.load_room(room_uuid, store) do
      {:ok, %Room{} = room} ->
        new_exits = Map.merge(exits, room.exits)
        write_room(room_uuid, %Room{room | exits: new_exits}, store, node_opts)

      _ ->
        :ok
    end
  end

  defp write_room(room_dir_uuid, %Room{} = room, store, node_opts) do
    {:ok, schema} = Schemas.load_dir_schema(room_dir_uuid, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.room_filename())
    Schemas.write_meta_doc(entry.node_id, Schemas.encode_room(room), store, node_opts)
  end

  ## Phase 2: movable objects (cloak, fountain) — seed-once (CX-k8lq)

  defp ensure_movable_objects_once(root_uuid, store, node_opts) do
    {:ok, root_schema} = Schemas.load_dir_schema(root_uuid, store)

    case Schema.get_entry(root_schema, @seed_marker) do
      {:ok, _entry} -> :ok
      :error -> place_movable_objects(root_uuid, store, node_opts)
    end
  end

  defp place_movable_objects(root_uuid, store, node_opts) do
    result =
      Enum.reduce_while(@objects, :ok, fn {room_key, objs}, :ok ->
        case resolve_room_uuid(root_uuid, room_key, store) do
          {:ok, room_uuid} ->
            case place_objects_in_room(room_uuid, objs, store, node_opts) do
              :ok -> {:cont, :ok}
              {:error, _} = err -> {:halt, err}
            end

          {:error, _} = err ->
            {:halt, err}
        end
      end)

    case result do
      :ok -> mark_seeded(root_uuid, store, node_opts)
      err -> err
    end
  end

  defp place_objects_in_room(room_uuid, objs, store, node_opts) do
    Enum.reduce_while(objs, :ok, fn obj_spec, :ok ->
      case ensure_object(room_uuid, object_from_spec(obj_spec), store, node_opts) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp object_from_spec(spec) do
    {Map.fetch!(spec, "filename"), plain_object(spec)}
  end

  defp plain_object(spec) do
    %Object{
      name: Map.fetch!(spec, "name"),
      aliases: Map.get(spec, "aliases", []),
      description: Map.get(spec, "description", ""),
      fixed: Map.get(spec, "fixed", false),
      container?: Map.get(spec, "container", false),
      tick_interval_ms: Map.get(spec, "tick_interval_ms"),
      tick_message: Map.get(spec, "tick_message")
    }
  end

  defp ensure_object(parent_uuid, {filename, %Object{} = canonical}, store, node_opts) do
    {:ok, parent_schema} = Schemas.load_dir_schema(parent_uuid, store)

    case Schema.get_entry(parent_schema, filename) do
      {:ok, _} ->
        :ok

      :error ->
        with {:ok, obj_uuid} <-
               Schemas.create_dir_with_meta(
                 Schemas.object_filename(),
                 Schemas.encode_object(canonical),
                 store,
                 node_opts
               ) do
          add_dir_entry(parent_uuid, filename, obj_uuid, store, node_opts)
        end
    end
  end

  defp mark_seeded(root_uuid, store, node_opts) do
    with {:ok, marker_uuid} <- Schemas.create_dir_with_meta(nil, nil, store, node_opts) do
      add_dir_entry(root_uuid, @seed_marker, marker_uuid, store, node_opts)
    end
  end

  ## Phase 3: veins — structural (fixed: true, never wanders), gated on
  ## simple presence-under-name, node-signed so a `mine` plays under
  ## `:enforce`.

  defp ensure_veins(root_uuid, store, node_opts) do
    Enum.reduce_while(@veins, :ok, fn {room_key, spec}, :ok ->
      with {:ok, room_uuid} <- resolve_room_uuid(root_uuid, room_key, store),
           :ok <- ensure_vein(room_uuid, vein_from_spec(spec), store, node_opts) do
        {:cont, :ok}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp vein_from_spec(spec) do
    {Map.fetch!(spec, "filename"),
     %Object{
       name: Map.fetch!(spec, "name"),
       aliases: Map.get(spec, "aliases", []),
       description: Map.get(spec, "description", ""),
       fixed: Map.get(spec, "fixed", true),
       kind: Map.get(spec, "kind", "vein"),
       yield_type: Map.get(spec, "yield_type"),
       yield_max: Map.get(spec, "yield_max"),
       # Exact-precision regen: computed from the same integer ratio the
       # JSON bundle carries (`regen_per_ms_num / regen_per_ms_denom`),
       # never a lossy literal float in the bundle itself.
       regen_per_ms:
         Map.fetch!(spec, "regen_per_ms_num") / Map.fetch!(spec, "regen_per_ms_denom"),
       yield_remaining: Map.get(spec, "yield_remaining"),
       last_regen_at: Map.get(spec, "last_regen_at")
     }}
  end

  defp ensure_vein(parent_uuid, {filename, %Object{} = canonical}, store, node_opts) do
    {:ok, parent_schema} = Schemas.load_dir_schema(parent_uuid, store)

    case Schema.get_entry(parent_schema, filename) do
      {:ok, _} ->
        :ok

      :error ->
        with {:ok, vein_uuid} <-
               Schemas.create_dir_with_meta(
                 Schemas.object_filename(),
                 Schemas.encode_object(canonical),
                 store,
                 node_opts
               ) do
          add_dir_entry(parent_uuid, filename, vein_uuid, store, node_opts)
        end
    end
  end

  ## Phase 4: recipes — node-signed anti-forgery root (a player can't
  ## author one). Independent of the room phases (lives under
  ## `root/__recipes/`, not under any seed room).

  defp ensure_recipes(root_uuid, store, node_opts) do
    with {:ok, recipes_dir} <- ensure_child_dir(root_uuid, "__recipes", store, node_opts) do
      Enum.reduce_while(@recipes, :ok, fn {filename, spec}, :ok ->
        case ensure_recipe(recipes_dir, filename, recipe_from_spec(spec), store, node_opts) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  defp recipe_from_spec(spec) do
    %Recipe{
      name: Map.fetch!(spec, "name"),
      inputs: Map.get(spec, "inputs", []),
      output: Map.get(spec, "output", %{}),
      station: Map.get(spec, "station")
    }
  end

  defp ensure_child_dir(parent_uuid, name, store, node_opts) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)

    case Schema.get_entry(schema, name) do
      {:ok, entry} ->
        {:ok, entry.node_id}

      :error ->
        with {:ok, dir_uuid} <- Schemas.create_dir_with_meta(nil, nil, store, node_opts),
             :ok <- add_dir_entry(parent_uuid, name, dir_uuid, store, node_opts) do
          {:ok, dir_uuid}
        end
    end
  end

  defp ensure_recipe(parent_uuid, filename, %Recipe{} = recipe, store, node_opts) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)

    case Schema.get_entry(schema, filename) do
      {:ok, _} ->
        :ok

      :error ->
        with {:ok, recipe_uuid} <-
               Schemas.create_dir_with_meta(
                 Schemas.recipe_filename(),
                 Schemas.encode_recipe(recipe),
                 store,
                 node_opts
               ) do
          add_dir_entry(parent_uuid, filename, recipe_uuid, store, node_opts)
        end
    end
  end

  ## Shared

  defp resolve_room_uuid(root_uuid, key, store) do
    with {:ok, schema} <- Schemas.load_dir_schema(root_uuid, store),
         {:ok, entry} <- Schema.get_entry(schema, key) do
      {:ok, entry.node_id}
    else
      _ -> {:error, {:room_not_found, key}}
    end
  end

  defp add_dir_entry(parent_uuid, name, child_uuid, store, node_opts) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_directory(schema, name, child_uuid)
    update = Encoding.encode_update(schema)

    {metadata, commit_opts} =
      Commonplace.MUD.SignedWrite.opts_for(parent_uuid, Keyword.put(node_opts, :store, store))

    case CommitStoreClient.create_chained_commit(
           store,
           parent_uuid,
           update,
           metadata,
           commit_opts
         ) do
      {:error, _} = err -> err
      _commit -> :ok
    end
  end
end
