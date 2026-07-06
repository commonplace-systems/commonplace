defmodule Commonplace.MUD.OutputTest do
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

    dir = Path.join(System.tmp_dir!(), "cp_mud_output_#{:rand.uniform(1_000_000)}")
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

  defp clearing_uuid(ctx) do
    {:ok, schema} = Schemas.load_dir_schema(ctx.root, ctx.store)
    {:ok, entry} = Schema.get_entry(schema, "clearing")
    entry.node_id
  end

  defp send_input(session, text) do
    PlayerSession.input_sync(session, text)
    Process.sleep(60)
  end

  test "Output.tell sends a string to the actor only", ctx do
    fountain_dir =
      with {:ok, schema} <- Schemas.load_dir_schema(clearing_uuid(ctx), ctx.store),
           {:ok, entry} <- Schema.get_entry(schema, "fountain.obj") do
        entry.node_id
      end

    src = """
    defmodule Commonplace.UserCode.Mud.Verb.FountainPing do
      alias Commonplace.MUD.Output

      def run(ctx) do
        Output.tell(ctx, "ping-from-tell")
        :ok
      end
    end
    """

    :ok = VerbSource.save_verb(fountain_dir, "ping", src, ctx.store)

    alice = start_player("alice", ctx)
    bob = start_player("bob", ctx)
    drain("alice")
    drain("bob")

    send_input(alice, "east")
    send_input(bob, "east")
    drain("alice")
    drain("bob")

    send_input(alice, "ping fountain")

    alice_out = drain("alice") |> Enum.join("\n")
    assert alice_out =~ "ping-from-tell"

    bob_out = drain("bob") |> Enum.join("\n")
    refute bob_out =~ "ping-from-tell"

    PlayerSession.stop(alice)
    PlayerSession.stop(bob)
  end

  test "Output.broadcast goes to bystanders, default-excludes actor", ctx do
    fountain_dir =
      with {:ok, schema} <- Schemas.load_dir_schema(clearing_uuid(ctx), ctx.store),
           {:ok, entry} <- Schema.get_entry(schema, "fountain.obj") do
        entry.node_id
      end

    src = """
    defmodule Commonplace.UserCode.Mud.Verb.FountainEmit do
      alias Commonplace.MUD.Output

      def run(ctx) do
        Output.broadcast(ctx, "broadcast-from-bcast")
        :ok
      end
    end
    """

    :ok = VerbSource.save_verb(fountain_dir, "emit", src, ctx.store)

    alice = start_player("alice", ctx)
    bob = start_player("bob", ctx)
    drain("alice")
    drain("bob")

    send_input(alice, "east")
    send_input(bob, "east")
    drain("alice")
    drain("bob")

    send_input(alice, "emit fountain")

    bob_out = drain("bob") |> Enum.join("\n")
    assert bob_out =~ "broadcast-from-bcast"

    alice_out = drain("alice") |> Enum.join("\n")
    refute alice_out =~ "broadcast-from-bcast"

    PlayerSession.stop(alice)
    PlayerSession.stop(bob)
  end

  test "@dump here renders the room (CX-vh3s)", ctx do
    alice = start_player("alice", ctx)
    drain("alice")

    send_input(alice, "@dump here")
    out = drain("alice") |> Enum.join("\n")
    assert out =~ "Start Room"

    PlayerSession.stop(alice)
  end

  test "look me renders the player's own description (CX-b54p)", ctx do
    alice = start_player("alice", ctx)
    drain("alice")

    send_input(alice, "look me")
    out = drain("alice") |> Enum.join("\n")
    assert out =~ "alice"
    assert out =~ "traveler"

    PlayerSession.stop(alice)
  end

  test "@dig and @name accept multi-word names (CX-eby7)", ctx do
    alice = start_player("alice", ctx)
    drain("alice")

    # CX-p0wx: "north" already has a seeded exit (to "A Forest Path"), and
    # @dig now refuses to clobber an existing exit — use a free direction
    # ("down") instead so this test still exercises multi-word @dig names.
    send_input(alice, "@dig down Old Stone Bridge")
    drain("alice")

    send_input(alice, "down")
    out = drain("alice") |> Enum.join("\n")
    assert out =~ "Old Stone Bridge"

    send_input(alice, "@name here North Forest Lookout")
    drain("alice")

    send_input(alice, "look")
    out2 = drain("alice") |> Enum.join("\n")
    assert out2 =~ "North Forest Lookout"

    PlayerSession.stop(alice)
  end

  test "verb_error appears once for the actor and once for bystanders (CX-7eqk)", ctx do
    fountain_dir =
      with {:ok, schema} <- Schemas.load_dir_schema(clearing_uuid(ctx), ctx.store),
           {:ok, entry} <- Schema.get_entry(schema, "fountain.obj") do
        entry.node_id
      end

    src = """
    defmodule Commonplace.UserCode.Mud.Verb.FountainBoom do
      def run(_ctx), do: raise "boom"
    end
    """

    :ok = VerbSource.save_verb(fountain_dir, "boom", src, ctx.store)

    alice = start_player("alice", ctx)
    bob = start_player("bob", ctx)
    drain("alice")
    drain("bob")

    send_input(alice, "east")
    send_input(bob, "east")
    drain("alice")
    drain("bob")

    send_input(alice, "boom fountain")

    alice_lines = drain("alice")
    crash_count_alice = Enum.count(alice_lines, fn l -> l =~ "boom" end)
    assert crash_count_alice == 1, "Actor saw #{crash_count_alice} crash messages, expected 1: #{inspect(alice_lines)}"

    bob_lines = drain("bob")
    crash_count_bob = Enum.count(bob_lines, fn l -> l =~ "boom" end)
    assert crash_count_bob == 1, "Bystander saw #{crash_count_bob} crash messages, expected 1: #{inspect(bob_lines)}"

    PlayerSession.stop(alice)
    PlayerSession.stop(bob)
  end
end
