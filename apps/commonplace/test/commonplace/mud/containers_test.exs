defmodule Commonplace.MUD.ContainersTest do
  @moduledoc """
  CX-cj3t.1.1 — nested containers (bags/chests).

  Contents of a container are plain `.obj` entries in the container's
  own dir schema — the SAME shape rooms/inventory already use, so
  `put`/`get ... from`/`look in` are just `World.move` + `World.list_objects_in`
  wired to a new `container?` flag on `Schemas.Object`. Mirrors the
  `PlayerSession` harness in `verbs_multiword_test.exs`.
  """

  use ExUnit.Case

  alias Commonplace.MUD.{Bootstrap, PlayerSession, Schemas, World}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_mud_containers_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_ctr_#{:rand.uniform(1_000_000)}"
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

    on_exit(fn ->
      if Process.alive?(bursar_pid),
        do:
          (try do
             GenServer.stop(bursar_pid)
           catch
             (:exit, _ -> :ok)
           end)
    end)

    root_uuid = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    {:ok, _} = Bootstrap.seed(root_uuid, store_name)
    {:ok, start_room_uuid} = World.resolve_path("start", root_uuid, store_name)

    %{store: store_name, root: root_uuid, room: start_room_uuid}
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

  # Finds the .obj entry by name in the room and flips its metadata's
  # "container" flag on — the same JSON field `@create object` writes,
  # via the same `World.set_meta/6` production write path (no new
  # storage machinery for the test either).
  defp make_container!(room_uuid, obj_name, ctx) do
    {:ok, entry} = World.find_entry_by_name(room_uuid, obj_name, ctx.store)
    :ok = World.set_meta(entry.node_id, Schemas.object_filename(), "container", true, ctx.store)
    entry.node_id
  end

  test "put item in container: leaves inventory, appears in container contents", ctx do
    alice = start_player("alice", ctx)

    send_input(alice, "@create object Wooden Box")
    drain("alice")
    make_container!(ctx.room, "Wooden Box", ctx)

    send_input(alice, "take cloak")
    drain("alice")

    send_input(alice, "put cloak in Wooden Box")
    out = drain("alice") |> Enum.join("\n")
    assert out =~ "You put cloak in Wooden Box."

    send_input(alice, "inventory")
    inv = drain("alice") |> Enum.join("\n")
    refute inv =~ "cloak"

    send_input(alice, "look in Wooden Box")
    look = drain("alice") |> Enum.join("\n")
    assert look =~ "cloak"
  end

  test "get item from container: back in inventory", ctx do
    alice = start_player("alice", ctx)

    send_input(alice, "@create object Wooden Box")
    drain("alice")
    make_container!(ctx.room, "Wooden Box", ctx)

    send_input(alice, "take cloak")
    drain("alice")
    send_input(alice, "put cloak in Wooden Box")
    drain("alice")

    send_input(alice, "get cloak from Wooden Box")
    out = drain("alice") |> Enum.join("\n")
    assert out =~ "You get cloak from Wooden Box."

    send_input(alice, "inventory")
    inv = drain("alice") |> Enum.join("\n")
    assert inv =~ "cloak"

    send_input(alice, "look in Wooden Box")
    look = drain("alice") |> Enum.join("\n")
    assert look =~ "The Wooden Box is empty."
  end

  test "look in container: lists contents, empty message when empty", ctx do
    alice = start_player("alice", ctx)

    send_input(alice, "@create object Wooden Box")
    drain("alice")
    make_container!(ctx.room, "Wooden Box", ctx)

    send_input(alice, "look in Wooden Box")
    empty_out = drain("alice") |> Enum.join("\n")
    assert empty_out =~ "The Wooden Box is empty."

    send_input(alice, "take cloak")
    drain("alice")
    send_input(alice, "put cloak in Wooden Box")
    drain("alice")

    send_input(alice, "look in Wooden Box")
    full_out = drain("alice") |> Enum.join("\n")
    assert full_out =~ "The Wooden Box contains: cloak."

    send_input(alice, "look Wooden Box")
    plain_look_out = drain("alice") |> Enum.join("\n")
    assert plain_look_out =~ "The Wooden Box contains: cloak."
  end

  test "put into a non-container object is rejected with a clear message", ctx do
    alice = start_player("alice", ctx)

    send_input(alice, "take cloak")
    drain("alice")

    send_input(alice, "@create object Rock")
    drain("alice")

    send_input(alice, "put cloak in Rock")
    out = drain("alice") |> Enum.join("\n")
    assert out =~ "You can't put things in the Rock."

    send_input(alice, "inventory")
    inv = drain("alice") |> Enum.join("\n")
    assert inv =~ "cloak"
  end

  test "cycle guard: put a container into itself is rejected", ctx do
    alice = start_player("alice", ctx)

    send_input(alice, "@create object Wooden Box")
    drain("alice")
    make_container!(ctx.room, "Wooden Box", ctx)

    send_input(alice, "take Wooden Box")
    drain("alice")

    send_input(alice, "put Wooden Box in Wooden Box")
    out = drain("alice") |> Enum.join("\n")
    assert out =~ "You can't put Wooden Box inside itself."
  end

  # CX-cj3t.1.1: the distinct-container round trip ("put A in B" then
  # "put B in A") can't be triggered as two SEQUENTIAL commands from one
  # player, because once A lands inside B, B — the second command's
  # target — is no longer resolvable via the (single-level, by design;
  # see `resolve_container/3`) room/inventory scan: the addressing
  # constraint alone already stops it, before `cycle_guard` ever runs.
  # The cycle_guard subtree-walk exists for the case that constraint
  # DOESN'T cover: two *different* players racing each other from the
  # SAME pre-move state (both resolve their target before either
  # write lands), relying on the atomic in-lock precheck — not
  # sequencing — to catch it. That's what this test drives: alice and
  # bob fire "put Box A in Box B" / "put Box B in Box A" concurrently;
  # both need the ROOM's bursar token (both source dirs), so the token
  # serializes them — whichever move commits first is fine (nothing
  # cyclic exists yet), and the second one's precheck now runs AFTER
  # that write landed, so `cycle_guard` sees the just-created nesting
  # and rejects it. Exactly one of the two must succeed; exactly one
  # must fail as a cycle.
  test "cycle guard: concurrent put-A-in-B / put-B-in-A — exactly one succeeds, the other is a cycle rejection",
       ctx do
    alice = start_player("alice", ctx)
    bob = start_player("bob", ctx)
    drain("alice")
    drain("bob")

    send_input(alice, "@create object Box A")
    drain("alice")
    send_input(alice, "@create object Box B")
    drain("alice")
    make_container!(ctx.room, "Box A", ctx)
    make_container!(ctx.room, "Box B", ctx)

    task_a = Task.async(fn -> PlayerSession.input_sync(alice, "put Box A in Box B") end)
    task_b = Task.async(fn -> PlayerSession.input_sync(bob, "put Box B in Box A") end)
    Task.await(task_a, 10_000)
    Task.await(task_b, 10_000)
    Process.sleep(50)

    alice_out = drain("alice") |> Enum.join("\n")
    bob_out = drain("bob") |> Enum.join("\n")
    outcomes = [alice_out, bob_out]

    successes = Enum.count(outcomes, &String.contains?(&1, "You put"))
    cycle_rejections = Enum.count(outcomes, &String.contains?(&1, "inside itself"))

    assert successes == 1
    assert cycle_rejections == 1
  end

  test "non-empty container: put a coin in a bag, take the bag, coin stays nested", ctx do
    alice = start_player("alice", ctx)

    send_input(alice, "@create object Leather Bag")
    drain("alice")
    make_container!(ctx.room, "Leather Bag", ctx)

    send_input(alice, "@create object Gold Coin")
    drain("alice")

    send_input(alice, "put Gold Coin in Leather Bag")
    out = drain("alice") |> Enum.join("\n")
    assert out =~ "You put Gold Coin in Leather Bag."

    send_input(alice, "take Leather Bag")
    take_out = drain("alice") |> Enum.join("\n")
    assert take_out =~ "You take Leather Bag."

    send_input(alice, "inventory")
    inv = drain("alice") |> Enum.join("\n")
    assert inv =~ "Leather Bag"

    send_input(alice, "look in Leather Bag")
    look = drain("alice") |> Enum.join("\n")
    assert look =~ "Gold Coin"
  end

  # Cross-section-trust enforce-mode coverage (spec's optional "if
  # feasible" item) is SKIPPED here: `section_ownership_test.exs`'s
  # harness (named-store trio + strict trust config + registered
  # signed players + capability certs) is substantial standalone
  # scaffolding, not something this bead's scope should duplicate or
  # bend to fit. `put`/`get ... from` both route through the SAME
  # `World.move/5` (`SignedWrite` opts threaded via `write_opts/1`) that
  # `take`/`drop`/`give` already use, so the enforcement path itself is
  # unchanged — no new trust surface was introduced.

  # plan #5965: the depth-cap must FAIL CLOSED. With the cap set to 0, a
  # container with any contents can't be proven acyclic past its first
  # descendant level, so putting it anywhere is refused (rather than
  # fail-open ALLOW, which would let a deep-but-acyclic nest form a cycle
  # beyond the BFS's reach). Box A does NOT contain Box X — the guard
  # just can't prove it within the bound, so it refuses.
  test "cycle guard fails CLOSED when the subtree exceeds the depth cap", ctx do
    Application.put_env(:commonplace, :cycle_guard_max_depth, 0)
    on_exit(fn -> Application.delete_env(:commonplace, :cycle_guard_max_depth) end)

    alice = start_player("alice", ctx)
    send_input(alice, "@create object Box A")
    drain("alice")
    send_input(alice, "@create object Box X")
    drain("alice")
    make_container!(ctx.room, "Box A", ctx)
    make_container!(ctx.room, "Box X", ctx)

    # Make Box A non-empty (a cloak, one level deep) so its subtree
    # exceeds cap 0.
    send_input(alice, "take cloak")
    drain("alice")
    send_input(alice, "put cloak in Box A")
    drain("alice")

    send_input(alice, "put Box A in Box X")
    out = drain("alice") |> Enum.join("\n")
    assert out =~ "can't put"

    # And it was NOT moved (fail-closed refused the write).
    send_input(alice, "look in Box X")
    look = drain("alice") |> Enum.join("\n")
    refute look =~ "Box A"
  end

  # CX-cj3t.1.1 in-world reachability: containers must be MAKEABLE via MUD
  # commands, not only the schema flag (else the feature is untestable /
  # unusable by a player).
  test "@create container makes a usable container in-world", ctx do
    alice = start_player("alice", ctx)

    send_input(alice, "@create container Wooden Chest")
    out = drain("alice") |> Enum.join("\n")
    assert out =~ "container"

    send_input(alice, "take cloak")
    drain("alice")
    send_input(alice, "put cloak in Wooden Chest")
    put = drain("alice") |> Enum.join("\n")
    assert put =~ "You put cloak in Wooden Chest."

    send_input(alice, "look in Wooden Chest")
    look = drain("alice") |> Enum.join("\n")
    assert look =~ "cloak"
  end

  # boss #5979 nit a: the actor got the put/get line TWICE (verb {:reply}
  # + the room broadcast rendering first-person to the actor too).
  test "put/get success line reaches the actor exactly once (no double)", ctx do
    alice = start_player("alice", ctx)
    send_input(alice, "@create container Chest")
    drain("alice")
    send_input(alice, "take cloak")
    drain("alice")

    send_input(alice, "put cloak in Chest")
    put_lines = drain("alice")
    assert Enum.count(put_lines, &(&1 =~ "You put cloak in Chest.")) == 1

    send_input(alice, "get cloak from Chest")
    get_lines = drain("alice")
    assert Enum.count(get_lines, &(&1 =~ "You get cloak from Chest.")) == 1
  end

  test "@container converts an existing object into a container", ctx do
    alice = start_player("alice", ctx)

    send_input(alice, "@create object Barrel")
    drain("alice")
    send_input(alice, "take cloak")
    drain("alice")

    # Not a container yet — put is refused.
    send_input(alice, "put cloak in Barrel")
    before = drain("alice") |> Enum.join("\n")
    refute before =~ "You put cloak in Barrel."

    send_input(alice, "@container Barrel")
    mark = drain("alice") |> Enum.join("\n")
    assert mark =~ "is now a container"

    # Now it works.
    send_input(alice, "put cloak in Barrel")
    after_mark = drain("alice") |> Enum.join("\n")
    assert after_mark =~ "You put cloak in Barrel."
  end
end
