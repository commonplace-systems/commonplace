defmodule Commonplace.MUD.VerbsDigLinkTest do
  @moduledoc """
  CX-p0wx: @dig onto an existing direction used to silently CLOBBER the
  exit — the old target room fell out of the tree with zero warning,
  and since relogin does NOT reset a player's location, a builder who
  clobbered their only exit was left permanently stranded with no
  in-game way back.

  These tests exercise the fix end-to-end through `PlayerSession` (same
  scaffolding as `verbs_multiword_test.exs` / `player_session_test.exs`):

    (a) @dig onto an existing exit is REFUSED, old exit intact, no orphan
    (b) @link points a dir at an existing room uuid and the player can
        then move that way
    (c) @teleport/@go moves the player to a room by uuid (recovery from
        a dead-end room, bypassing exits entirely)
    (d) @dig onto a FREE direction still works (no regression)
    (e) @unlink removes an exit if you built it
  """

  use ExUnit.Case

  alias Commonplace.MUD.{Bootstrap, PlayerSession}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_mud_diglink_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_dl_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    case GenServer.whereis(Commonplace.Green.Bursar) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, bursar_pid} =
      Commonplace.Green.Bursar.start_link(
        root_uuid: UUID.uuid4(),
        store: store_name,
        sweep_interval: 60_000
      )

    on_exit(fn -> if Process.alive?(bursar_pid), do: GenServer.stop(bursar_pid) end)

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
    Process.sleep(50)
  end

  # Pulls the target uuid for `dir` out of an `@dump here` reply, which
  # renders the room struct's `exits` map (e.g. `"up" => "abcd-uuid"`).
  defp extract_exit_uuid(dump_out, dir) do
    case Regex.run(~r/"#{dir}"\s*=>\s*"([^"]+)"/, dump_out) do
      [_, uuid] -> uuid
      nil -> nil
    end
  end

  test "@dig onto an existing exit is REFUSED, old exit intact, no orphan", ctx do
    alice = start_player("alice", ctx)

    # "north" already leads to "A Forest Path" (seeded by Bootstrap).
    send_input(alice, "@dig north Blocked Woods")
    dig_out = drain("alice") |> Enum.join("\n")

    assert dig_out =~ "already an exit north"
    refute dig_out =~ "Blocked Woods"

    # Old exit is intact — walking north still reaches the original room.
    send_input(alice, "north")
    move_out = drain("alice") |> Enum.join("\n")
    assert move_out =~ "A Forest Path"
    refute move_out =~ "Blocked Woods"
  end

  test "@dig onto a FREE direction still works (no regression)", ctx do
    alice = start_player("alice", ctx)

    send_input(alice, "@dig up The Tower")
    dig_out = drain("alice") |> Enum.join("\n")
    assert dig_out =~ "The Tower"

    send_input(alice, "up")
    move_out = drain("alice") |> Enum.join("\n")
    assert move_out =~ "The Tower"
  end

  test "@link points a dir at an existing room uuid and the player can then move that way", ctx do
    alice = start_player("alice", ctx)

    # Carve a room via a free direction, then read its uuid back off the
    # start room's exits (the same uuid @dump already exposes).
    send_input(alice, "@dig up The Tower")
    drain("alice")

    send_input(alice, "@dump here")
    dump_out = drain("alice") |> Enum.join("\n")
    tower_uuid = extract_exit_uuid(dump_out, "up")
    assert tower_uuid != nil

    # "west" is free in the seeded start room — link it to the Tower.
    send_input(alice, "@link west #{tower_uuid}")
    link_out = drain("alice") |> Enum.join("\n")
    assert link_out =~ "Linked west"
    assert link_out =~ "The Tower"

    send_input(alice, "west")
    move_out = drain("alice") |> Enum.join("\n")
    assert move_out =~ "The Tower"
  end

  test "@teleport (and its @go alias) moves the player to a room by uuid, recovering from a dead end", ctx do
    alice = start_player("alice", ctx)

    # Carve a small dead-end branch: start -up-> Tower -north-> Attic.
    send_input(alice, "@dig up The Tower")
    drain("alice")
    send_input(alice, "up")
    drain("alice")

    send_input(alice, "@dig north The Attic")
    drain("alice")
    send_input(alice, "north")
    drain("alice")

    # From the Attic (a dead end reachable only back the way we came),
    # @dump reveals the uuid of "The Start Room" via the reverse exit
    # chain: Attic's "south" exit points at the Tower, and the Tower's
    # own "down" exit (captured earlier) points at start. Simpler: dump
    # the Tower's exits while passing through it isn't needed — dump
    # here in Attic shows the Tower's uuid; instead we grab start's uuid
    # directly from the Tower on the way through.
    send_input(alice, "@teleport not-a-real-room-uuid")
    bad_out = drain("alice") |> Enum.join("\n")
    assert bad_out =~ "No such room"

    # Now get a REAL uuid: go back south into the Tower, dump its exits
    # to read start's uuid off the "down" exit, then teleport there
    # directly from the Attic (bypassing exits) to prove recovery works
    # from anywhere, not just from the room you're standing in.
    send_input(alice, "south")
    drain("alice")
    send_input(alice, "@dump here")
    tower_dump = drain("alice") |> Enum.join("\n")
    start_uuid = extract_exit_uuid(tower_dump, "down")
    assert start_uuid != nil

    send_input(alice, "north")
    drain("alice")

    send_input(alice, "@teleport #{start_uuid}")
    tp_out = drain("alice") |> Enum.join("\n")
    assert tp_out =~ "The Start Room"

    # @go is a builder alias for the same primitive.
    send_input(alice, "@dig down The Cellar")
    drain("alice")
    send_input(alice, "down")
    drain("alice")
    send_input(alice, "@dump here")
    cellar_dump = drain("alice") |> Enum.join("\n")
    start_uuid2 = extract_exit_uuid(cellar_dump, "up")
    assert start_uuid2 != nil

    send_input(alice, "@go #{start_uuid2}")
    go_out = drain("alice") |> Enum.join("\n")
    assert go_out =~ "The Start Room"
  end

  test "@unlink removes an exit if you built it", ctx do
    alice = start_player("alice", ctx)

    send_input(alice, "@dig down The Cellar")
    drain("alice")

    send_input(alice, "@unlink down")
    unlink_out = drain("alice") |> Enum.join("\n")
    assert unlink_out =~ "Removed the exit down"

    send_input(alice, "down")
    move_out = drain("alice") |> Enum.join("\n")
    assert move_out =~ "can't go down"

    # Unlinking a direction with no exit is a no-op, not an error.
    send_input(alice, "@unlink down")
    noop_out = drain("alice") |> Enum.join("\n")
    assert noop_out =~ "no exit down"
  end
end
