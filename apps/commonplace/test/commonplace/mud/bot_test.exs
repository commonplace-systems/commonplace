defmodule Commonplace.MUD.BotTest do
  use ExUnit.Case

  alias Commonplace.MUD.{Bootstrap, Bot, MoveServer, PlayerSession}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_mud_bot_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    case GenServer.whereis({:global, MoveServer}) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, _} = MoveServer.start_link(store: store)
    on_exit(fn ->
      case GenServer.whereis({:global, MoveServer}) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end
    end)

    root_uuid = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root_uuid, update, nil)
    {:ok, _} = Bootstrap.seed(root_uuid, store)

    on_exit(fn ->
      Bot.stop("bartleby")
      Bot.stop("watcher")
    end)

    %{store: store, root: root_uuid}
  end

  defp human_player(name, ctx) do
    parent = self()
    output_fn = fn text -> send(parent, {:human, name, text}) end

    {:ok, session} =
      PlayerSession.start_link(
        player_name: name,
        root_uuid: ctx.root,
        store: ctx.store,
        output_fn: output_fn,
        owner_pid: parent
      )

    drain_human(name)
    session
  end

  defp drain_human(name) do
    receive do
      {:human, ^name, _} -> drain_human(name)
    after
      30 -> :ok
    end
  end

  test "bot.send_input spawns a session and returns the room render", ctx do
    {:ok, events} = Bot.send_input("bartleby", "look", store: ctx.store, root_uuid: ctx.root)
    text = Enum.join(events, "\n")
    assert text =~ "Start Room"
    assert text =~ "north"
  end

  test "bot session persists across calls; second send sees fewer events", ctx do
    {:ok, _greet_events} = Bot.send_input("bartleby", "look", store: ctx.store, root_uuid: ctx.root)
    {:ok, second} = Bot.send_input("bartleby", "look", store: ctx.store, root_uuid: ctx.root)
    text = Enum.join(second, "\n")
    assert text =~ "Start Room"
    # No greet event from a fresh session this time.
    refute text =~ "Welcome"
  end

  test "bot can walk the world and ends up in a different room", ctx do
    {:ok, _} = Bot.send_input("bartleby", "look", store: ctx.store, root_uuid: ctx.root)
    {:ok, events} = Bot.send_input("bartleby", "north", store: ctx.store, root_uuid: ctx.root)
    text = Enum.join(events, "\n")
    assert text =~ "Forest Path"
  end

  test "bot hears human player's say", ctx do
    {:ok, _} = Bot.send_input("bartleby", "look", store: ctx.store, root_uuid: ctx.root)
    alice = human_player("alice", ctx)
    PlayerSession.input_sync(alice, "say hello bartleby")
    Process.sleep(80)

    {:ok, events} = Bot.read_events("bartleby")
    text = Enum.join(events, "\n")
    assert text =~ "alice says, \"hello bartleby\""

    PlayerSession.stop(alice)
  end

  test "bot's say is heard by a human player in the same room", ctx do
    alice = human_player("alice", ctx)
    {:ok, _} = Bot.send_input("bartleby", "look", store: ctx.store, root_uuid: ctx.root)

    # Drain alice's mailbox first
    drain_human("alice")

    {:ok, _} = Bot.send_input("bartleby", "say hi alice", store: ctx.store, root_uuid: ctx.root)
    Process.sleep(80)

    received =
      Stream.repeatedly(fn ->
        receive do
          {:human, "alice", text} -> text
        after
          50 -> nil
        end
      end)
      |> Stream.take_while(& &1)
      |> Enum.to_list()
      |> Enum.join("\n")

    assert received =~ "bartleby says, \"hi alice\""

    PlayerSession.stop(alice)
  end

  test "bot can take an object and see it in inventory", ctx do
    {:ok, _} = Bot.send_input("bartleby", "look", store: ctx.store, root_uuid: ctx.root)
    {:ok, take_events} = Bot.send_input("bartleby", "take cloak", store: ctx.store, root_uuid: ctx.root)
    take_text = Enum.join(take_events, "\n")
    assert take_text =~ "You take cloak"

    {:ok, inv_events} = Bot.send_input("bartleby", "inventory", store: ctx.store, root_uuid: ctx.root)
    inv_text = Enum.join(inv_events, "\n")
    assert inv_text =~ "cloak"
  end
end
