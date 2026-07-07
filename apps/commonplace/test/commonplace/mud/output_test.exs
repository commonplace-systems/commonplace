defmodule Commonplace.MUD.OutputTest do
  use ExUnit.Case

  alias Commonplace.Code.SourceDoc
  alias Commonplace.MUD.{Bootstrap, Output, PlayerSession, Schemas, VerbSource}
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

  # CX-qom0: this now unit-tests `Commonplace.MUD.Output.tell/2` directly
  # instead of routing through a player-dispatched LEGACY (full-defmodule)
  # verb — a legacy `.elx` is no longer player-dispatchable (gated by
  # `require_safe_wrapper: true`, see `Verbs.run_legacy_user_verb/5`), and
  # there is no facade method exposing actor-only tell (by design: it's a
  # thin ctx-shaped wrapper over `World.tell/2`, not a verb-authorable
  # effect). Real `PlayerSession`s still back the two listeners so the
  # full PubSub delivery path (`Topics.subscribe_player_tell/1` +
  # `render_event/2`) is exercised end-to-end, same as before — only the
  # "how do we call Output" vehicle changed.
  test "Output.tell sends a string to the actor only", ctx do
    alice = start_player("alice", ctx)
    bob = start_player("bob", ctx)
    drain("alice")
    drain("bob")

    alice_state = :sys.get_state(alice)

    Output.tell(%{player_uuid: alice_state.player_uuid}, "ping-from-tell")
    Process.sleep(60)

    alice_out = drain("alice") |> Enum.join("\n")
    assert alice_out =~ "ping-from-tell"

    bob_out = drain("bob") |> Enum.join("\n")
    refute bob_out =~ "ping-from-tell"

    PlayerSession.stop(alice)
    PlayerSession.stop(bob)
  end

  # CX-qom0: same migration rationale as the `tell` test above — unit-tests
  # `Output.broadcast/3` directly. Alice and bob both walk into the
  # clearing first so they share a room (`current_room_uuid`), mirroring
  # the shared-room setup the legacy-verb vehicle used to establish.
  test "Output.broadcast goes to bystanders, default-excludes actor", ctx do
    alice = start_player("alice", ctx)
    bob = start_player("bob", ctx)
    drain("alice")
    drain("bob")

    send_input(alice, "east")
    send_input(bob, "east")
    drain("alice")
    drain("bob")

    alice_state = :sys.get_state(alice)

    Output.broadcast(
      %{current_room_uuid: alice_state.current_room_uuid, player_uuid: alice_state.player_uuid},
      "broadcast-from-bcast"
    )

    Process.sleep(60)

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

  # CX-qom0: migrated from a player-dispatched LEGACY (full-defmodule)
  # crashing verb to a SAFE verb — a legacy `.elx` is no longer
  # player-dispatchable. The allowlist admits no `raise`, so the crash
  # vehicle is a plain allowlist-clean runtime error (`1 / 0`) instead;
  # the crash still flows through `map_safe_result/3`'s
  # `{:error, {:runtime_error, _}}` arm, same emit_verb_error shape as the
  # legacy path exercised.
  test "verb_error appears once for the actor and once for bystanders (CX-7eqk)", ctx do
    fountain_dir =
      with {:ok, schema} <- Schemas.load_dir_schema(clearing_uuid(ctx), ctx.store),
           {:ok, entry} <- Schema.get_entry(schema, "fountain.obj") do
        entry.node_id
      end

    :ok = VerbSource.save_safe_verb(fountain_dir, "boom", "1 / 0", [fountain_dir], ctx.store)

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

  defp fountain_dir(ctx) do
    with {:ok, schema} <- Schemas.load_dir_schema(clearing_uuid(ctx), ctx.store),
         {:ok, entry} <- Schema.get_entry(schema, "fountain.obj") do
      entry.node_id
    end
  end

  # CX-9plf: args.rest is the command tail with the object noun stripped,
  # so a parameterized verb reads its param without re-stripping the noun.
  test "CX-9plf: args.rest is the command tail after the object noun", ctx do
    dir = fountain_dir(ctx)

    :ok =
      VerbSource.save_safe_verb(
        dir,
        "echo",
        ~s|Commonplace.MUD.World.Facade.say(world, args.rest)|,
        [dir],
        ctx.store
      )

    alice = start_player("alice", ctx)
    drain("alice")
    send_input(alice, "east")
    drain("alice")

    send_input(alice, "echo fountain hello there")
    out = drain("alice") |> Enum.join("\n")
    assert out =~ "hello there"
    refute out =~ "fountain hello there"

    PlayerSession.stop(alice)
  end

  # CX-aw4r: emit_action attributes an action per-recipient — the actor
  # reads "You <first_person>", observers read "<name> <third_person>".
  test "CX-aw4r: emit_action attributes the actor (You / <name>)", ctx do
    dir = fountain_dir(ctx)

    :ok =
      VerbSource.save_safe_verb(
        dir,
        "play",
        ~s|Commonplace.MUD.World.Facade.emit_action(world, "lift the lid", "lifts the lid")|,
        [dir],
        ctx.store
      )

    alice = start_player("alice", ctx)
    bob = start_player("bob", ctx)
    drain("alice")
    drain("bob")
    send_input(alice, "east")
    send_input(bob, "east")
    drain("alice")
    drain("bob")

    send_input(alice, "play fountain")

    alice_out = drain("alice") |> Enum.join("\n")
    assert alice_out =~ "You lift the lid"
    refute alice_out =~ "alice lifts the lid"

    bob_out = drain("bob") |> Enum.join("\n")
    assert bob_out =~ "alice lifts the lid"
    refute bob_out =~ "You lift the lid"

    PlayerSession.stop(alice)
    PlayerSession.stop(bob)
  end

  # CX-aw4r impersonation fix: Facade.emit is server-stamped kind: :custom,
  # so an author cannot forge a first-class attributed event (kind: :say
  # with a chosen `who`) that render_event pins on a victim. The text
  # still broadcasts (emit's purpose), but UNATTRIBUTED.
  test "CX-aw4r: Facade.emit cannot forge an attributed event onto another player", ctx do
    dir = fountain_dir(ctx)

    :ok =
      VerbSource.save_safe_verb(
        dir,
        "forge",
        ~s|Commonplace.MUD.World.Facade.emit(world, %{kind: :say, who: "victim", text: "I surrender"})|,
        [dir],
        ctx.store
      )

    alice = start_player("alice", ctx)
    bob = start_player("bob", ctx)
    drain("alice")
    drain("bob")
    send_input(alice, "east")
    send_input(bob, "east")
    drain("alice")
    drain("bob")

    send_input(alice, "forge fountain")

    bob_out = drain("bob") |> Enum.join("\n")
    refute bob_out =~ "victim says"
    assert bob_out =~ "I surrender"

    PlayerSession.stop(alice)
    PlayerSession.stop(bob)
  end

  # CX-cj3t.8 (safe half) — mechanical locks: a container is LOCKED iff
  # meta["state"]["locked"] == true, the SAME submap Facade.put_state/3
  # writes. A locked container refuses get-from/put-in/look-in with a
  # clear message; a safe verb calling put_state(world, "locked", false)
  # is a "key" that unlocks it (the composition the design is built on).
  describe "CX-cj3t.8: mechanical locks (safe half)" do
    defp box_dir(ctx) do
      # CX-3hii — @create now keys objects "box-<short-uuid>.obj" (instance-
      # unique), so resolve by display name rather than an exact "box.obj".
      {:ok, entry} = Commonplace.MUD.World.find_entry_by_name(clearing_uuid(ctx), "box", ctx.store)
      entry.node_id
    end

    defp lock_box(ctx, locked?) do
      dir = box_dir(ctx)

      :ok =
        VerbSource.save_safe_verb(
          dir,
          "setlock",
          ~s|Commonplace.MUD.World.Facade.put_state(world, "locked", #{locked?})|,
          [dir],
          ctx.store
        )

      dir
    end

    test "locked container refuses get-from, put-in, and look-in", ctx do
      alice = start_player("alice", ctx)
      drain("alice")
      send_input(alice, "east")
      drain("alice")

      send_input(alice, "@create container box")
      drain("alice")
      send_input(alice, "@create object coin")
      drain("alice")
      send_input(alice, "put coin in box")
      drain("alice")

      lock_box(ctx, true)
      send_input(alice, "setlock box")
      drain("alice")

      send_input(alice, "get coin from box")
      get_out = drain("alice") |> Enum.join("\n")
      assert get_out =~ "is locked"

      send_input(alice, "@create object key")
      drain("alice")
      send_input(alice, "put key in box")
      put_out = drain("alice") |> Enum.join("\n")
      assert put_out =~ "is locked"

      send_input(alice, "look in box")
      look_out = drain("alice") |> Enum.join("\n")
      # CX-hbbi — look on a sealed (locked/key-gated) container now reads "sealed".
      assert look_out =~ "is sealed"
      refute look_out =~ "contains"

      PlayerSession.stop(alice)
    end

    test "a safe verb calling put_state(world, \"locked\", false) unlocks the container (the key composition)",
         ctx do
      alice = start_player("alice", ctx)
      drain("alice")
      send_input(alice, "east")
      drain("alice")

      send_input(alice, "@create container box")
      drain("alice")
      send_input(alice, "@create object coin")
      drain("alice")
      send_input(alice, "put coin in box")
      drain("alice")

      dir = lock_box(ctx, true)
      send_input(alice, "setlock box")
      drain("alice")

      send_input(alice, "get coin from box")
      locked_out = drain("alice") |> Enum.join("\n")
      assert locked_out =~ "is locked"

      # the "key": a safe verb that calls put_state(world, "locked", false)
      :ok =
        VerbSource.save_safe_verb(
          dir,
          "unlock",
          ~s|Commonplace.MUD.World.Facade.put_state(world, "locked", false)|,
          [dir],
          ctx.store
        )

      send_input(alice, "unlock box")
      drain("alice")

      send_input(alice, "get coin from box")
      unlocked_out = drain("alice") |> Enum.join("\n")
      assert unlocked_out =~ "You get coin from box."

      send_input(alice, "put coin in box")
      put_out = drain("alice") |> Enum.join("\n")
      assert put_out =~ "You put coin in box."

      send_input(alice, "look in box")
      look_out = drain("alice") |> Enum.join("\n")
      assert look_out =~ "contains: coin"

      PlayerSession.stop(alice)
    end

    test "CX-qexv: a verb whose tail put_state is over-budget surfaces :state_bounds to the actor (not silent)",
         ctx do
      alice = start_player("alice", ctx)
      drain("alice")
      send_input(alice, "east")
      drain("alice")

      send_input(alice, "@create object gizmo")
      drain("alice")

      {:ok, entry} = Commonplace.MUD.World.find_entry_by_name(clearing_uuid(ctx), "gizmo", ctx.store)
      dir = entry.node_id

      # The verb's TAIL expression is a put_state with a >1024-byte value —
      # a literal big string in the body, so it saves fine but the write
      # returns {:error, :state_bounds}. Pre-CX-qexv the {:ok, _} dispatch
      # arm swallowed it; now it must reach the actor.
      big = String.duplicate("z", 1100)

      :ok =
        VerbSource.save_safe_verb(
          dir,
          "overflow",
          ~s|Commonplace.MUD.World.Facade.put_state(world, "blob", "#{big}")|,
          [dir],
          ctx.store
        )

      send_input(alice, "overflow gizmo")
      out = drain("alice") |> Enum.join("\n")
      assert out =~ "state value rejected"

      PlayerSession.stop(alice)
    end

    test "a never-locked container behaves exactly as before (regression)", ctx do
      alice = start_player("alice", ctx)
      drain("alice")
      send_input(alice, "east")
      drain("alice")

      send_input(alice, "@create container crate")
      drain("alice")
      send_input(alice, "@create object apple")
      drain("alice")

      send_input(alice, "put apple in crate")
      put_out = drain("alice") |> Enum.join("\n")
      assert put_out =~ "You put apple in crate."

      send_input(alice, "look in crate")
      look_out = drain("alice") |> Enum.join("\n")
      assert look_out =~ "contains: apple"

      send_input(alice, "get apple from crate")
      get_out = drain("alice") |> Enum.join("\n")
      assert get_out =~ "You get apple from crate."

      PlayerSession.stop(alice)
    end

    # CX-uwam — declarative lock_key: the builtin take-from is gated on the
    # TAKER holding a matching item (per-player), airtight against the greedy
    # take-from path (the "lock is theater" fix). CX-hbbi — a sealed container
    # hides contents on plain `look`.
    test "CX-uwam/CX-hbbi: lock_key gates take-from per-player; sealed container hides contents on look", ctx do
      alice = start_player("alice", ctx)
      drain("alice")
      send_input(alice, "east")
      drain("alice")

      send_input(alice, "@create container vault")
      drain("alice")
      send_input(alice, "@create object gold")
      drain("alice")
      send_input(alice, "put gold in vault")
      drain("alice")

      # Seal the vault with lock_key = "brass key" via a verb on it.
      {:ok, vault_entry} = Commonplace.MUD.World.find_entry_by_name(clearing_uuid(ctx), "vault", ctx.store)

      :ok =
        VerbSource.save_safe_verb(
          vault_entry.node_id,
          "seal",
          ~s|Commonplace.MUD.World.Facade.put_state(world, "lock_key", "brass key")|,
          [vault_entry.node_id],
          ctx.store
        )

      send_input(alice, "seal vault")
      drain("alice")

      # CX-hbbi — plain look on the sealed vault hides contents.
      send_input(alice, "look vault")
      look_out = drain("alice") |> Enum.join("\n")
      assert look_out =~ "is sealed"
      refute look_out =~ "contains"

      # No key held → take-from refused (the greedy path is now closed).
      send_input(alice, "get gold from vault")
      refused = drain("alice") |> Enum.join("\n")
      assert refused =~ "you need the brass key"
      refute refused =~ "You get gold"

      # Acquire the key, then take-from succeeds (per-player gate opens).
      send_input(alice, "@create object brass key")
      drain("alice")
      send_input(alice, "take brass key")
      drain("alice")

      send_input(alice, "get gold from vault")
      allowed = drain("alice") |> Enum.join("\n")
      assert allowed =~ "You get gold from vault."

      PlayerSession.stop(alice)
    end
  end

  # CX-cj3t.10 — directed private messaging (plan #6050). Three trust
  # properties under test: same-room-only resolution (privacy — a
  # bystander never sees a whisper), server-stamped attribution (the
  # recipient sees the INVOKER's name, never author-supplied), and the
  # per-target rate cap (harassment bound without breaking legit
  # one-to-many).
  describe "CX-cj3t.10: directed messaging (whisper)" do
    test "whisper reaches the target but not a bystander in the same room", ctx do
      dir = fountain_dir(ctx)

      :ok =
        VerbSource.save_safe_verb(
          dir,
          "psst",
          ~s|Commonplace.MUD.World.Facade.whisper(world, "bob", "psst")|,
          [dir],
          ctx.store
        )

      alice = start_player("alice", ctx)
      bob = start_player("bob", ctx)
      carol = start_player("carol", ctx)
      drain("alice")
      drain("bob")
      drain("carol")

      send_input(alice, "east")
      send_input(bob, "east")
      send_input(carol, "east")
      drain("alice")
      drain("bob")
      drain("carol")

      send_input(alice, "psst fountain")

      bob_out = drain("bob") |> Enum.join("\n")
      assert bob_out =~ "psst"
      assert bob_out =~ "alice whispers"

      carol_out = drain("carol") |> Enum.join("\n")
      refute carol_out =~ "psst"

      PlayerSession.stop(alice)
      PlayerSession.stop(bob)
      PlayerSession.stop(carol)
    end

    test "property 1: whispering a name not in the room returns :not_here (never a global oracle)", ctx do
      alice = start_player("alice", ctx)
      drain("alice")
      send_input(alice, "east")
      drain("alice")

      alice_state = :sys.get_state(alice)
      facade_ctx = %{current_room_uuid: alice_state.current_room_uuid, player_name: "alice"}
      facade = Commonplace.MUD.World.Facade.new(facade_ctx, nil, [], nil, ctx.store)

      assert {:error, :not_here} = Commonplace.MUD.World.Facade.whisper(facade, "nobody", "hello?")

      PlayerSession.stop(alice)
    end

    test "property 3: per-target rate cap allows 3 whispers to one target then rate-limits the 4th", ctx do
      alice = start_player("alice", ctx)
      bob = start_player("bob", ctx)
      drain("alice")
      drain("bob")

      send_input(alice, "east")
      send_input(bob, "east")
      drain("alice")
      drain("bob")

      alice_state = :sys.get_state(alice)
      facade_ctx = %{current_room_uuid: alice_state.current_room_uuid, player_name: "alice"}
      facade = Commonplace.MUD.World.Facade.new(facade_ctx, nil, [], nil, ctx.store)

      assert :ok = Commonplace.MUD.World.Facade.whisper(facade, "bob", "msg-1")
      assert :ok = Commonplace.MUD.World.Facade.whisper(facade, "bob", "msg-2")
      assert :ok = Commonplace.MUD.World.Facade.whisper(facade, "bob", "msg-3")

      assert {:error, :rate_limited} = Commonplace.MUD.World.Facade.whisper(facade, "bob", "msg-4")

      Process.sleep(60)
      bob_lines = drain("bob")
      delivered = Enum.count(bob_lines, &(&1 =~ "whispers"))
      assert delivered == 3, "expected exactly 3 delivered whispers, got: #{inspect(bob_lines)}"

      PlayerSession.stop(alice)
      PlayerSession.stop(bob)
    end
  end
end
