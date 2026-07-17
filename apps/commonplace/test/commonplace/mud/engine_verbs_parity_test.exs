defmodule Commonplace.MUD.EngineVerbsParityTest do
  @moduledoc """
  CX-wkau (MUD-as-documents Inc-1) — a PARITY pin for the doc-hosted
  gameplay-verb baselines: tranche 1's six (`where`/`sit`/`stand`/
  `examine`/`search`/`read`) plus tranche 2's three (`who`/`recipes`/
  `use`). With each verb's seed FRESHLY ensured
  (`Bootstrap.ensure_engine_*_verb/1`) on a bootstrapped test world, running
  a command through `EngineModule.run_verb/4` (the doc path) must produce
  the exact same result as running it through the verb's compiled-in FLOOR
  module directly. This is the seed<->floor behavior-identity pin at seed
  time — the individual `engine_module_test.exs` describes above cover the
  doc->run/non-brick/RCE mechanics per-verb in depth; this file is the
  breadth check across all nine with representative inputs (empty argv, a
  found target, a missing target).
  """
  use ExUnit.Case, async: false

  alias Commonplace.MUD.{Bootstrap, EngineModule, Parser, SeedWorld}
  alias Commonplace.MUD.Schemas
  alias Commonplace.MUD.Schemas.{Object, Player, Room}

  alias Commonplace.MUD.Verbs.{
    ExamineFloor,
    GoFloor,
    HomeFloor,
    ReadFloor,
    RecipesFloor,
    SearchFloor,
    SitFloor,
    StandFloor,
    UseFloor,
    WhereFloor,
    WhoFloor
  }

  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema

  @store CommitStoreClient

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_engine_parity_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
    {:ok, _pid} = Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    Commonplace.Tree.DocCache.clear()
    Commonplace.Code.SourceDoc.reset_cache()

    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    old_manifest = Application.get_env(:commonplace, :mud_engine_manifest)
    old_trust = Application.get_env(:commonplace, :trust)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: true, trusted_identities: %{}})

    # CX-wkau (tranche 3): `go`/`home` actually move presence (`Move.move/5`
    # takes exclusive green tokens on the source/dest dir schemas), so this
    # file's Bursar-less predecessor tests (sit/stand/etc, no tree moves)
    # now need one for the go/home parity tests below.
    case GenServer.whereis(Commonplace.Green.Bursar) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    bursar_root = UUID.uuid4()

    {:ok, bursar_pid} =
      Commonplace.Green.Bursar.start_link(root_uuid: bursar_root, store: @store, sweep_interval: 60_000)

    on_exit(fn -> if Process.alive?(bursar_pid), do: (try do GenServer.stop(bursar_pid) catch (:exit, _ -> :ok) end) end)

    on_exit(fn ->
      if is_nil(old_manifest),
        do: Application.delete_env(:commonplace, :mud_engine_manifest),
        else: Application.put_env(:commonplace, :mud_engine_manifest, old_manifest)

      if is_nil(old_trust),
        do: Application.delete_env(:commonplace, :trust),
        else: Application.put_env(:commonplace, :trust, old_trust)

      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")

      {:ok, _pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: "tmp/test_data"})

      Commonplace.Tree.DocCache.clear()
      Commonplace.Code.SourceDoc.reset_cache()
      File.rm_rf!(dir)
    end)

    :ok
  end

  # A minimal but real ctx: a room (with a "widget" object in it), an
  # inventory (with a "gem" object in it), and a player dir — same shape
  # `PlayerSession` builds, hand-built here (mirrors `engine_module_test.exs`
  # `build_ctx`/`build_inventory_ctx`/`build_examine_ctx` helpers) so this
  # doesn't need a full `PlayerSession`/socket stack.
  defp build_world_ctx do
    root_uuid = UUID.uuid4()
    root_update = Yelixer.Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(CommitStore, root_uuid, root_update, nil)

    {:ok, room_uuid} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: "The Vault", description: "A quiet stone vault."}),
        @store
      )

    {:ok, inventory_uuid} = Schemas.create_dir_with_meta(nil, nil, @store)

    {:ok, player_uuid} =
      Schemas.create_dir_with_meta(
        Schemas.player_filename(),
        Schemas.encode_player(%Player{name: "alice", description: "A curious adventurer."}),
        @store
      )

    seed_object(room_uuid, "widget", "A humble widget.")
    seed_object(inventory_uuid, "gem", "A sparkling gem.")

    %{
      player_name: "alice",
      player_uuid: player_uuid,
      player_dir_uuid: player_uuid,
      inventory_uuid: inventory_uuid,
      current_room_uuid: room_uuid,
      presence_filename: "alice.usr",
      root_uuid: root_uuid,
      store: @store,
      signing_context: nil
    }
  end

  defp seed_object(dir_uuid, name, description) do
    {:ok, obj_uuid} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: name, description: description}),
        @store
      )

    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, @store)
    schema = Schema.add_directory(schema, "#{name}.obj", obj_uuid)
    update = Yelixer.Encoding.encode_update(schema)
    CommitStore.create_chained_commit(CommitStore, dir_uuid, update, %{kind: :regular}, [])
  end

  defp cmd(verb, argv \\ []),
    do: %Parser.Command{verb: verb, argv: argv, target: List.first(argv)}

  defp ensure_all_six do
    assert :ok = Bootstrap.ensure_engine_where_verb(@store)
    assert :ok = Bootstrap.ensure_engine_sit_verb(@store)
    assert :ok = Bootstrap.ensure_engine_stand_verb(@store)
    assert :ok = Bootstrap.ensure_engine_examine_verb(@store)
    assert :ok = Bootstrap.ensure_engine_search_verb(@store)
    assert :ok = Bootstrap.ensure_engine_read_verb(@store)
  end

  defp ensure_tranche_2 do
    assert :ok = Bootstrap.ensure_engine_who_verb(@store)
    assert :ok = Bootstrap.ensure_engine_recipes_verb(@store)
    assert :ok = Bootstrap.ensure_engine_use_verb(@store)
  end

  defp ensure_tranche_3 do
    assert :ok = Bootstrap.ensure_engine_go_verb(@store)
    assert :ok = Bootstrap.ensure_engine_home_verb(@store)
  end

  # A src room with a "north" exit to a dest room, plus a presence entry
  # (`presence_filename` -> `player_uuid`) seeded directly into the src
  # room's schema — the shape `Move.move/5` requires for a real move.
  defp build_go_ctx(name \\ "alice") do
    root_uuid = UUID.uuid4()
    CommitStore.create_commit(CommitStore, root_uuid, Yelixer.Encoding.encode_update(Schema.new_schema()), nil)

    {:ok, dest_uuid} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: "Dest", description: "A dest room."}),
        @store
      )

    {:ok, src_uuid} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: "Src", description: "A src room.", exits: %{"north" => dest_uuid}}),
        @store
      )

    player_uuid = UUID.uuid4()
    presence_filename = "#{name}.usr"

    {:ok, src_schema} = Schemas.load_dir_schema(src_uuid, @store)
    src_schema = Schema.add_file(src_schema, presence_filename, player_uuid)
    CommitStore.create_chained_commit(CommitStore, src_uuid, Yelixer.Encoding.encode_update(src_schema), %{kind: :regular}, [])

    %{
      player_uuid: player_uuid,
      player_name: name,
      presence_filename: presence_filename,
      current_room_uuid: src_uuid,
      dest_uuid: dest_uuid,
      root_uuid: root_uuid,
      store: @store,
      signing_context: nil
    }
  end

  # A full `players/<name>/` home room + a separate starting room with the
  # player's presence seeded in it.
  defp build_home_ctx(name) do
    root_uuid = UUID.uuid4()
    CommitStore.create_commit(CommitStore, root_uuid, Yelixer.Encoding.encode_update(Schema.new_schema()), nil)

    {:ok, home_uuid} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: "#{name}'s Home", description: "Cozy."}),
        @store
      )

    {:ok, start_uuid} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: "Start", description: "The starting room."}),
        @store
      )

    players_uuid = UUID.uuid4()
    players_schema = Schema.add_directory(Schema.new_schema(), name, home_uuid)
    CommitStore.create_commit(CommitStore, players_uuid, Yelixer.Encoding.encode_update(players_schema), nil)

    {:ok, root_schema} = Schemas.load_dir_schema(root_uuid, @store)
    root_schema = Schema.add_directory(root_schema, "players", players_uuid)

    CommitStore.create_chained_commit(
      CommitStore,
      root_uuid,
      Yelixer.Encoding.encode_update(root_schema),
      %{kind: :regular},
      []
    )

    player_uuid = UUID.uuid4()
    presence_filename = "#{name}.usr"

    {:ok, start_schema} = Schemas.load_dir_schema(start_uuid, @store)
    start_schema = Schema.add_file(start_schema, presence_filename, player_uuid)

    CommitStore.create_chained_commit(
      CommitStore,
      start_uuid,
      Yelixer.Encoding.encode_update(start_schema),
      %{kind: :regular},
      []
    )

    %{
      player_uuid: player_uuid,
      player_name: name,
      presence_filename: presence_filename,
      current_room_uuid: start_uuid,
      home_uuid: home_uuid,
      root_uuid: root_uuid,
      store: @store,
      signing_context: nil
    }
  end

  test "seed<->floor parity for all six tranche-1 verbs across representative inputs" do
    ctx = build_world_ctx()
    ensure_all_six()

    # where: no target concept — bare invocation only.
    assert EngineModule.run_verb(:where, cmd("where"), ctx, @store) ==
             WhereFloor.run(cmd("where"), ctx)

    # sit / stand: bare invocation, plus the room-broadcast side effect.
    Commonplace.MUD.Topics.subscribe_room(ctx.current_room_uuid)

    assert EngineModule.run_verb(:sit, cmd("sit"), ctx, @store) == {:reply, "You sit down."}
    assert SitFloor.run(cmd("sit"), ctx) == {:reply, "You sit down."}
    assert_receive {"red:" <> _, %{kind: :emote, text: "sits down."}}, 500

    assert EngineModule.run_verb(:stand, cmd("stand"), ctx, @store) == {:reply, "You stand up."}
    assert StandFloor.run(cmd("stand"), ctx) == {:reply, "You stand up."}
    assert_receive {"red:" <> _, %{kind: :emote, text: "stands up."}}, 500

    # search: constant baseline, bare invocation and with a (unused) target.
    for argv <- [[], ["everywhere"]] do
      assert EngineModule.run_verb(:search, cmd("search", argv), ctx, @store) ==
               SearchFloor.run(cmd("search", argv), ctx)
    end

    # examine: empty argv, a found room target, a found inventory target, a
    # missing target.
    for argv <- [[], ["widget"], ["gem"], ["nonexistent"]] do
      assert EngineModule.run_verb(:examine, cmd("examine", argv), ctx, @store) ==
               ExamineFloor.run(cmd("examine", argv), ctx),
             "examine #{inspect(argv)} diverged from the floor"
    end

    # read: empty argv, a found target (falls back to description, no
    # meta["state"]["text"] seeded), a missing target.
    for argv <- [[], ["widget"], ["nonexistent"]] do
      assert EngineModule.run_verb(:read, cmd("read", argv), ctx, @store) ==
               ReadFloor.run(cmd("read", argv), ctx),
             "read #{inspect(argv)} diverged from the floor"
    end
  end

  test "seed<->floor parity for the tranche-2 verbs (who/recipes/use) across representative inputs" do
    ctx = build_world_ctx()
    ensure_tranche_2()

    # who: no live sessions registered anywhere — bare invocation only.
    assert EngineModule.run_verb(:who, cmd("who"), ctx, @store) ==
             WhoFloor.run(cmd("who"), ctx)

    assert {:reply, "Nobody is logged in."} = EngineModule.run_verb(:who, cmd("who"), ctx, @store)

    # recipes: the test world seeds the iron-ingot recipe via SeedWorld.
    assert {:ok, :ready} = SeedWorld.import(ctx.root_uuid, @store)

    assert EngineModule.run_verb(:recipes, cmd("recipes"), ctx, @store) ==
             RecipesFloor.run(cmd("recipes"), ctx)

    assert {:reply, text} = EngineModule.run_verb(:recipes, cmd("recipes"), ctx, @store)
    assert text =~ "iron ingot"

    # use: with and without an argv target — a constant baseline either way.
    for argv <- [[], ["widget"]] do
      assert EngineModule.run_verb(:use, cmd("use", argv), ctx, @store) ==
               UseFloor.run(cmd("use", argv), ctx),
             "use #{inspect(argv)} diverged from the floor"
    end
  end

  # CX-wkau (Inc-1, tranche 3) — `go`/`home` breadth check: bad direction, no
  # direction, and a real valid move, for `go`; the no-home-room case and a
  # real valid move for `home`. TRUST-ADJACENT (CX-avzp): the valid-move
  # cases exercise the SAME `World.move_presence/5` chokepoint every other
  # mover uses — see `EngineModuleTest`'s "go verb"/"home verb" describes for
  # the deeper floor/node-edit/player-signed-refused/crash-contained matrix,
  # and `CxAvzpPrivateRoomTest` for the dedicated denial/eavesdrop dual-path
  # pin.
  test "seed<->floor parity for go/home (tranche 3) across representative inputs" do
    ensure_tranche_3()

    # go: no direction at all -> "Go where?" (no move, safe to share one ctx
    # with the floor comparison).
    ctx = build_go_ctx()

    assert EngineModule.run_verb(:go, cmd("go", []), ctx, @store) == GoFloor.run(cmd("go", []), ctx)
    assert {:error, "Go where?"} = EngineModule.run_verb(:go, cmd("go", []), ctx, @store)

    # go: a direction with no matching exit -> "You can't go <dir>." (no
    # move either).
    assert EngineModule.run_verb(:go, cmd("go", ["south"]), ctx, @store) ==
             GoFloor.run(cmd("go", ["south"]), ctx)

    assert {:error, "You can't go south."} = EngineModule.run_verb(:go, cmd("go", ["south"]), ctx, @store)

    # go: a valid move — a real presence relocation, so the doc path and the
    # floor path each need their OWN fresh src/dest pair (a move mutates
    # schema state; the same ctx can't be replayed through both).
    doc_go_ctx = build_go_ctx("go-doc-mover")
    floor_go_ctx = build_go_ctx("go-floor-mover")

    assert {:moved, doc_dest} = EngineModule.run_verb(:go, cmd("go", ["north"]), doc_go_ctx, @store)
    assert doc_dest == doc_go_ctx.dest_uuid

    assert {:moved, floor_dest} = GoFloor.run(cmd("go", ["north"]), floor_go_ctx)
    assert floor_dest == floor_go_ctx.dest_uuid

    # the bare-direction shorthand ("north" parsed as its OWN verb) must
    # agree with the explicit "go north" form above.
    doc_go_ctx2 = build_go_ctx("go-doc-mover-2")
    assert {:moved, dest2} = EngineModule.run_verb(:go, cmd("north", []), doc_go_ctx2, @store)
    assert dest2 == doc_go_ctx2.dest_uuid

    # home: no `players/<name>/` room at all -> the structural-absence
    # error (no move, safe to share one ctx).
    no_home_ctx = build_world_ctx()

    assert EngineModule.run_verb(:home, cmd("home", []), no_home_ctx, @store) ==
             HomeFloor.run(cmd("home", []), no_home_ctx)

    assert {:error, "You don't seem to have a home to return to yet."} =
             EngineModule.run_verb(:home, cmd("home", []), no_home_ctx, @store)

    # home: a valid move — same fresh-pair-per-path discipline as go above.
    doc_home_ctx = build_home_ctx("home-doc-mover")
    floor_home_ctx = build_home_ctx("home-floor-mover")

    assert {:moved, doc_home} = EngineModule.run_verb(:home, cmd("home", []), doc_home_ctx, @store)
    assert doc_home == doc_home_ctx.home_uuid

    assert {:moved, floor_home} = HomeFloor.run(cmd("home", []), floor_home_ctx)
    assert floor_home == floor_home_ctx.home_uuid
  end
end
