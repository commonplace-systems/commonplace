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

  alias Commonplace.Code.SourceDoc
  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.Schemas
  alias Commonplace.MUD.Schemas.{Object, Recipe, Room}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.{Doc, Encoding}

  # CX-cj3t (items epic phase 2, MINE) — the seed vein's yield-spec
  # template. Node-signed at creation (see `ensure_vein/4`) so it plays
  # under `local_write_gate: :enforce` the same way the cloak/fountain
  # bootstrap objects do for TAKE.
  @iron_ore_template %{
    "name" => "iron ore",
    "aliases" => ["ore"],
    "description" => "A rough chunk of iron ore."
  }

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

  # CX-2xez (MUD-as-documents Inc-1): the doc-hosted command parser. A FIXED
  # uuid so the seed is idempotent across boots and the manifest (trust root)
  # is stable. The source is node-signed at seed time so `SourceDoc.compile`'s
  # Gate B grants `:execute`. It is a DISTINCT module name from the compiled-in
  # floor (`Commonplace.MUD.Parser`) so a doc compile never purges the floor.
  # Behaviour mirrors `Parser.parse/1` exactly (the floor) and RETURNS the
  # kernel-defined `%Commonplace.MUD.Parser.Command{}` (a data contract it
  # references, not owns). Editing this doc hot-reloads the grammar live.
  @engine_parser_uuid "aa11bb22-cc33-4d44-8e55-ff6677889900"

  @engine_parser_source ~S'''
  defmodule Commonplace.MUD.EngineParser do
    @moduledoc "Doc-hosted MUD command parser (CX-2xez Inc-1). Hot-editable."

    @direction_aliases %{
      "n" => "north",
      "s" => "south",
      "e" => "east",
      "w" => "west",
      "u" => "up",
      "d" => "down"
    }

    @verb_aliases Map.merge(@direction_aliases, %{
                    "i" => "inventory",
                    "inv" => "inventory",
                    "l" => "look",
                    "'" => "say",
                    "\"" => "say"
                  })

    def parse(line) when is_binary(line) do
      line = String.trim(line)

      case line do
        "" ->
          %Commonplace.MUD.Parser.Command{}

        <<"'", rest::binary>> when rest != "" ->
          %Commonplace.MUD.Parser.Command{verb: "say", args: rest, argv: [rest], target: nil}

        _ ->
          {verb_word, args} = split_first(line)
          verb = Map.get(@verb_aliases, String.downcase(verb_word), String.downcase(verb_word))
          argv = if args == "", do: [], else: String.split(args, ~r/\s+/, trim: true)
          target = List.first(argv)
          %Commonplace.MUD.Parser.Command{verb: verb, args: args, argv: argv, target: target}
      end
    end

    defp split_first(line) do
      case String.split(line, ~r/\s+/, parts: 2) do
        [verb] -> {verb, ""}
        [verb, rest] -> {verb, rest}
      end
    end
  end
  '''

  # CX-aya0 (MUD-as-documents Inc-2 / B1): the first doc-hosted MUD verb.
  # `look` is PURE (read + format, zero tree writes) — the lowest-blast-
  # radius verb, chosen to prove the `EngineModule.run_verb/4` mechanism
  # before broadening to the rest of the stateless-leaf cohort (B2). Fixed
  # uuid + node-signed at seed time, same idempotent-seed shape as
  # `@engine_parser_uuid` above (see that constant's comment for the
  # Gate B / distinct-module-name rationale — identical here).
  #
  # SCOPE (deliberately partial — not a regression): this doc implements
  # only the two PURE-lookup cases of `look` (bare `look` / `look here` /
  # `look room`, and `look me` / `look self` / `look myself`) — the two
  # cases exercised by the parity test below. Every other `look` subcommand
  # (`look <object>`, `look in <container>`) has no matching `run/2` clause
  # in this doc, so it raises `FunctionClauseError` — which
  # `EngineModule.run_verb/4`'s crash containment catches and falls back to
  # the compiled-in floor (`Commonplace.MUD.Verbs.LookFloor`, full
  # `do_look/2` parity) for THAT call. This is the non-brick tier-3 path
  # doing real work, not a gap: broadening this doc to full parity (or
  # replacing it) is B2 scope, not B1's "prove the mechanism" bar.
  @engine_look_verb_uuid "100ca11b-1004-4e55-9f66-a07788990011"

  @engine_look_verb_source ~S'''
  defmodule Commonplace.MUD.EngineLook do
    @moduledoc "Doc-hosted `look` verb (CX-aya0, MUD-as-documents Inc-2 / B1). Hot-editable."

    alias Commonplace.MUD.Schemas
    alias Commonplace.MUD.Schemas.Player
    alias Commonplace.MUD.World

    def run(%Commonplace.MUD.Parser.Command{argv: []}, ctx), do: {:reply, render_room(ctx)}

    def run(%Commonplace.MUD.Parser.Command{target: target}, ctx) when target in ["here", "room"] do
      {:reply, render_room(ctx)}
    end

    def run(%Commonplace.MUD.Parser.Command{target: target}, ctx) when target in ["me", "self", "myself"] do
      case Schemas.load_player(ctx.player_dir_uuid, ctx.store) do
        {:ok, %Player{} = pl} ->
          title = if pl.title == "", do: pl.name, else: pl.title
          {:reply, "#{title}\n#{pl.description}"}

        _ ->
          {:reply, ctx.player_name}
      end
    end

    defp render_room(ctx) do
      case World.room_snapshot(ctx.current_room_uuid, ctx.presence_filename, ctx.store, viewer: identity(ctx)) do
        {:ok, %{name: name, desc: desc, exits: exits, contents: objects, occupants: players}} ->
          exit_dirs = Enum.map(exits, fn {dir, _to} -> dir end)

          IO.iodata_to_binary([
            "== ", name, " ==\n",
            desc, "\n",
            if(exit_dirs == [], do: "Exits: (none)\n", else: ["Exits: ", Enum.join(exit_dirs, ", "), "\n"]),
            if(objects == [], do: "", else: ["You see: ", Enum.join(objects, ", "), "\n"]),
            if(players == [], do: "", else: ["Players: ", Enum.join(players, ", "), "\n"])
          ])

        {:error, :read_denied} ->
          "That place is private."

        {:error, _} ->
          "(this place has no description)"
      end
    end

    defp identity(ctx) do
      case ctx[:signing_context] do
        %{identity_uuid: id} when is_binary(id) -> id
        _ -> nil
      end
    end
  end
  '''

  # CX-aya0 (MUD-as-documents Inc-2 / B2): the next stateless-leaf verbs
  # doc-hosted after `look` (B1) — `inventory` (pure read + format, zero
  # tree writes) and `say`/`emote` (pure `World.broadcast_room` PubSub
  # broadcast, zero tree writes). Same fixed-uuid + node-signed idempotent
  # seed shape as `@engine_look_verb_uuid` above (see that constant's
  # comment for the Gate B / distinct-module-name rationale — identical
  # here). Unlike `look`'s deliberately partial doc (B1 only proved the
  # mechanism), these three doc bodies are FULL parity with their
  # `do_*` counterparts — each verb's compiled-in logic is simple enough
  # that mirroring it completely in the seed doc costs nothing extra.
  @engine_inventory_verb_uuid "200da22c-2005-4f66-a077-b18899001122"

  @engine_inventory_verb_source ~S'''
  defmodule Commonplace.MUD.EngineInventory do
    @moduledoc "Doc-hosted `inventory` verb (CX-aya0, MUD-as-documents Inc-2 / B2). Hot-editable."

    alias Commonplace.MUD.Schemas
    alias Commonplace.MUD.Schemas.Object
    alias Commonplace.MUD.World

    def run(_cmd, ctx) do
      items =
        World.list_objects_in(ctx.inventory_uuid, ctx.store)
        |> Enum.map(fn e ->
          case Schemas.load_object(e.node_id, ctx.store) do
            {:ok, %Object{name: name}} -> name
            _ -> e.name
          end
        end)

      text =
        case items do
          [] -> "You are carrying nothing."
          _ -> "You are carrying:\n  - " <> Enum.join(items, "\n  - ")
        end

      {:reply, text}
    end
  end
  '''

  @engine_emote_verb_uuid "300eb33d-3006-4a77-b188-c29900112233"

  @engine_emote_verb_source ~S'''
  defmodule Commonplace.MUD.EngineEmote do
    @moduledoc "Doc-hosted `emote` verb (CX-aya0, MUD-as-documents Inc-2 / B2). Hot-editable."

    alias Commonplace.MUD.World

    def run(%Commonplace.MUD.Parser.Command{args: ""}, _ctx), do: {:error, "Emote what?"}

    def run(%Commonplace.MUD.Parser.Command{args: text}, ctx) do
      World.broadcast_room(ctx.current_room_uuid, %{kind: :emote, who: ctx.player_name, text: text})
      :ok
    end
  end
  '''

  @engine_say_verb_uuid "400fc44e-4007-4b88-c299-d3a011223344"

  @engine_say_verb_source ~S'''
  defmodule Commonplace.MUD.EngineSay do
    @moduledoc "Doc-hosted `say` verb (CX-aya0, MUD-as-documents Inc-2 / B2). Hot-editable."

    alias Commonplace.MUD.World

    def run(%Commonplace.MUD.Parser.Command{args: ""}, _ctx), do: {:error, "Say what?"}

    def run(%Commonplace.MUD.Parser.Command{args: text}, ctx) do
      World.broadcast_room(ctx.current_room_uuid, %{kind: :say, who: ctx.player_name, text: text})
      :ok
    end
  end
  '''

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
    # CX-2xez: seed the doc-hosted parser + point the engine manifest at it
    # FIRST and independently — it's node-signed + standalone (no tree
    # linkage), and best-effort (always returns :ok), so it can never block or
    # be blocked by the room-seed chain, and a failure just leaves
    # `EngineModule` on its compiled-in floor (never bricks).
    :ok = ensure_engine_parser(store)

    # CX-aya0 (B1): same best-effort, never-blocks shape as the parser
    # seed above — seed the doc-hosted `look` verb + point the manifest at
    # it. A failure just leaves `EngineModule.run_verb(:look, ...)` on the
    # compiled-in floor (`Commonplace.MUD.Verbs.LookFloor`, full parity).
    :ok = ensure_engine_look_verb(store)

    # CX-aya0 (B2): same best-effort, never-blocks shape — seed the
    # doc-hosted `inventory`/`emote`/`say` verbs + point the manifest at
    # them. A failure just leaves `EngineModule.run_verb/4` on the
    # respective compiled-in floor (full `do_*` parity).
    :ok = ensure_engine_inventory_verb(store)
    :ok = ensure_engine_emote_verb(store)
    :ok = ensure_engine_say_verb(store)

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
         :ok <- ensure_movable_objects_once(root_uuid, start_uuid, clearing_uuid, store),
         :ok <- ensure_vein(forest_uuid, "iron-vein.obj", iron_vein(), store),
         :ok <- ensure_recipes(root_uuid, store) do
      {:ok, :ready}
    end
  end

  ## Private

  # CX-2xez (MUD-as-documents Inc-1): idempotently seed the node-signed parser
  # source doc at the fixed uuid + set the engine manifest (the trust root) to
  # point at it. Best-effort by construction: any failure (no node identity,
  # write refused, whatever) just returns :ok and leaves EngineModule on its
  # compiled-in floor — the doc-hosted path is strictly additive and must
  # never brick or block seeding.
  @doc false
  def ensure_engine_parser(store \\ CommitStoreClient) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context() do
      unless source_doc_present?(@engine_parser_uuid, store) do
        seed_source_doc(@engine_parser_uuid, @engine_parser_source, node_ctx, store)
      end

      # The manifest is a TRUST ROOT — node-controlled app-env, never player
      # input. Pointing it here is what says "THIS doc is the parser".
      manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
      Application.put_env(:commonplace, :mud_engine_manifest, Map.put(manifest, :parser, @engine_parser_uuid))
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # CX-aya0 (B1): idempotently seed the node-signed `look` verb source doc
  # + set the engine manifest's `:look` entry. Mirrors
  # `ensure_engine_parser/1` exactly (best-effort, rescues/catches to `:ok`
  # on any failure — no node identity, write refused, whatever — so the
  # doc-hosted `look` path is strictly additive and can never brick or
  # block seeding; `EngineModule` just stays on the compiled-in floor).
  @doc false
  def ensure_engine_look_verb(store \\ CommitStoreClient) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context() do
      unless source_doc_present?(@engine_look_verb_uuid, store) do
        seed_source_doc(@engine_look_verb_uuid, @engine_look_verb_source, node_ctx, store, "_engine_look.ex")
      end

      manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
      Application.put_env(:commonplace, :mud_engine_manifest, Map.put(manifest, :look, @engine_look_verb_uuid))
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # CX-aya0 (B2): idempotently seed the node-signed `inventory` verb source
  # doc + set the engine manifest's `:inventory` entry. Mirrors
  # `ensure_engine_look_verb/1` exactly (best-effort, rescues/catches to
  # `:ok` on any failure — no node identity, write refused, whatever — so
  # the doc-hosted `inventory` path is strictly additive and can never
  # brick or block seeding; `EngineModule` just stays on the compiled-in
  # floor).
  @doc false
  def ensure_engine_inventory_verb(store \\ CommitStoreClient) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context() do
      unless source_doc_present?(@engine_inventory_verb_uuid, store) do
        seed_source_doc(@engine_inventory_verb_uuid, @engine_inventory_verb_source, node_ctx, store, "_engine_inventory.ex")
      end

      manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
      Application.put_env(:commonplace, :mud_engine_manifest, Map.put(manifest, :inventory, @engine_inventory_verb_uuid))
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # CX-aya0 (B2): idempotently seed the node-signed `emote` verb source
  # doc + set the engine manifest's `:emote` entry. Mirrors
  # `ensure_engine_look_verb/1` exactly.
  @doc false
  def ensure_engine_emote_verb(store \\ CommitStoreClient) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context() do
      unless source_doc_present?(@engine_emote_verb_uuid, store) do
        seed_source_doc(@engine_emote_verb_uuid, @engine_emote_verb_source, node_ctx, store, "_engine_emote.ex")
      end

      manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
      Application.put_env(:commonplace, :mud_engine_manifest, Map.put(manifest, :emote, @engine_emote_verb_uuid))
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # CX-aya0 (B2): idempotently seed the node-signed `say` verb source
  # doc + set the engine manifest's `:say` entry. Mirrors
  # `ensure_engine_look_verb/1` exactly.
  @doc false
  def ensure_engine_say_verb(store \\ CommitStoreClient) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context() do
      unless source_doc_present?(@engine_say_verb_uuid, store) do
        seed_source_doc(@engine_say_verb_uuid, @engine_say_verb_source, node_ctx, store, "_engine_say.ex")
      end

      manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
      Application.put_env(:commonplace, :mud_engine_manifest, Map.put(manifest, :say, @engine_say_verb_uuid))
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp source_doc_present?(uuid, store) do
    match?({:ok, _source, _hash}, SourceDoc.read(uuid, store))
  end

  # `filename` defaults to the parser doc's original hardcoded name — every
  # pre-existing call site (just `ensure_engine_parser/1`) omits the arg and
  # is byte-for-byte unchanged; `ensure_engine_look_verb/1` passes its own.
  defp seed_source_doc(uuid, source, node_ctx, store, filename \\ "_engine_parser.ex") do
    doc =
      Doc.new()
      |> ContentType.create(:text, filename)
      |> ContentType.insert_text(0, source)

    update = Encoding.encode_update(doc)
    CommitStoreClient.create_commit(store, uuid, update, nil, %{}, signing_context: node_ctx)
  end

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

  # CX-cj3t (items epic phase 2) — the seed vein, node-signed at creation
  # (see `ensure_vein/4`) so a mine plays under `local_write_gate:
  # :enforce`, mirroring how the cloak/fountain are node-signed for TAKE.
  # `fixed: true` so the vein itself can never be TAKEn — only MINEd.
  defp iron_vein do
    %Object{
      name: "iron vein",
      aliases: ["vein", "iron"],
      description: "A vein of raw iron runs through the rock here.",
      fixed: true,
      kind: "vein",
      yield_type: @iron_ore_template,
      yield_max: 5,
      # CX-znwh — regen ~1 ore / 30s (lazy, computed per-mine as
      # floor(elapsed_ms * regen_per_ms), capped at yield_max). Was 0 =
      # permanent depletion, which world-cumulatively starved newcomers of the
      # 2 ore the only recipe needs (the mine→smith loop the room advertises).
      # A slow regen keeps the resource meaningful while making it renewable.
      regen_per_ms: 1 / 30_000,
      yield_remaining: 5,
      last_regen_at: 0
    }
  end

  # A vein is room-structural like a room itself (never wanders — it is
  # `fixed: true`, un-takeable), so it's gated on simple presence-under-
  # name, not the seed-once marker `ensure_movable_objects_once` uses for
  # movable bootstrap objects. NODE-SIGNED (unlike `ensure_object/4`'s
  # unsigned bootstrap writes) so the vein plays under `:enforce` — a
  # player's `mine` runs the vein-write ELEVATED against this doc, which
  # only succeeds if the doc is genuinely node-owned.
  defp ensure_vein(parent_uuid, filename, %Object{} = canonical, store) do
    {:ok, parent_schema} = Schemas.load_dir_schema(parent_uuid, store)

    case Schema.get_entry(parent_schema, filename) do
      {:ok, _} ->
        :ok

      :error ->
        with {:ok, node_ctx} <- NodeIdentity.signing_context(),
             node_opts = [signing_context: node_ctx, cert_cids: []],
             {:ok, vein_uuid} <-
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

  # CX-cj3t (items epic phase 2, SMITH) — the seed recipe, node-signed at
  # creation so it plays under `:enforce` (a player can't author one — its
  # authorship is the anti-forgery root). "iron ingot" ← 2× "iron ore"
  # (the iron vein's yield). Lives under `root/__recipes/` where
  # `Mint.smith`/`recipes` resolve it.
  @iron_ingot_template %{
    "name" => "iron ingot",
    "aliases" => ["ingot"],
    "description" => "A sturdy bar of smelted iron."
  }

  defp iron_ingot_recipe do
    %Recipe{
      name: "iron ingot",
      inputs: [%{"type" => "iron ore", "qty" => 2}],
      output: @iron_ingot_template,
      station: nil
    }
  end

  defp ensure_recipes(root_uuid, store) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context(),
         node_opts = [signing_context: node_ctx, cert_cids: []],
         {:ok, recipes_dir} <- ensure_child_dir(root_uuid, "__recipes", store, node_opts) do
      ensure_recipe(recipes_dir, "iron-ingot", iron_ingot_recipe(), store, node_opts)
    end
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

  defp add_dir_entry(parent_uuid, name, child_uuid, store, opts \\ []) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_directory(schema, name, child_uuid)
    update = Encoding.encode_update(schema)
    {metadata, commit_opts} = Commonplace.MUD.SignedWrite.opts_for(parent_uuid, Keyword.put(opts, :store, store))

    case CommitStoreClient.create_chained_commit(store, parent_uuid, update, metadata, commit_opts) do
      {:error, _} = err -> err
      _commit -> :ok
    end
  end
end
