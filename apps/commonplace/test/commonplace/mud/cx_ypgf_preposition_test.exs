defmodule Commonplace.MUD.CxYpgfPrepositionTest do
  @moduledoc """
  CX-ypgf — parser/noun-matching hardening:

  1. Partial noun matches must anchor at a WORD boundary. A short token /
     preposition ('on') must not substring-match mid-word ('ir**on** ingot'),
     so `step on warppad` while carrying an iron ingot no longer resolves the
     ingot ("You can't step iron ingot").
  2. `put ... on/onto/into ...` works as an alias of `put ... in ...` (a
     surface-flavored container — plate/altar/pedestal — begs for "on").
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

    dir = Path.join(System.tmp_dir!(), "cp_mud_ypgf_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_ypgf_#{:rand.uniform(1_000_000)}"
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

  # ---- 1. word-boundary anchoring (pure matcher, fast) ----

  describe "World.find_entry_ranked word-boundary anchoring" do
    setup ctx do
      # Seed an "iron ingot" object directly in the room.
      {:ok, obj} =
        Schemas.create_dir_with_meta(
          Schemas.object_filename(),
          Schemas.encode_object(%Schemas.Object{name: "iron ingot"}),
          ctx.store
        )

      {:ok, schema} = Schemas.load_dir_schema(ctx.room, ctx.store)
      schema = Schema.add_directory(schema, "iron ingot.obj", obj)
      update = Encoding.encode_update(schema)
      CommitStore.create_commit(ctx.store, ctx.room, update, ctx.room)
      :ok
    end

    test "a preposition ('on') does NOT match mid-word inside 'iron ingot'", ctx do
      assert World.find_entry_ranked(ctx.room, "on", ctx.store) == nil
    end

    test "a real word-prefix ('ingot' / 'iron' / 'iron in') still matches", ctx do
      assert {_score, _e} = World.find_entry_ranked(ctx.room, "ingot", ctx.store)
      assert {_score, _e} = World.find_entry_ranked(ctx.room, "iron", ctx.store)
      assert {_score, _e} = World.find_entry_ranked(ctx.room, "iron in", ctx.store)
    end

    test "a mid-word fragment ('got') no longer matches", ctx do
      assert World.find_entry_ranked(ctx.room, "got", ctx.store) == nil
    end
  end

  # ---- 2. end-to-end through the real session ----

  test "carrying 'iron ingot', `step on warppad` does not resolve the ingot", ctx do
    alice = start_player("alice", ctx)

    send_input(alice, "alice", "@create object iron ingot")
    send_input(alice, "alice", "take iron ingot")
    inv = send_input(alice, "alice", "inventory")
    assert inv =~ "iron ingot", "sanity: alice is carrying the iron ingot"

    out = send_input(alice, "alice", "step on warppad")
    refute out =~ "iron ingot", "'on' substring-matched into 'iron ingot': #{out}"
    refute out =~ "ingot"
  end

  test "`put <item> on <surface-container>` works like `put ... in ...`", ctx do
    alice = start_player("alice", ctx)

    send_input(alice, "alice", "@create object tithe-plate")
    {:ok, entry} = World.find_entry_by_name(ctx.room, "tithe-plate", ctx.store)
    :ok = World.set_meta(entry.node_id, Schemas.object_filename(), "container", true, ctx.store)

    send_input(alice, "alice", "take cloak")
    out = send_input(alice, "alice", "put cloak on tithe-plate")

    refute out =~ ~r/Put what in what/i, "'on' was not accepted as a put preposition: #{out}"
    inv = send_input(alice, "alice", "inventory")
    refute inv =~ "cloak", "cloak should have left inventory into the plate"
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
      50 -> Enum.reverse(acc)
    end
  end

  defp send_input(session, name, text) do
    PlayerSession.input_sync(session, text)
    Process.sleep(50)
    drain(name) |> Enum.join("\n")
  end
end
