defmodule Commonplace.MUD.OutputTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias Commonplace.Code.SourceDoc
  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.MUD.{Bootstrap, Output, PlayerSession, Schemas, VerbSource}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  # CX-3x5a output-hygiene — a throwaway signed identity, for tests that
  # need a real (non-nil) `identity_uuid` to exercise the author-match /
  # non-author-suppress split on the `:verb_diagnostic` player tell.
  defp fresh_identity(tag) do
    {pub, priv} = Signing.generate_keypair()
    %SigningContext{identity_uuid: "#{tag}-#{:rand.uniform(999_999_999_999)}", private_key: priv, public_key: pub}
  end

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

  defp start_player(name, ctx, parent \\ self(), opts \\ []) do
    output_fn = fn text -> send(parent, {:out, name, text}) end

    {:ok, session} =
      PlayerSession.start_link(
        Keyword.merge(
          [
            player_name: name,
            root_uuid: ctx.root,
            store: ctx.store,
            output_fn: output_fn,
            owner_pid: parent
          ],
          opts
        )
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

  # CX-ydmv: emote text is author-written THIRD-person; the actor's own
  # self-echo must render "<name> <text>" (NOT "You <text>", which would be the
  # grammatically-broken "You sets the jar down"), matching what the room sees.
  test "emote self-echo shows the actor's NAME, not 'You' (third-person text stays grammatical)", ctx do
    alice = start_player("alice", ctx)
    bob = start_player("bob", ctx)
    drain("alice")
    drain("bob")

    send_input(alice, "east")
    send_input(bob, "east")
    drain("alice")
    drain("bob")

    send_input(alice, "emote sets the firefly jar down")

    alice_out = drain("alice") |> Enum.join("\n")
    bob_out = drain("bob") |> Enum.join("\n")

    # The actor sees the NAME form, never the broken "You sets ...".
    assert alice_out =~ "alice sets the firefly jar down"
    refute alice_out =~ "You sets"
    # And it matches exactly what the room already broadcast to observers.
    assert bob_out =~ "alice sets the firefly jar down"

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

    test "CX-qexv/CX-3x5a: a verb whose tail put_state is over-budget surfaces a DIM :verb_diagnostic to the actor (not silent)",
         ctx do
      # CX-3x5a output-hygiene: the player tell is now author-scoped, so
      # alice must be the verb's AUTHOR (same signing identity on both the
      # player session and the saved verb source) for the diagnostic to
      # reach her — see the "non-author invoker" test below for the
      # suppressed case.
      alice_ctx = fresh_identity("alice")
      alice = start_player("alice", ctx, self(), signing_context: alice_ctx)
      drain("alice")
      send_input(alice, "east")
      drain("alice")

      send_input(alice, "@create object gizmo")
      drain("alice")

      {:ok, entry} = Commonplace.MUD.World.find_entry_by_name(clearing_uuid(ctx), "gizmo", ctx.store)
      dir = entry.node_id

      # The verb's TAIL expression is a put_state with a >1024-byte value —
      # a literal big string in the body, so it saves fine but the write
      # returns {:error, :state_bounds}. CX-3x5a retired the dedicated
      # {:ok, {:error, :state_bounds}} arm: the drop now flows through the
      # facade accumulator and reaches the actor as a DIM author-diagnostic
      # ("(verb note: put_state → state_bounds)") instead of a loud reply.
      big = String.duplicate("z", 1100)

      :ok =
        VerbSource.save_safe_verb(
          dir,
          "overflow",
          ~s|Commonplace.MUD.World.Facade.put_state(world, "blob", "#{big}")|,
          [dir],
          ctx.store,
          signing_context: alice_ctx
        )

      send_input(alice, "overflow gizmo")
      out = drain("alice") |> Enum.join("\n")
      assert out =~ "verb note"
      assert out =~ "put_state"
      assert out =~ "state_bounds"

      PlayerSession.stop(alice)
    end

    test "CX-drp2 REPRO: a NON-last put_state persists through real dispatch (the 'must be last' model is FALSE)",
         ctx do
      alice = start_player("alice", ctx)
      drain("alice")
      send_input(alice, "east")
      drain("alice")

      send_input(alice, "@create object gadget")
      drain("alice")

      {:ok, entry} = Commonplace.MUD.World.find_entry_by_name(clearing_uuid(ctx), "gadget", ctx.store)
      dir = entry.node_id

      # "first" is written, THEN a say, THEN "second" — so "first" is NOT the
      # verb's final expression. CX-drp2's reported model says a non-last
      # put_state is silently discarded; if that were true "first" would be
      # gone. put_state commits immediately (set_meta), position-independent,
      # so BOTH must persist.
      body =
        ~s|Commonplace.MUD.World.Facade.put_state(world, "first", "A")\n| <>
          ~s|Commonplace.MUD.World.Facade.say(world, "midway")\n| <>
          ~s|Commonplace.MUD.World.Facade.put_state(world, "second", "B")|

      :ok = VerbSource.save_safe_verb(dir, "multiwrite", body, [dir], ctx.store)

      send_input(alice, "multiwrite gadget")
      drain("alice")

      {:ok, meta} = Commonplace.MUD.World.get_meta_map(dir, Schemas.object_filename(), ctx.store)
      state = meta["state"] || %{}
      assert state["first"] == "A", "NON-last put_state was discarded — 'must be last' model would be REAL"
      assert state["second"] == "B"

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

  describe "CX-ylge / CX-a3rq: room-verb dispatch + object-host guard surfacing" do
    test "CX-ylge: a room verb fires even when its first arg NAMES an in-room object", ctx do
      alice = start_player("alice", ctx)
      drain("alice")
      send_input(alice, "east")
      drain("alice")

      # An in-room object whose NAME will be the verb's argument.
      send_input(alice, "@create object statue")
      drain("alice")

      # A ROOM ("here:") verb — authored on the current room, not on any object.
      room = clearing_uuid(ctx)

      :ok =
        VerbSource.save_safe_verb(
          room,
          "probemove",
          ~s|Commonplace.MUD.World.Facade.say(world, "ROOMVERB-FIRED:" <> args.target)|,
          [room],
          ctx.store
        )

      # Arg is a NON-object word → room verb already worked (control).
      send_input(alice, "probemove xyzzy")
      control = drain("alice") |> Enum.join("\n")
      assert control =~ "ROOMVERB-FIRED:xyzzy"

      # Arg NAMES an in-room object → pre-fix this died as "I don't understand
      # that" (the object-name shadowed the room verb). Now it must fire.
      send_input(alice, "probemove statue")
      out = drain("alice") |> Enum.join("\n")
      assert out =~ "ROOMVERB-FIRED:statue"
      refute out =~ "don't understand"

      PlayerSession.stop(alice)
    end

    test "CX-a3rq/CX-3x5a: a room verb calling an object-only effect surfaces a DIM :verb_diagnostic to the actor", ctx do
      # CX-3x5a output-hygiene: author-scoped player tell, so alice must be
      # the verb's author here too (see fresh_identity/1 note above).
      alice_ctx = fresh_identity("alice")
      alice = start_player("alice", ctx, self(), signing_context: alice_ctx)
      drain("alice")
      send_input(alice, "east")
      drain("alice")

      room = clearing_uuid(ctx)

      # consume/2 is object-host only; on a ROOM host the facade refuses with
      # :requires_object_host. Pre-CX-a3rq that was a silent no-op; CX-3x5a
      # retired the dedicated {:ok, {:error, :requires_object_host}} arm and
      # the drop now reaches the actor as a DIM author-diagnostic
      # ("(verb note: consume → requires_object_host)").
      :ok =
        VerbSource.save_safe_verb(
          room,
          "vanish",
          ~s|Commonplace.MUD.World.Facade.consume(world)|,
          [room],
          ctx.store,
          signing_context: alice_ctx
        )

      send_input(alice, "vanish")
      out = drain("alice") |> Enum.join("\n")
      assert out =~ "verb note"
      assert out =~ "consume"
      assert out =~ "requires_object_host"

      PlayerSession.stop(alice)
    end
  end

  # CX-3x5a — the drop accumulator's END-TO-END guarantee: a facade
  # {:error, _} that a verb SILENTLY DROPS (ignores the return and keeps
  # going) becomes VISIBLE to the invoker as a DIM :verb_diagnostic line —
  # NOT a loud gameplay reply, and only reaching the caller. And N3: a pure
  # read returning nil/false is normal control flow, NOT a drop, so it emits
  # NOTHING.
  describe "CX-3x5a: silent-drop author diagnostics" do
    test "a verb that IGNORES a failing put_state (non-tail) then says → invoker sees the dim diagnostic", ctx do
      # CX-3x5a output-hygiene: author-scoped player tell, so alice must be
      # the verb's author here too (see fresh_identity/1 note above).
      alice_ctx = fresh_identity("alice")
      alice = start_player("alice", ctx, self(), signing_context: alice_ctx)
      drain("alice")
      send_input(alice, "east")
      drain("alice")

      send_input(alice, "@create object widget")
      drain("alice")

      {:ok, entry} = Commonplace.MUD.World.find_entry_by_name(clearing_uuid(ctx), "widget", ctx.store)
      dir = entry.node_id

      # The put_state over-budget error is DROPPED (its return ignored); the
      # verb continues to say something and returns the say's :ok. Pre-3x5a
      # the intermediate error vanished entirely (map_safe_result only ever
      # saw the TAIL). Now the accumulator surfaces it as a dim note to the
      # invoker, ALONGSIDE the normal gameplay say.
      big = String.duplicate("z", 1100)

      :ok =
        VerbSource.save_safe_verb(
          dir,
          "leak",
          ~s|Commonplace.MUD.World.Facade.put_state(world, "blob", "#{big}")\n  Commonplace.MUD.World.Facade.say(world, "hello there")|,
          [dir],
          ctx.store,
          signing_context: alice_ctx
        )

      send_input(alice, "leak widget")
      out = drain("alice") |> Enum.join("\n")
      # The gameplay say still happens...
      assert out =~ "hello there"
      # ...AND the dropped error is now visible as a dim author-diagnostic.
      assert out =~ "verb note"
      assert out =~ "put_state"
      assert out =~ "state_bounds"

      PlayerSession.stop(alice)
    end

    test "N3: a verb whose get_state is nil / actor_carries? is false emits NO diagnostic (normal control flow)", ctx do
      alice = start_player("alice", ctx)
      drain("alice")
      send_input(alice, "east")
      drain("alice")

      send_input(alice, "@create object doohickey")
      drain("alice")

      {:ok, entry} = Commonplace.MUD.World.find_entry_by_name(clearing_uuid(ctx), "doohickey", ctx.store)
      dir = entry.node_id

      # get_state on a missing key returns nil; actor_carries? on a not-held
      # item returns false — BOTH are normal reads, NOT {:error, _}, so the
      # accumulator records nothing and no diagnostic is emitted.
      :ok =
        VerbSource.save_safe_verb(
          dir,
          "peek",
          ~s|_ = Commonplace.MUD.World.Facade.get_state(world, "never-set")\n  _ = Commonplace.MUD.World.Facade.actor_carries?(world, "nonexistent-thing")\n  Commonplace.MUD.World.Facade.say(world, "all clear")|,
          [dir],
          ctx.store
        )

      send_input(alice, "peek doohickey")
      out = drain("alice") |> Enum.join("\n")
      assert out =~ "all clear"
      refute out =~ "verb note"

      PlayerSession.stop(alice)
    end
  end

  # CX-3x5a output-hygiene fix — `emit_author_diagnostic/2`'s player tell is
  # now scoped to "is the invoker the verb's author": a non-author invoker
  # (the common case for a shared/curated verb) can't act on verb-debug
  # jargon like "(verb note: consume → requires_object_host)", so it must
  # be suppressed FROM THE PLAYER while staying loud on the ops side
  # (`Logger.warning`, unconditional — the CX-3x5a guarantee this bead is
  # about is ops visibility, not player visibility).
  describe "CX-3x5a output-hygiene: author-scoped :verb_diagnostic player tell" do
    test "NON-AUTHOR invoker + author-class drop → no player tell, but the drop IS logged", ctx do
      author_ctx = fresh_identity("author")
      alice_ctx = fresh_identity("alice")
      alice = start_player("alice", ctx, self(), signing_context: alice_ctx)
      drain("alice")
      send_input(alice, "east")
      drain("alice")

      room = clearing_uuid(ctx)

      # consume/2 on a ROOM host always drops :requires_object_host — same
      # deterministic author-class drop the CX-a3rq test above exercises,
      # but here the verb source is authored by a DIFFERENT identity than
      # the invoker.
      :ok =
        VerbSource.save_safe_verb(
          room,
          "vanish2",
          ~s|Commonplace.MUD.World.Facade.consume(world)|,
          [room],
          ctx.store,
          signing_context: author_ctx
        )

      out =
        capture_log(fn ->
          send_input(alice, "vanish2")
          send(self(), {:captured, drain("alice") |> Enum.join("\n")})
        end)

      assert_received {:captured, player_out}
      refute player_out =~ "verb note"
      refute player_out =~ "requires_object_host"

      assert out =~ "safe-verb author diagnostic"
      assert out =~ "consume"
      assert out =~ "requires_object_host"

      PlayerSession.stop(alice)
    end

    test "unresolvable verb author (unsigned source doc) → no player tell, but the drop IS logged (fail-closed)", ctx do
      alice_ctx = fresh_identity("alice")
      alice = start_player("alice", ctx, self(), signing_context: alice_ctx)
      drain("alice")
      send_input(alice, "east")
      drain("alice")

      room = clearing_uuid(ctx)

      # No `signing_context` opt → the verb source doc's commit is unsigned
      # (signer_id nil), so the author identity is unresolvable — same
      # shape as a store/read failure. Fail CLOSED: no player leak, but
      # still ops-visible. (This also models the curated-verb case: a
      # curated verb's source is signed by the NODE identity, which no
      # human invoker's `identity_uuid` ever matches either.)
      :ok =
        VerbSource.save_safe_verb(
          room,
          "vanish3",
          ~s|Commonplace.MUD.World.Facade.consume(world)|,
          [room],
          ctx.store
        )

      out =
        capture_log(fn ->
          send_input(alice, "vanish3")
          send(self(), {:captured, drain("alice") |> Enum.join("\n")})
        end)

      assert_received {:captured, player_out}
      refute player_out =~ "verb note"

      assert out =~ "safe-verb author diagnostic"
      assert out =~ "requires_object_host"

      PlayerSession.stop(alice)
    end

  end

  describe "CX-avgu: @destroy builder cleanup" do
    test "@destroy unlinks a stray object from the room", ctx do
      alice = start_player("alice", ctx)
      drain("alice")
      send_input(alice, "east")
      drain("alice")

      send_input(alice, "@create object liratest")
      drain("alice")
      assert {:ok, _} = Commonplace.MUD.World.find_entry_by_name(clearing_uuid(ctx), "liratest", ctx.store)

      send_input(alice, "@destroy liratest")
      out = drain("alice") |> Enum.join("\n")
      assert out =~ "You destroy the liratest"
      assert :error = Commonplace.MUD.World.find_entry_by_name(clearing_uuid(ctx), "liratest", ctx.store)

      PlayerSession.stop(alice)
    end

    test "@destroy a nonexistent object → clean 'nothing here' error", ctx do
      alice = start_player("alice", ctx)
      drain("alice")
      send_input(alice, "east")
      drain("alice")

      send_input(alice, "@destroy phantom")
      out = drain("alice") |> Enum.join("\n")
      assert out =~ "no \"phantom\" here"

      PlayerSession.stop(alice)
    end

    test "@destroy refuses a NON-EMPTY container (would orphan its contents)", ctx do
      alice = start_player("alice", ctx)
      drain("alice")
      send_input(alice, "east")
      drain("alice")

      send_input(alice, "@create container crate")
      drain("alice")
      send_input(alice, "@create object apple")
      drain("alice")
      send_input(alice, "put apple in crate")
      drain("alice")

      send_input(alice, "@destroy crate")
      refused = drain("alice") |> Enum.join("\n")
      assert refused =~ "isn't empty"
      # crate still there.
      assert {:ok, _} = Commonplace.MUD.World.find_entry_by_name(clearing_uuid(ctx), "crate", ctx.store)

      # empty it, then it destroys.
      send_input(alice, "get apple from crate")
      drain("alice")
      send_input(alice, "@destroy crate")
      ok = drain("alice") |> Enum.join("\n")
      assert ok =~ "You destroy the crate"
      assert :error = Commonplace.MUD.World.find_entry_by_name(clearing_uuid(ctx), "crate", ctx.store)

      PlayerSession.stop(alice)
    end
  end

  describe "CX-<notify>: private verb feedback" do
    test "notify reaches the INVOKER as plain text, NOT the co-present player and NOT as speech", ctx do
      alice = start_player("alice", ctx)
      bob = start_player("bob", ctx)
      drain("alice")
      drain("bob")

      send_input(alice, "east")
      send_input(bob, "east")
      drain("alice")
      drain("bob")

      send_input(alice, "@create object gong")
      drain("alice")

      {:ok, entry} = Commonplace.MUD.World.find_entry_by_name(clearing_uuid(ctx), "gong", ctx.store)

      :ok =
        VerbSource.save_safe_verb(
          entry.node_id,
          "ring",
          ~s|Commonplace.MUD.World.Facade.notify(world, "STATUS-XYZZY charge 3/5")|,
          [entry.node_id],
          ctx.store
        )

      send_input(alice, "ring gong")
      alice_out = drain("alice") |> Enum.join("\n")
      bob_out = drain("bob") |> Enum.join("\n")

      # Invoker sees the status PLAIN (not "You say, ...").
      assert alice_out =~ "STATUS-XYZZY charge 3/5"
      refute alice_out =~ "You say"
      # Co-present player sees NOTHING — private, not room speech.
      refute bob_out =~ "STATUS-XYZZY"

      PlayerSession.stop(alice)
      PlayerSession.stop(bob)
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

  describe "CX-oh5k: move_self session sync" do
    test "CX-oh5k: move_self in a verb moves the session room, not just presence (no ghost)", ctx do
      alice = start_player("alice", ctx)
      drain("alice")
      send_input(alice, "east")
      drain("alice")

      clearing = clearing_uuid(ctx)
      {:ok, root_schema} = Schemas.load_dir_schema(ctx.root, ctx.store)
      {:ok, start_entry} = Schema.get_entry(root_schema, "start")
      start = start_entry.node_id

      :ok =
        VerbSource.save_safe_verb(
          clearing,
          "teleport",
          ~s|Commonplace.MUD.World.Facade.move_self(world, "#{start}")|,
          [clearing],
          ctx.store
        )

      send_input(alice, "teleport")
      drain("alice")

      s = :sys.get_state(alice)
      # THE FIX: session followed the presence to the dest room.
      assert s.current_room_uuid == start, "session room did NOT follow move_self (ghost)"

      # And the presence really is in start, not clearing.
      names = fn dir ->
        {:ok, sch} = Schemas.load_dir_schema(dir, ctx.store)
        sch |> Schema.list_entries() |> Enum.map(& &1.name)
      end

      assert s.presence_filename in names.(start)
      refute s.presence_filename in names.(clearing)

      PlayerSession.stop(alice)
    end
  end
end
