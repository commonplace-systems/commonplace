defmodule Commonplace.MUD.VerbsMultiwordTest do
  @moduledoc """
  CX-8iyv: multi-word names in the MUD parse/verb layer.

  Before this fix, `@create`/`@dig` only used the first word after the
  verb as the name (minting rooms literally named "The"), and
  take/give/@desc/@name only matched the first word of a target,
  breaking on multi-word object names. These tests exercise the fix
  end-to-end through `PlayerSession` (same scaffolding as
  `player_session_test.exs`).
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

    dir = Path.join(System.tmp_dir!(), "cp_mud_multiword_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_mw_#{:rand.uniform(1_000_000)}"
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

  test "@create room with a multi-word name uses the FULL name, not just the first word", ctx do
    alice = start_player("alice", ctx)

    send_input(alice, "@create room The Silver Fountain")
    out = drain("alice") |> Enum.join("\n")

    assert out =~ "The Silver Fountain"
    refute out =~ "(The)"
  end

  test "@create object with a multi-word name uses the FULL name", ctx do
    alice = start_player("alice", ctx)

    send_input(alice, "@create object Silver Coin")
    out = drain("alice") |> Enum.join("\n")
    assert out =~ "You create a Silver Coin."

    send_input(alice, "look")
    room_out = drain("alice") |> Enum.join("\n")
    assert room_out =~ "Silver Coin"
  end

  test "@dig with a multi-word name carves a connected room with the FULL name (no orphan)", ctx do
    alice = start_player("alice", ctx)

    send_input(alice, "@dig up The Silver Fountain Grove")
    dig_out = drain("alice") |> Enum.join("\n")
    assert dig_out =~ "The Silver Fountain Grove"

    # Connected: alice can walk there and see the full name rendered,
    # proving it's reachable from the current room (not a disconnected
    # orphan) and that the name wasn't truncated to "The".
    send_input(alice, "up")
    move_out = drain("alice") |> Enum.join("\n")
    assert move_out =~ "The Silver Fountain Grove"

    send_input(alice, "look")
    look_out = drain("alice") |> Enum.join("\n")
    assert look_out =~ "The Silver Fountain Grove"
  end

  test "take resolves a multi-word object name (not just the first word)", ctx do
    alice = start_player("alice", ctx)

    send_input(alice, "@create object Silver Coin")
    drain("alice")

    send_input(alice, "take Silver Coin")
    take_out = drain("alice") |> Enum.join("\n")
    assert take_out =~ "You take Silver Coin"

    send_input(alice, "inventory")
    inv_out = drain("alice") |> Enum.join("\n")
    assert inv_out =~ "Silver Coin"
  end

  test "@desc resolves a multi-word target and sets the FULL remaining text", ctx do
    alice = start_player("alice", ctx)

    send_input(alice, "@create object Silver Coin")
    drain("alice")

    send_input(alice, "@desc Silver Coin A shiny round coin, freshly minted")
    desc_out = drain("alice") |> Enum.join("\n")
    assert desc_out =~ "Updated Silver Coin description."

    send_input(alice, "look Silver Coin")
    look_out = drain("alice") |> Enum.join("\n")
    assert look_out =~ "A shiny round coin, freshly minted"
  end

  test "@name resolves a multi-word target and renames to a multi-word new name", ctx do
    alice = start_player("alice", ctx)

    send_input(alice, "@create object Silver Coin")
    drain("alice")

    send_input(alice, "@name Silver Coin Golden Coin")
    name_out = drain("alice") |> Enum.join("\n")
    assert name_out =~ "Updated Silver Coin name."

    send_input(alice, "look Golden Coin")
    look_out = drain("alice") |> Enum.join("\n")
    assert look_out =~ "Golden Coin"
  end

  test "give with 'to' delivers a multi-word item to the right recipient", ctx do
    alice = start_player("alice", ctx)
    bob = start_player("bob", ctx)
    drain("alice")
    drain("bob")

    send_input(alice, "@create object Silver Coin")
    drain("alice")
    send_input(alice, "take Silver Coin")
    drain("alice")
    drain("bob")

    send_input(alice, "give Silver Coin to bob")
    give_out = drain("alice") |> Enum.join("\n")
    assert give_out =~ "You give Silver Coin to bob"

    bob_out = drain("bob") |> Enum.join("\n")
    assert bob_out =~ "alice gives you Silver Coin"

    send_input(bob, "inventory")
    bob_inv = drain("bob") |> Enum.join("\n")
    assert bob_inv =~ "Silver Coin"

    PlayerSession.stop(alice)
    PlayerSession.stop(bob)
  end

  test "give without 'to' still works for single-word item/recipient (no regression)", ctx do
    alice = start_player("alice", ctx)
    bob = start_player("bob", ctx)
    drain("alice")
    drain("bob")

    send_input(alice, "take cloak")
    drain("alice")
    drain("bob")

    send_input(alice, "give cloak bob")
    give_out = drain("alice") |> Enum.join("\n")
    assert give_out =~ "You give cloak to bob"

    PlayerSession.stop(alice)
    PlayerSession.stop(bob)
  end

  test "@alias adds an alias that then resolves in take/look", ctx do
    alice = start_player("alice", ctx)

    send_input(alice, "@create object Silver Coin")
    drain("alice")

    send_input(alice, "@alias Silver Coin loot")
    alias_out = drain("alice") |> Enum.join("\n")
    assert alias_out =~ "loot"

    send_input(alice, "look loot")
    look_out = drain("alice") |> Enum.join("\n")
    assert look_out =~ "Silver Coin"

    send_input(alice, "take loot")
    take_out = drain("alice") |> Enum.join("\n")
    assert take_out =~ "You take Silver Coin"
  end

  test "single-word names/targets still work (no regression)", ctx do
    alice = start_player("alice", ctx)

    # CX-df64: @desc/@name now target entries in BOTH the inventory and
    # the current room, so ordering (desc-then-take vs take-then-desc)
    # no longer matters — kept doing desc-before-take here as the
    # pre-existing no-regression shape; the carried-object case is
    # covered separately below.
    send_input(alice, "@desc cloak A freshly re-described cloak")
    desc_out = drain("alice") |> Enum.join("\n")
    assert desc_out =~ "Updated cloak description."

    send_input(alice, "take cloak")
    take_out = drain("alice") |> Enum.join("\n")
    assert take_out =~ "You take cloak"
  end

  # CX-df64 — repro: @desc on a CARRIED object (already in inventory, not
  # in the room) previously fell through to the generic "Try: @desc
  # <target> <text>" usage hint, because `split_target_and_rest`/
  # `update_meta` (shared by @desc/@name) only searched the current room
  # — @verb's own target resolution already searched inventory too, so
  # this was a real @desc-specific gap, not a general design limit. Fix:
  # both helpers now search [inventory, room], mirroring
  # `resolve_target_object`'s precedence.
  test "@desc resolves an object the player is CARRYING, not just one in the room (CX-df64)", ctx do
    alice = start_player("alice", ctx)

    send_input(alice, "@create object glowbug")
    drain("alice")
    send_input(alice, "take glowbug")
    drain("alice")

    send_input(alice, "@desc glowbug A tiny insect that pulses with soft green light.")
    desc_out = drain("alice") |> Enum.join("\n")
    refute desc_out =~ "Try: @desc"
    assert desc_out =~ "Updated glowbug description."

    send_input(alice, "look glowbug")
    look_out = drain("alice") |> Enum.join("\n")
    assert look_out =~ "A tiny insect that pulses with soft green light."
  end

  # CX-df64 — @name shares the same `update_meta` helper as @desc; pin the
  # same fix for the renamed-while-carried path.
  test "@name resolves an object the player is CARRYING (CX-df64)", ctx do
    alice = start_player("alice", ctx)

    send_input(alice, "@create object glowbug")
    drain("alice")
    send_input(alice, "take glowbug")
    drain("alice")

    send_input(alice, "@name glowbug Firefly")
    name_out = drain("alice") |> Enum.join("\n")
    refute name_out =~ "Try: @name"
    assert name_out =~ "Updated glowbug name."

    send_input(alice, "inventory")
    inv_out = drain("alice") |> Enum.join("\n")
    assert inv_out =~ "Firefly"
  end
end
