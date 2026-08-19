defmodule Commonplace.MUD.SameNameObjectsTest do
  @moduledoc """
  CX-1cfj: two objects with the SAME display name must coexist in one container
  (room or inventory) and remain individually take/drop-able. The original bug
  (name-keyed maps → "There's already one of those here." / "You aren't carrying
  that." while both are listed) is resolved by instance-unique schema keys
  ("<name>-<uuid>.obj", CX-3hii/CX-lfo3). This is the regression guard proving it
  end-to-end: create two coins, carry both, drop both into the same room.
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

    dir = Path.join(System.tmp_dir!(), "cp_1cfj_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"store_1cfj_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    case GenServer.whereis(Commonplace.Green.Bursar) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, bursar} =
      Commonplace.Green.Bursar.start_link(
        root_uuid: UUID.uuid4(),
        store: store,
        sweep_interval: 60_000
      )

    on_exit(fn ->
      if Process.alive?(bursar),
        do:
          (try do
             GenServer.stop(bursar)
           catch
             (:exit, _ -> :ok)
           end)
    end)

    root = UUID.uuid4()
    CommitStore.create_commit(store, root, Encoding.encode_update(Schema.new_schema()), nil)
    {:ok, _} = Bootstrap.seed(root, store)

    %{store: store, root: root}
  end

  test "two same-name objects coexist in a container and both take/drop cleanly", ctx do
    parent = self()
    out = fn text -> send(parent, {:out, text}) end

    {:ok, alice} =
      PlayerSession.start_link(
        player_name: "alice",
        root_uuid: ctx.root,
        store: ctx.store,
        output_fn: out,
        owner_pid: parent
      )

    drain()
    input(alice, "east")
    input(alice, "@create object coin")
    input(alice, "@create object coin")

    # Both are takeable, even though they share a display name.
    assert one(input(alice, "take coin")) =~ "take coin"
    assert one(input(alice, "take coin")) =~ "take coin"

    # The carry set holds BOTH (not one shadowing the other).
    assert one(input(alice, "inventory")) =~ ~r/coin.*coin/s

    # Both drop into the SAME room — no "already one of those here" collision,
    # no "you aren't carrying that" for the twin.
    d1 = one(input(alice, "drop coin"))
    d2 = one(input(alice, "drop coin"))
    assert d1 =~ "drop coin"
    assert d2 =~ "drop coin"
    refute d2 =~ "already one of those"
    refute d2 =~ "aren't carrying"

    assert one(input(alice, "inventory")) =~ "carrying nothing"

    PlayerSession.stop(alice)
  end

  defp input(session, text) do
    PlayerSession.input_sync(session, text)
    Process.sleep(60)
    drain()
  end

  defp one(lines), do: Enum.join(lines, "\n")

  defp drain(acc \\ []) do
    receive do
      {:out, t} -> drain([t | acc])
    after
      30 -> Enum.reverse(acc)
    end
  end
end
