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

    on_exit(fn -> if Process.alive?(bursar_pid), do: GenServer.stop(bursar_pid) end)

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

    # Type four lines of source then '.' to save
    send_input(alice, "defmodule Commonplace.UserCode.Mud.Verb.CloakBow do")
    send_input(alice, ~s|  def run(ctx), do: Commonplace.MUD.World.broadcast_room(ctx.current_room_uuid, "\#{ctx.player_name} bows gracefully.")|)
    send_input(alice, "end")
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

    # Bob types `bow cloak`. The custom verb on cloak.obj fires.
    send_input(bob, "bow cloak")
    Process.sleep(80)

    bob_out = drain("bob") |> Enum.join("\n")
    alice_out = drain("alice") |> Enum.join("\n")

    assert (bob_out <> alice_out) =~ "bob bows gracefully"

    PlayerSession.stop(alice)
    PlayerSession.stop(bob)
  end

  test "user verb runtime exception emits a verb_error event", ctx do
    alice = start_player("alice", ctx)

    fountain_dir =
      with {:ok, schema} <- Schemas.load_dir_schema(clearing_uuid(ctx), ctx.store),
           {:ok, entry} <- Schema.get_entry(schema, "fountain.obj") do
        entry.node_id
      end

    crash = """
    defmodule Commonplace.UserCode.Mud.Verb.FountainShake do
      def run(_ctx) do
        raise "deliberate"
      end
    end
    """

    :ok = VerbSource.save_verb(fountain_dir, "shake", crash, ctx.store)

    # Alice walks east into the clearing where fountain lives
    send_input(alice, "east")
    Process.sleep(60)
    drain("alice")

    send_input(alice, "shake fountain")
    Process.sleep(60)

    out = drain("alice") |> Enum.join("\n")
    assert out =~ "shake" and out =~ "deliberate"

    PlayerSession.stop(alice)
  end

  test "tick.elx on an object overrides tick_message", ctx do
    alias Commonplace.Green.Bursar
    alias Commonplace.MUD.{Topics, TickBot}

    fountain_dir =
      with {:ok, schema} <- Schemas.load_dir_schema(clearing_uuid(ctx), ctx.store),
           {:ok, entry} <- Schema.get_entry(schema, "fountain.obj") do
        entry.node_id
      end

    src = """
    defmodule Commonplace.UserCode.Mud.Verb.FountainTick do
      def run(ctx) do
        Commonplace.MUD.World.broadcast_room(ctx.current_room_uuid, %{kind: :custom, text: "Sparks fly!"})
        :ok
      end
    end
    """

    :ok = VerbSource.save_verb(fountain_dir, "tick", src, ctx.store)

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

    on_exit(fn -> if Process.alive?(bursar_pid), do: GenServer.stop(bursar_pid) end)

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
end
