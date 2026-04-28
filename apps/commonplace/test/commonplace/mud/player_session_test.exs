defmodule Commonplace.MUD.PlayerSessionTest do
  use ExUnit.Case

  alias Commonplace.MUD.{Bootstrap, MoveServer, PlayerSession}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_mud_session_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    # Register MoveServer at the global name so World.move/4 routes to it.
    case GenServer.whereis({:global, MoveServer}) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, _} = MoveServer.start_link(store: store_name)
    on_exit(fn ->
      case GenServer.whereis({:global, MoveServer}) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end
    end)

    root_uuid = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    {:ok, _} = Bootstrap.seed(root_uuid, store_name)

    %{store: store_name, root: root_uuid}
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
    # Give PubSub broadcasts time to fan out to other sessions
    Process.sleep(50)
  end

  test "player can look around in seeded world", ctx do
    alice = start_player("alice", ctx)
    send_input(alice, "look")
    out = drain("alice")
    output = Enum.join(out, "\n")
    assert output =~ "Start Room"
    assert output =~ "north"
    assert output =~ "east"
  end

  test "two players in the same room see each other on say", ctx do
    alice = start_player("alice", ctx)
    bob = start_player("bob", ctx)
    drain("alice")
    drain("bob")

    send_input(alice, "say hello bob")
    Process.sleep(80)

    bob_out = drain("bob") |> Enum.join("\n")
    assert bob_out =~ "alice says, \"hello bob\""

    alice_out = drain("alice") |> Enum.join("\n")
    assert alice_out =~ "You say, \"hello bob\""

    PlayerSession.stop(alice)
    PlayerSession.stop(bob)
  end

  test "alice walks north and bob sees her depart", ctx do
    alice = start_player("alice", ctx)
    bob = start_player("bob", ctx)
    drain("alice")
    drain("bob")

    send_input(alice, "north")
    Process.sleep(80)

    bob_out = drain("bob") |> Enum.join("\n")
    assert bob_out =~ "alice leaves to the north"

    alice_out = drain("alice") |> Enum.join("\n")
    assert alice_out =~ "Forest Path"

    PlayerSession.stop(alice)
    PlayerSession.stop(bob)
  end

  test "alice takes the cloak; bob sees the action and can't take it after", ctx do
    alice = start_player("alice", ctx)
    bob = start_player("bob", ctx)
    drain("alice")
    drain("bob")

    send_input(alice, "take cloak")
    Process.sleep(80)

    alice_out = drain("alice") |> Enum.join("\n")
    assert alice_out =~ "You take cloak"

    bob_out = drain("bob") |> Enum.join("\n")
    assert bob_out =~ "alice takes cloak"

    send_input(bob, "take cloak")
    Process.sleep(80)
    bob_take_out = drain("bob") |> Enum.join("\n")
    assert bob_take_out =~ "don't see"

    PlayerSession.stop(alice)
    PlayerSession.stop(bob)
  end

  test "alice gives cloak to bob, bob sees it in inventory", ctx do
    alice = start_player("alice", ctx)
    bob = start_player("bob", ctx)
    drain("alice")
    drain("bob")

    send_input(alice, "take cloak")
    Process.sleep(80)
    drain("alice")
    drain("bob")

    send_input(alice, "give cloak bob")
    Process.sleep(80)

    alice_out = drain("alice") |> Enum.join("\n")
    assert alice_out =~ "You give cloak to bob"

    bob_out = drain("bob") |> Enum.join("\n")
    assert bob_out =~ "alice gives you cloak"

    send_input(bob, "inventory")
    Process.sleep(40)
    bob_inv = drain("bob") |> Enum.join("\n")
    assert bob_inv =~ "cloak"

    PlayerSession.stop(alice)
    PlayerSession.stop(bob)
  end
end
