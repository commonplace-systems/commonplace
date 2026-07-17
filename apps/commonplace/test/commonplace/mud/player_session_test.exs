defmodule Commonplace.MUD.PlayerSessionTest do
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

    dir = Path.join(System.tmp_dir!(), "cp_mud_session_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

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
        store: store_name,
        sweep_interval: 60_000
      )

    on_exit(fn -> if Process.alive?(bursar_pid), do: (try do GenServer.stop(bursar_pid) catch (:exit, _ -> :ok) end) end)

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

  test "CX-3xwu: stopping a session retracts the player's presence — no ghost in the room roster", ctx do
    alice = start_player("alice", ctx)
    room = :sys.get_state(alice).current_room_uuid
    fname = Commonplace.Presence.filename("alice", :usr)

    # Present while the session is alive.
    assert presence_in_room?(room, fname, ctx.store)

    # GenServer.stop(:normal) runs terminate/2 synchronously before returning.
    PlayerSession.stop(alice)

    # Retracted on teardown — no lingering ghost. The persistent player
    # record under /players/alice/ is NOT touched (only the online marker).
    refute presence_in_room?(room, fname, ctx.store)

    {:ok, players_schema} =
      Commonplace.MUD.Schemas.load_dir_schema(ctx.root, ctx.store)

    assert match?({:ok, _}, Schema.get_entry(players_schema, "players")),
           "persistent /players record must survive a quit"
  end

  defp presence_in_room?(room_uuid, fname, store) do
    {:ok, schema} = Commonplace.MUD.Schemas.load_dir_schema(room_uuid, store)
    match?({:ok, _}, Schema.get_entry(schema, fname))
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

  # CX-gq7a: saving an empty (or '.' as the very first line) @verb body
  # used to crash the session — `VerbSource.save_verb` reached
  # `Yelixer.Types.Text.insert/4` with `text == ""`, which had no
  # no-op clause and raised `FunctionClauseError`. The fix validates at
  # the editor layer (player_session's save_verb) so a blank body is a
  # graceful message, never a crash — and the session must survive.
  describe "@verb editor: empty/'.' save (CX-gq7a)" do
    test "saving with an empty body reports a validation message and the session survives",
         ctx do
      alice = start_player("alice", ctx)
      drain("alice")

      send_input(alice, "@verb here:greet")
      drain("alice")

      # Type '.' immediately — no body lines at all.
      send_input(alice, ".")
      out = drain("alice") |> Enum.join("\n")

      assert out =~ "empty"
      assert Process.alive?(alice)

      # The session is still usable afterwards (didn't crash / restart
      # into a broken state).
      send_input(alice, "look")
      look_out = drain("alice") |> Enum.join("\n")
      assert look_out =~ "Start Room"

      PlayerSession.stop(alice)
    end

    test "saving a whitespace-only body also reports a validation message and survives",
         ctx do
      alice = start_player("alice", ctx)
      drain("alice")

      send_input(alice, "@verb here:greet2")
      drain("alice")

      send_input(alice, "   ")
      send_input(alice, ".")
      out = drain("alice") |> Enum.join("\n")

      assert out =~ "empty"
      assert Process.alive?(alice)

      PlayerSession.stop(alice)
    end

    # CX-bg1v/CX-fhz4: `@verb` now authors SAFE verbs (`.safe.elx`) via
    # `VerbSource.save_safe_verb/6` — a bare `run/2` BODY (no `defmodule`),
    # lint- and allowlist-checked, not the legacy ambient-store path. The
    # editor input is now a body using `world`/`args`, not a full module.
    test "saving a non-empty verb body still works", ctx do
      alice = start_player("alice", ctx)
      drain("alice")

      send_input(alice, "@verb here:greet3")
      drain("alice")

      send_input(alice, ~s|Commonplace.MUD.World.Facade.say(world, "hi")|)
      send_input(alice, ".")
      out = drain("alice") |> Enum.join("\n")

      assert out =~ "compiles cleanly"
      assert Process.alive?(alice)

      PlayerSession.stop(alice)
    end

    # CX-bg1v — the whole point: a dangerous body must be REJECTED at
    # save, never persisted, never compiled.
    test "saving a body with a dangerous operation is rejected", ctx do
      alice = start_player("alice", ctx)
      drain("alice")

      send_input(alice, "@verb here:greet4")
      drain("alice")

      send_input(alice, ~s|System.cmd("id", [])|)
      send_input(alice, ".")
      out = drain("alice") |> Enum.join("\n")

      assert out =~ "rejected"
      assert Process.alive?(alice)

      PlayerSession.stop(alice)
    end
  end

  # CX-hbb2 — the `@verb` editor's "Common calls" banner is now GENERATED
  # from the live safe-verb allowlist (`ApiDoc.render_calls/0`) instead of
  # hand-maintained prose, fixing the CX-hn75 discoverability bug where the
  # banner silently omitted open_exit/grant/spawn/consume/whisper/etc. This
  # pins the banner actually reaching the player and actually listing calls
  # the old hand-written text left out.
  test "@verb editor banner lists the FULL safe-verb API (CX-hbb2, was missing open_exit/grant before)",
       ctx do
    alice = start_player("alice", ctx)
    drain("alice")

    send_input(alice, "@verb here:newverb")
    out = drain("alice") |> Enum.join("\n")

    # Present pre-fix (sanity — the banner still works at all).
    assert out =~ "say("
    assert out =~ "put_state("

    # CX-hn75: these were MISSING from the old hand-written banner.
    assert out =~ "open_exit("
    assert out =~ "grant("
    assert out =~ "spawn("
    assert out =~ "consume("
    assert out =~ "whisper("

    PlayerSession.stop(alice)
  end
end
