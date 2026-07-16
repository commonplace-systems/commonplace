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

  CX-lr73 (self-hosting slice 2): the world CONTENT (rooms/exits,
  cloak/fountain, the iron vein, the iron-ingot recipe) is no longer
  hardcoded here — it moved wholesale to `Commonplace.MUD.SeedWorld`
  (an imported `priv/mud_seed_world.json` bundle, node-signed at import
  time). This module's `repair/2` is now an IMPORTER: the engine-verb +
  help/home-template/world-meta doc seeds stay here (see below), and the
  world-content phases delegate to `SeedWorld.import/2` — see that
  module's moduledoc for the idempotence keys (CX-k8lq's `@seed_marker`
  discipline included) and the node-signing / phase-decoupling fixes
  (CX-g5lb/CX-nd49).
  """

  alias Commonplace.Code.SourceDoc
  alias Commonplace.Crypto.NodeIdentity
  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.SeedWorld
  alias Commonplace.Store.CommitStoreClient
  alias Yelixer.{Doc, Encoding}

  # CX-2xez (MUD-as-documents Inc-1): the doc-hosted command parser. A FIXED
  # uuid so the seed is idempotent across boots and the manifest (trust root)
  # is stable. The source is node-signed at seed time so `SourceDoc.compile`'s
  # Gate B grants `:execute`. It is a DISTINCT module name from the compiled-in
  # floor (`Commonplace.MUD.Parser`) so a doc compile never purges the floor.
  # Behaviour mirrors `Parser.parse/1` exactly (the floor) and RETURNS the
  # kernel-defined `%Commonplace.MUD.Parser.Command{}` (a data contract it
  # references, not owns). Editing this doc hot-reloads the grammar live.
  @engine_parser_uuid "aa11bb22-cc33-4d44-8e55-ff6677889900"

  # CX-6pbu (self-hosting slice 3): the source body itself now lives in
  # `priv/engine_verbs/parser.exs.seed`, loaded at COMPILE time (same
  # `@external_resource` + `File.read!` pattern as
  # `Commonplace.MUD.SeedWorld`'s bundle) — the beam carries the content,
  # no runtime priv lookup. Zero behavior change: this is still the
  # doc-hosted parser source seeded (once) into the tree at boot.
  engine_parser_path = Path.join([__DIR__, "..", "..", "..", "priv", "engine_verbs", "parser.exs.seed"])
  @external_resource engine_parser_path
  @engine_parser_source File.read!(engine_parser_path)

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

  # CX-6pbu (self-hosting slice 3): source body moved to
  # `priv/engine_verbs/look.exs.seed` — see the comment on
  # `@engine_parser_source` above for the pattern/rationale.
  engine_look_verb_path = Path.join([__DIR__, "..", "..", "..", "priv", "engine_verbs", "look.exs.seed"])
  @external_resource engine_look_verb_path
  @engine_look_verb_source File.read!(engine_look_verb_path)

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

  # CX-6pbu (self-hosting slice 3): source body moved to
  # `priv/engine_verbs/inventory.exs.seed` — see the comment on
  # `@engine_parser_source` above for the pattern/rationale.
  engine_inventory_verb_path = Path.join([__DIR__, "..", "..", "..", "priv", "engine_verbs", "inventory.exs.seed"])
  @external_resource engine_inventory_verb_path
  @engine_inventory_verb_source File.read!(engine_inventory_verb_path)

  @engine_emote_verb_uuid "300eb33d-3006-4a77-b188-c29900112233"

  # CX-6pbu (self-hosting slice 3): source body moved to
  # `priv/engine_verbs/emote.exs.seed` — see the comment on
  # `@engine_parser_source` above for the pattern/rationale.
  engine_emote_verb_path = Path.join([__DIR__, "..", "..", "..", "priv", "engine_verbs", "emote.exs.seed"])
  @external_resource engine_emote_verb_path
  @engine_emote_verb_source File.read!(engine_emote_verb_path)

  @engine_say_verb_uuid "400fc44e-4007-4b88-c299-d3a011223344"

  # CX-6pbu (self-hosting slice 3): source body moved to
  # `priv/engine_verbs/say.exs.seed` — see the comment on
  # `@engine_parser_source` above for the pattern/rationale.
  engine_say_verb_path = Path.join([__DIR__, "..", "..", "..", "priv", "engine_verbs", "say.exs.seed"])
  @external_resource engine_say_verb_path
  @engine_say_verb_source File.read!(engine_say_verb_path)

  # CX-wkau (MUD-as-documents Inc-1, tranche 1): the six PURE/stateless
  # gameplay-verb baselines (CX-z6ub M2.2) — `where`/`sit`/`stand`/
  # `examine`/`search`/`read` — join the doc-hosted cohort after
  # `look`/`inventory`/`emote`/`say`. Same fixed-uuid + node-signed
  # idempotent seed shape as `@engine_look_verb_uuid` above (see that
  # constant's comment for the Gate B / distinct-module-name rationale —
  # identical here); source bodies load from `priv/engine_verbs/*.exs.seed`
  # at compile time (CX-6pbu shape — see `@engine_parser_source`'s comment).
  # `examine`/`read` are full parity with their `do_*` counterparts via the
  # promoted `Verbs.resolve_target/2` surface (see that function's doc);
  # `where`/`sit`/`stand`/`search` are simple enough to mirror completely.
  @engine_where_verb_uuid "c2c16b7f-3b47-44d5-849f-7d522802a91e"
  engine_where_verb_path = Path.join([__DIR__, "..", "..", "..", "priv", "engine_verbs", "where.exs.seed"])
  @external_resource engine_where_verb_path
  @engine_where_verb_source File.read!(engine_where_verb_path)

  @engine_sit_verb_uuid "9b002b18-37e4-4a31-a869-8849f9906761"
  engine_sit_verb_path = Path.join([__DIR__, "..", "..", "..", "priv", "engine_verbs", "sit.exs.seed"])
  @external_resource engine_sit_verb_path
  @engine_sit_verb_source File.read!(engine_sit_verb_path)

  @engine_stand_verb_uuid "2b5eae29-f49e-4a85-a426-9342ac6c4b4d"
  engine_stand_verb_path = Path.join([__DIR__, "..", "..", "..", "priv", "engine_verbs", "stand.exs.seed"])
  @external_resource engine_stand_verb_path
  @engine_stand_verb_source File.read!(engine_stand_verb_path)

  @engine_examine_verb_uuid "fdcb5f1e-a0f1-4fc3-82dc-1508bdf44b12"
  engine_examine_verb_path = Path.join([__DIR__, "..", "..", "..", "priv", "engine_verbs", "examine.exs.seed"])
  @external_resource engine_examine_verb_path
  @engine_examine_verb_source File.read!(engine_examine_verb_path)

  @engine_search_verb_uuid "0521e66a-d36f-4c25-86bc-3f77c2fccdf8"
  engine_search_verb_path = Path.join([__DIR__, "..", "..", "..", "priv", "engine_verbs", "search.exs.seed"])
  @external_resource engine_search_verb_path
  @engine_search_verb_source File.read!(engine_search_verb_path)

  @engine_read_verb_uuid "61f0cb2f-3676-445e-95ae-ce8585f3ef25"
  engine_read_verb_path = Path.join([__DIR__, "..", "..", "..", "priv", "engine_verbs", "read.exs.seed"])
  @external_resource engine_read_verb_path
  @engine_read_verb_source File.read!(engine_read_verb_path)

  # CX-hbb2 (self-hosting slice A): the in-world `help` text as a node-signed
  # doc, editable without redeploy. Fixed uuid, same idempotent-seed shape as
  # `@engine_parser_uuid`/`@engine_look_verb_uuid` above — but this doc is
  # PLAIN TEXT, not a `defmodule`, so it is read (never compiled) by
  # `Commonplace.MUD.HelpDoc.text/1`, which applies the SAME Gate-B
  # authority walk (`Commonplace.Trust.authorized_to_execute?/2`) as a
  # content-defacement defense before trusting the doc's text. The source
  # here is byte-identical to `HelpDoc.floor/0` (the compiled-in floor) so
  # the seeded doc and the non-brick fallback start in parity.
  @mud_help_uuid "0866de22-43ff-47a1-8215-e00f62f13c1e"

  # CX-gkqk (self-hosting slice 2, part B): the citizenship starter-home
  # room template (name + prose) as a node-signed doc, editable without
  # redeploy. Same idempotent-seed shape as `@mud_help_uuid` — PLAIN TEXT
  # (a JSON body, not a `defmodule`), read via
  # `Commonplace.MUD.HomeTemplate.render/3`, which applies the SAME
  # Gate-B authority walk as `HelpDoc.text/1`. The seeded source is
  # byte-identical to `HomeTemplate.floor/0` (the compiled-in floor) so
  # the seeded doc and the non-brick fallback start in parity.
  @home_template_uuid "77f2ea65-485e-405b-9517-be9349ef6c05"

  # CX-lr73 (self-hosting slice 2, part C): the world's own TITLE (the
  # `mud_live.ex` `<h1>`) as a node-signed doc, editable without
  # redeploy. Same idempotent-seed shape as `@mud_help_uuid`/
  # `@home_template_uuid` — PLAIN TEXT (JSON body), read via
  # `Commonplace.MUD.WorldMeta.title/1` with the SAME Gate-B authority
  # walk.
  @world_meta_uuid "d9dc8e1f-d6ef-47b8-ac5e-8e454888bbcb"

  def seed(root_uuid, store \\ CommitStoreClient), do: repair(root_uuid, store)

  # CX-6pbu: test-facing accessors for the five engine verb sources moved
  # to `priv/engine_verbs/*.exs.seed` — mirrors the existing
  # `TemplateBootstrap.chat_compute_source/0` accessor pattern. `@doc
  # false` (internal, not part of the module's operational API).
  @doc false
  def engine_parser_source, do: @engine_parser_source
  @doc false
  def engine_look_verb_source, do: @engine_look_verb_source
  @doc false
  def engine_inventory_verb_source, do: @engine_inventory_verb_source
  @doc false
  def engine_emote_verb_source, do: @engine_emote_verb_source
  @doc false
  def engine_say_verb_source, do: @engine_say_verb_source
  @doc false
  def engine_where_verb_source, do: @engine_where_verb_source
  @doc false
  def engine_sit_verb_source, do: @engine_sit_verb_source
  @doc false
  def engine_stand_verb_source, do: @engine_stand_verb_source
  @doc false
  def engine_examine_verb_source, do: @engine_examine_verb_source
  @doc false
  def engine_search_verb_source, do: @engine_search_verb_source
  @doc false
  def engine_read_verb_source, do: @engine_read_verb_source

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

    # CX-wkau (Inc-1, tranche 1): same best-effort, never-blocks shape —
    # seed the doc-hosted `where`/`sit`/`stand`/`examine`/`search`/`read`
    # verbs + point the manifest at them. A failure just leaves
    # `EngineModule.run_verb/4` on the respective compiled-in floor (full
    # `do_*` parity).
    :ok = ensure_engine_where_verb(store)
    :ok = ensure_engine_sit_verb(store)
    :ok = ensure_engine_stand_verb(store)
    :ok = ensure_engine_examine_verb(store)
    :ok = ensure_engine_search_verb(store)
    :ok = ensure_engine_read_verb(store)

    # CX-hbb2: same best-effort, never-blocks shape — seed the node-signed
    # `help` text doc + point the manifest's `:help` entry at it. A failure
    # just leaves `Commonplace.MUD.HelpDoc.text/1` on the compiled-in floor.
    :ok = ensure_mud_help(store)

    # CX-gkqk: same best-effort, never-blocks shape — seed the node-signed
    # citizen starter-home TEMPLATE doc + point the manifest's
    # `:home_template` entry at it. A failure just leaves
    # `Commonplace.MUD.HomeTemplate.render/3` on the compiled-in floor.
    :ok = ensure_home_template(store)

    # CX-lr73 (mud_live.ex title): same best-effort, never-blocks shape —
    # seed the node-signed world-meta doc + point the manifest's
    # `:world_meta` entry at it. A failure just leaves
    # `Commonplace.MUD.WorldMeta.title/1` on the compiled-in floor.
    :ok = ensure_world_meta(store)

    # CX-lr73: the world CONTENT (rooms/exits, cloak/fountain, the iron
    # vein, the iron-ingot recipe) is now an imported bundle — see
    # `SeedWorld`'s moduledoc for the phase-decoupling + node-signing
    # discipline that replaces this `with`-chain's old shape.
    SeedWorld.import(root_uuid, store)
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

  # CX-wkau (Inc-1, tranche 1): idempotently seed the node-signed `where`
  # verb source doc + set the engine manifest's `:where` entry. Mirrors
  # `ensure_engine_look_verb/1` exactly.
  @doc false
  def ensure_engine_where_verb(store \\ CommitStoreClient) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context() do
      unless source_doc_present?(@engine_where_verb_uuid, store) do
        seed_source_doc(@engine_where_verb_uuid, @engine_where_verb_source, node_ctx, store, "_engine_where.ex")
      end

      manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
      Application.put_env(:commonplace, :mud_engine_manifest, Map.put(manifest, :where, @engine_where_verb_uuid))
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # CX-wkau (Inc-1, tranche 1): idempotently seed the node-signed `sit`
  # verb source doc + set the engine manifest's `:sit` entry. Mirrors
  # `ensure_engine_look_verb/1` exactly.
  @doc false
  def ensure_engine_sit_verb(store \\ CommitStoreClient) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context() do
      unless source_doc_present?(@engine_sit_verb_uuid, store) do
        seed_source_doc(@engine_sit_verb_uuid, @engine_sit_verb_source, node_ctx, store, "_engine_sit.ex")
      end

      manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
      Application.put_env(:commonplace, :mud_engine_manifest, Map.put(manifest, :sit, @engine_sit_verb_uuid))
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # CX-wkau (Inc-1, tranche 1): idempotently seed the node-signed `stand`
  # verb source doc + set the engine manifest's `:stand` entry. Mirrors
  # `ensure_engine_look_verb/1` exactly.
  @doc false
  def ensure_engine_stand_verb(store \\ CommitStoreClient) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context() do
      unless source_doc_present?(@engine_stand_verb_uuid, store) do
        seed_source_doc(@engine_stand_verb_uuid, @engine_stand_verb_source, node_ctx, store, "_engine_stand.ex")
      end

      manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
      Application.put_env(:commonplace, :mud_engine_manifest, Map.put(manifest, :stand, @engine_stand_verb_uuid))
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # CX-wkau (Inc-1, tranche 1): idempotently seed the node-signed `examine`
  # verb source doc + set the engine manifest's `:examine` entry. Mirrors
  # `ensure_engine_look_verb/1` exactly.
  @doc false
  def ensure_engine_examine_verb(store \\ CommitStoreClient) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context() do
      unless source_doc_present?(@engine_examine_verb_uuid, store) do
        seed_source_doc(@engine_examine_verb_uuid, @engine_examine_verb_source, node_ctx, store, "_engine_examine.ex")
      end

      manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
      Application.put_env(:commonplace, :mud_engine_manifest, Map.put(manifest, :examine, @engine_examine_verb_uuid))
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # CX-wkau (Inc-1, tranche 1): idempotently seed the node-signed `search`
  # verb source doc + set the engine manifest's `:search` entry. Mirrors
  # `ensure_engine_look_verb/1` exactly.
  @doc false
  def ensure_engine_search_verb(store \\ CommitStoreClient) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context() do
      unless source_doc_present?(@engine_search_verb_uuid, store) do
        seed_source_doc(@engine_search_verb_uuid, @engine_search_verb_source, node_ctx, store, "_engine_search.ex")
      end

      manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
      Application.put_env(:commonplace, :mud_engine_manifest, Map.put(manifest, :search, @engine_search_verb_uuid))
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # CX-wkau (Inc-1, tranche 1): idempotently seed the node-signed `read`
  # verb source doc + set the engine manifest's `:read` entry. Mirrors
  # `ensure_engine_look_verb/1` exactly.
  @doc false
  def ensure_engine_read_verb(store \\ CommitStoreClient) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context() do
      unless source_doc_present?(@engine_read_verb_uuid, store) do
        seed_source_doc(@engine_read_verb_uuid, @engine_read_verb_source, node_ctx, store, "_engine_read.ex")
      end

      manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
      Application.put_env(:commonplace, :mud_engine_manifest, Map.put(manifest, :read, @engine_read_verb_uuid))
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # CX-hbb2: idempotently seed the node-signed `help` TEXT doc + set the
  # engine manifest's `:help` entry. Mirrors `ensure_engine_look_verb/1`'s
  # discipline exactly (best-effort, rescues/catches to `:ok` on any
  # failure — no node identity, write refused, whatever — so the doc-hosted
  # `help` path is strictly additive and can never brick or block seeding;
  # `Commonplace.MUD.HelpDoc.text/1` just stays on the compiled-in floor).
  # UNLIKE the engine-* seeds above, the content here is PLAIN TEXT (not a
  # `defmodule`) — `seed_source_doc/5` is reused as-is (it only ever writes
  # a text-content doc; it never compiles anything), so no new write path is
  # introduced (CX-k20z class: minimal writes only).
  @doc false
  def ensure_mud_help(store \\ CommitStoreClient) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context() do
      unless source_doc_present?(@mud_help_uuid, store) do
        seed_source_doc(@mud_help_uuid, Commonplace.MUD.HelpDoc.floor(), node_ctx, store, "_mud_help.txt")
      end

      manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
      Application.put_env(:commonplace, :mud_engine_manifest, Map.put(manifest, :help, @mud_help_uuid))
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # CX-gkqk: idempotently seed the node-signed home-TEMPLATE JSON doc +
  # set the engine manifest's `:home_template` entry. Mirrors
  # `ensure_mud_help/1`'s discipline exactly (best-effort, rescues/catches
  # to `:ok` on any failure — so the doc-hosted template path is strictly
  # additive and can never brick or block seeding;
  # `Commonplace.MUD.HomeTemplate.render/3` just stays on the compiled-in
  # floor). `seed_source_doc/5` is reused as-is — no new write path
  # (CX-k20z class).
  @doc false
  def ensure_home_template(store \\ CommitStoreClient) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context() do
      unless source_doc_present?(@home_template_uuid, store) do
        seed_source_doc(@home_template_uuid, Commonplace.MUD.HomeTemplate.floor_json(), node_ctx, store, "_home_template.json")
      end

      manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
      Application.put_env(:commonplace, :mud_engine_manifest, Map.put(manifest, :home_template, @home_template_uuid))
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # CX-lr73: idempotently seed the node-signed world-meta JSON doc + set
  # the engine manifest's `:world_meta` entry. Mirrors `ensure_mud_help/1`
  # exactly (best-effort, never blocks/bricks; `Commonplace.MUD.WorldMeta.title/1`
  # stays on the compiled-in floor on any failure).
  @doc false
  def ensure_world_meta(store \\ CommitStoreClient) do
    with {:ok, node_ctx} <- NodeIdentity.signing_context() do
      unless source_doc_present?(@world_meta_uuid, store) do
        seed_source_doc(@world_meta_uuid, Commonplace.MUD.WorldMeta.floor_json(), node_ctx, store, "_world_meta.json")
      end

      manifest = Application.get_env(:commonplace, :mud_engine_manifest, %{})
      Application.put_env(:commonplace, :mud_engine_manifest, Map.put(manifest, :world_meta, @world_meta_uuid))
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
end
