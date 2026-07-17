defmodule Commonplace.MUD.VerbSourceTest do
  use ExUnit.Case

  alias Commonplace.Code.SourceDoc
  alias Commonplace.MUD.{Bootstrap, PlayerSession, Schemas, VerbSource}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    SourceDoc.reset_cache()

    dir = Path.join(System.tmp_dir!(), "cp_mud_verb_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn ->
      File.rm_rf!(dir)
      SourceDoc.reset_cache()
    end)

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

    on_exit(fn -> if Process.alive?(bursar_pid), do: (try do GenServer.stop(bursar_pid) catch (:exit, _ -> :ok) end) end)

    root_uuid = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root_uuid, update, nil)
    {:ok, _} = Bootstrap.seed(root_uuid, store)

    %{store: store, root: root_uuid}
  end

  defp start_player(name, ctx, parent \\ self()) do
    output_fn = fn text -> send(parent, {:out, name, text}) end

    {:ok, session} =
      PlayerSession.start_link(
        player_name: name,
        root_uuid: ctx.root,
        store: ctx.store,
        output_fn: output_fn,
        owner_pid: parent
      )

    drain(name)
    session
  end

  defp drain(name, acc \\ []) do
    receive do
      {:out, ^name, text} -> drain(name, [text | acc])
    after
      30 -> Enum.reverse(acc)
    end
  end

  defp send_input(session, text) do
    PlayerSession.input_sync(session, text)
    Process.sleep(60)
  end

  defp clearing_uuid(ctx) do
    {:ok, schema} = Schemas.load_dir_schema(ctx.root, ctx.store)
    {:ok, entry} = Schema.get_entry(schema, "clearing")
    entry.node_id
  end

  defp start_room_uuid(ctx) do
    {:ok, schema} = Schemas.load_dir_schema(ctx.root, ctx.store)
    {:ok, entry} = Schema.get_entry(schema, "start")
    entry.node_id
  end

  defp fountain_dir(ctx) do
    with {:ok, schema} <- Schemas.load_dir_schema(clearing_uuid(ctx), ctx.store),
         {:ok, entry} <- Schema.get_entry(schema, "fountain.obj") do
      entry.node_id
    end
  end

  defp cloak_dir(ctx) do
    with {:ok, schema} <- Schemas.load_dir_schema(start_room_uuid(ctx), ctx.store),
         {:ok, entry} <- Schema.get_entry(schema, "cloak.obj") do
      entry.node_id
    end
  end

  test "save_verb writes a source doc, validates compile, and round-trips through find_source", ctx do
    fountain_dir =
      with {:ok, schema} <- Schemas.load_dir_schema(clearing_uuid(ctx), ctx.store),
           {:ok, entry} <- Schema.get_entry(schema, "fountain.obj") do
        entry.node_id
      end

    src = """
    defmodule Commonplace.UserCode.Mud.Verb.FountainBow do
      def run(_ctx), do: :ok
    end
    """

    assert :ok = VerbSource.save_verb(fountain_dir, "bow", src, ctx.store)
    assert {:ok, _uuid} = VerbSource.find_source(fountain_dir, "bow", ctx.store)
    assert {:ok, mod} = VerbSource.compile_verb(fountain_dir, "bow", ctx.store)
    assert function_exported?(mod, :run, 1)
  end

  test "save_verb returns compile error but still persists source", ctx do
    fountain_dir =
      with {:ok, schema} <- Schemas.load_dir_schema(clearing_uuid(ctx), ctx.store),
           {:ok, entry} <- Schema.get_entry(schema, "fountain.obj") do
        entry.node_id
      end

    bad = "defmodule Borked do def run(ctx) syntax_error end"

    assert {:error, {:compile_error, _}} = VerbSource.save_verb(fountain_dir, "broke", bad, ctx.store)
    assert {:ok, _} = VerbSource.find_source(fountain_dir, "broke", ctx.store)
  end

  # CX-bg1v/CX-fhz4: `@verb` now authors SAFE verbs (`.safe.elx`) via
  # `VerbSource.save_safe_verb/6` — a bare `run/2` BODY bound to
  # `world`/`args`, not a full ambient-store `defmodule`. Updated from the
  # legacy form this test originally authored (which would now be REJECTED
  # by `Lint` — `defmodule` is banned in a safe-verb body).
  test "@verb editor flow: alice authors a bow verb on the cloak; bob triggers it", ctx do
    alice = start_player("alice", ctx)
    bob = start_player("bob", ctx)
    drain("alice")
    drain("bob")

    # Alice picks up the cloak so it's in scope for @verb in either room.
    send_input(alice, "take cloak")
    drain("alice")
    drain("bob")

    # Alice opens the editor on cloak:bow
    send_input(alice, "@verb cloak:bow")
    Process.sleep(50)
    drain("alice")

    # Type a bare run/2 BODY (world/args in scope, no defmodule) then '.' to save.
    send_input(alice, ~s|Commonplace.MUD.World.Facade.say(world, "bows gracefully.")|)
    send_input(alice, ".")
    Process.sleep(60)

    out = drain("alice") |> Enum.join("\n")
    assert out =~ "saved" and (out =~ "compiles cleanly" or out =~ "compile error" == false)

    # Now bob: drop the cloak first so cloak is in the room (alice has it).
    # Easier: alice drops it.
    send_input(alice, "drop cloak")
    Process.sleep(60)
    drain("alice")
    drain("bob")

    # Bob types `bow cloak`. The custom safe verb on cloak.obj fires,
    # broadcasting to bob's (the invoker's) current room.
    send_input(bob, "bow cloak")
    Process.sleep(80)

    bob_out = drain("bob") |> Enum.join("\n")
    alice_out = drain("alice") |> Enum.join("\n")

    assert (bob_out <> alice_out) =~ "bows gracefully"

    PlayerSession.stop(alice)
    PlayerSession.stop(bob)
  end

  # CX-qom0: migrated from a player-dispatched LEGACY (full-defmodule)
  # crashing verb to a SAFE verb — a legacy `.elx` is no longer
  # player-dispatchable (gated by `require_safe_wrapper: true`). The
  # allowlist admits no `raise`, so the crash vehicle is a plain
  # allowlist-clean runtime error (`1 / 0`) instead of `raise "deliberate"`.
  test "user verb runtime exception emits a verb_error event", ctx do
    alice = start_player("alice", ctx)

    fountain_dir =
      with {:ok, schema} <- Schemas.load_dir_schema(clearing_uuid(ctx), ctx.store),
           {:ok, entry} <- Schema.get_entry(schema, "fountain.obj") do
        entry.node_id
      end

    :ok = VerbSource.save_safe_verb(fountain_dir, "shake", "1 / 0", [fountain_dir], ctx.store)

    # Alice walks east into the clearing where fountain lives
    send_input(alice, "east")
    Process.sleep(60)
    drain("alice")

    send_input(alice, "shake fountain")
    Process.sleep(60)

    out = drain("alice") |> Enum.join("\n")
    assert out =~ "shake" and out =~ "crashed"

    PlayerSession.stop(alice)
  end

  # CX-qom0: migrated from a LEGACY (full-defmodule, ambient-reach)
  # `tick.elx` to a SAFE `tick.safe.elx` — `TickBot.fire/2` no longer
  # dispatches the legacy tick path at all (a plantable legacy verb on a
  # ticking object/room would otherwise get full store/uuid reach on
  # every heartbeat, no player involved — the confused-deputy ingress
  # CX-qom0 closes). The body uses the facade's `emit/2` (a room
  # broadcast, no doc write, so no owner_grant/intersection check
  # applies) to fire the same custom event the legacy body used to.
  test "tick.safe.elx on an object overrides tick_message", ctx do
    alias Commonplace.Green.Bursar
    alias Commonplace.MUD.{Topics, TickBot}

    fountain_dir =
      with {:ok, schema} <- Schemas.load_dir_schema(clearing_uuid(ctx), ctx.store),
           {:ok, entry} <- Schema.get_entry(schema, "fountain.obj") do
        entry.node_id
      end

    body = ~s|Commonplace.MUD.World.Facade.emit(world, %{kind: :custom, text: "Sparks fly!"})|

    :ok = VerbSource.save_safe_verb(fountain_dir, "tick", body, [fountain_dir], ctx.store)

    # CX-pvrl: this test only cares about tick.elx firing, not
    # World.move — so its TickBot gets a dedicated, uniquely-named
    # Bursar instead of ctx's default-named one (which the setup starts
    # so World.move's take/drop/east tests elsewhere in this module can
    # find it). The application also boots an unconditional
    # `Commonplace.MUD.TickBot` singleton (default name, real 1s
    # heartbeat, `bursar:` defaulting to the literal `Bursar` atom) for
    # the whole `mix test` run; if this test's TickBot pointed at the
    # shared default-named Bursar, that ambient singleton could win the
    # "__singletons/tick_bot" lease first and this tick_now would flake
    # with :not_leader. A private Bursar is invisible to it.
    bursar_name = :"verb_source_tick_bursar_#{:rand.uniform(1_000_000)}"

    {:ok, bursar_pid} =
      Bursar.start_link(
        root_uuid: UUID.uuid4(),
        store: ctx.store,
        name: bursar_name,
        sweep_interval: 60_000
      )

    on_exit(fn -> if Process.alive?(bursar_pid), do: (try do GenServer.stop(bursar_pid) catch (:exit, _ -> :ok) end) end)

    name = :"tick_bot_#{:rand.uniform(1_000_000)}"

    {:ok, _pid} =
      TickBot.start_link(
        name: name,
        store: ctx.store,
        root_uuid: ctx.root,
        heartbeat_ms: 999_999,
        auto_start: false,
        bursar: bursar_name
      )

    Topics.subscribe_room(clearing_uuid(ctx))

    :ok = TickBot.tick_now(name)

    assert_receive {"red:" <> _, %{kind: :custom, text: "Sparks fly!"}}, 200
    refute_receive {"red:" <> _, %{kind: :custom, text: "The fountain burbles softly."}}, 50
  end

  # CX-9plf: @unverb's backing — remove a verb so it no longer resolves.
  test "delete_verb removes the verb entry; missing verb is :not_found", ctx do
    dir = fountain_dir(ctx)

    :ok =
      VerbSource.save_safe_verb(
        dir,
        "temp",
        ~s|Commonplace.MUD.World.Facade.say(world, "hi")|,
        [dir],
        ctx.store
      )

    assert {:ok, _} = VerbSource.find_safe_source(dir, "temp", ctx.store)

    assert :ok = VerbSource.delete_verb(dir, "temp", ctx.store)
    assert :not_found = VerbSource.find_safe_source(dir, "temp", ctx.store)

    # Removing a verb that isn't there is a clean :not_found.
    assert :not_found = VerbSource.delete_verb(dir, "nope", ctx.store)
  end

  describe "CX-9f62: unique per-verb module naming (kills the global compile collision)" do
    test "two verbs authored under the SAME defmodule name on DIFFERENT objects compile to distinct modules and both run correctly",
         ctx do
      same_name_src = fn text ->
        """
        defmodule UserVerb do
          def run(ctx) do
            Commonplace.MUD.World.broadcast_room(ctx.current_room_uuid, #{inspect(text)})
            :ok
          end
        end
        """
      end

      assert :ok = VerbSource.save_verb(fountain_dir(ctx), "poke", same_name_src.("fountain poke fired"), ctx.store)
      assert :ok = VerbSource.save_verb(cloak_dir(ctx), "poke", same_name_src.("cloak poke fired"), ctx.store)

      assert {:ok, fountain_mod} = VerbSource.compile_verb(fountain_dir(ctx), "poke", ctx.store)
      assert {:ok, cloak_mod} = VerbSource.compile_verb(cloak_dir(ctx), "poke", ctx.store)

      # The collision is gone: distinct BEAM module atoms even though both
      # source docs authored the identical `defmodule UserVerb`.
      refute fountain_mod == cloak_mod

      alias Commonplace.MUD.Topics
      Topics.subscribe_room(clearing_uuid(ctx))
      Topics.subscribe_room(start_room_uuid(ctx))

      assert {:ok, :ok} =
               VerbSource.run_verb(
                 fountain_dir(ctx),
                 "poke",
                 %{current_room_uuid: clearing_uuid(ctx), player_name: "alice"},
                 ctx.store
               )

      assert_receive {"red:" <> _, %{text: "fountain poke fired"}}, 200

      assert {:ok, :ok} =
               VerbSource.run_verb(
                 cloak_dir(ctx),
                 "poke",
                 %{current_room_uuid: start_room_uuid(ctx), player_name: "alice"},
                 ctx.store
               )

      assert_receive {"red:" <> _, %{text: "cloak poke fired"}}, 200
      refute_received {"red:" <> _, %{text: "fountain poke fired"}}
    end

    test "invoking the verb on one object never fires the other object's same-named verb (verb-name hijack symptom)",
         ctx do
      hijack_src = fn marker ->
        """
        defmodule UserVerb do
          def run(_ctx), do: #{inspect(marker)}
        end
        """
      end

      assert :ok = VerbSource.save_verb(fountain_dir(ctx), "twist", hijack_src.(:fountain_twist), ctx.store)
      assert :ok = VerbSource.save_verb(cloak_dir(ctx), "twist", hijack_src.(:cloak_twist), ctx.store)

      assert {:ok, :fountain_twist} = VerbSource.run_verb(fountain_dir(ctx), "twist", %{}, ctx.store)
      assert {:ok, :cloak_twist} = VerbSource.run_verb(cloak_dir(ctx), "twist", %{}, ctx.store)

      # Re-run in the opposite order too — cache hits must still resolve
      # to the correct, distinct module per object.
      assert {:ok, :cloak_twist} = VerbSource.run_verb(cloak_dir(ctx), "twist", %{}, ctx.store)
      assert {:ok, :fountain_twist} = VerbSource.run_verb(fountain_dir(ctx), "twist", %{}, ctx.store)
    end

    test "a non-verb SourceDoc caller (compute/view/black doc) still compiles under its own self-named module (unaffected)",
         ctx do
      alias Commonplace.Document.ContentType
      alias Commonplace.Store.CommitStore
      alias Yelixer.Doc, as: YDoc

      uuid = UUID.uuid4()
      doc = YDoc.new()
      doc = ContentType.create(doc, :text, "elixir")
      doc = ContentType.insert_text(doc, 0, "defmodule Commonplace.UserCode.NotAVerb do\n  def value, do: :plain\nend\n")
      update = Encoding.encode_update(doc)
      CommitStore.create_commit(ctx.store, uuid, update, nil)

      assert {:ok, mod} = SourceDoc.compile(uuid, ctx.store)
      assert mod == Commonplace.UserCode.NotAVerb
      assert mod.value() == :plain
    end

    test "editing a verb still hot-reloads (content-hash recompile) under the new naming", ctx do
      assert :ok =
               VerbSource.save_verb(
                 fountain_dir(ctx),
                 "shimmer",
                 "defmodule UserVerb do\n  def run(_ctx), do: :v1\nend\n",
                 ctx.store
               )

      assert {:ok, mod_v1} = VerbSource.compile_verb(fountain_dir(ctx), "shimmer", ctx.store)
      assert {:ok, :v1} = VerbSource.run_verb(fountain_dir(ctx), "shimmer", %{}, ctx.store)

      assert :ok =
               VerbSource.save_verb(
                 fountain_dir(ctx),
                 "shimmer",
                 "defmodule UserVerb do\n  def run(_ctx), do: :v2\nend\n",
                 ctx.store
               )

      assert {:ok, mod_v2} = VerbSource.compile_verb(fountain_dir(ctx), "shimmer", ctx.store)
      # Same derived module name (deterministic from the verb doc's own
      # uuid) — hot reload re-targets the same atom, doesn't leak a new one.
      assert mod_v1 == mod_v2
      assert {:ok, :v2} = VerbSource.run_verb(fountain_dir(ctx), "shimmer", %{}, ctx.store)
    end
  end
end
