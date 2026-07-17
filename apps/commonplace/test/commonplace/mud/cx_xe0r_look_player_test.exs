defmodule Commonplace.MUD.CxXe0rLookPlayerTest do
  @moduledoc """
  CX-xe0r — `look <player>` / `examine <player>` cannot target another LIVE
  player in the room, even though the room render lists them under `Players:`
  and `give` resolves them. Reproduction + regression pins, driven through the
  real `PlayerSession` harness (two live sessions in the same room).
  """

  use ExUnit.Case

  alias Commonplace.Document.ContentType
  alias Commonplace.MUD.{Bootstrap, PlayerSession, SignedWrite, World}
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_mud_xe0r_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_xe0r_#{:rand.uniform(1_000_000)}"
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

    on_exit(fn -> if Process.alive?(bursar_pid), do: (try do GenServer.stop(bursar_pid) catch (:exit, _ -> :ok) end) end)

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
      50 -> Enum.reverse(acc)
    end
  end

  defp send_input(session, name, text) do
    PlayerSession.input_sync(session, text)
    Process.sleep(50)
    drain(name) |> Enum.join("\n")
  end

  test "look <player>: a live co-present player can be inspected by name", ctx do
    alice = start_player("alice", ctx)
    _bob = start_player("bob", ctx)

    # Room render lists bob (sanity — they are co-present).
    room = send_input(alice, "alice", "look")
    assert room =~ "bob"

    out = send_input(alice, "alice", "look bob")

    refute out =~ ~r/don't see/i, "look <player> lied that a co-present player isn't here: #{out}"
    assert out =~ "bob"
  end

  test "examine <player>: a live co-present player can be examined by name", ctx do
    alice = start_player("alice", ctx)
    _bob = start_player("bob", ctx)

    out = send_input(alice, "alice", "examine bob")

    refute out =~ ~r/don't see/i, "examine <player> lied that a co-present player isn't here: #{out}"
    assert out =~ "bob"
  end

  # The LIVE failure mode (CX-xe0r): an ephemeral / homeless presence — a
  # `.usr` in the room with NO `players/<name>` home + Player doc (line 902 of
  # player_session: ephemeral sessions provision no players/ dir). look/examine
  # matched the presence but `load_player_for_lookup` couldn't load a Player
  # doc, so it fell through to the lying "You don't see X here."
  test "look <homeless presence>: a co-present player without a players/ home is still visible, not denied", ctx do
    alice = start_player("alice", ctx)
    seed_homeless_presence!(ctx, ctx.room, "wraith")

    room = send_input(alice, "alice", "look")
    assert room =~ "wraith", "sanity: the homeless presence is listed in the room"

    out = send_input(alice, "alice", "look wraith")
    refute out =~ ~r/don't see/i, "look lied about a co-present (homeless) player: #{out}"
    assert out =~ "wraith"
  end

  # Seed a presence `.usr` in `room_uuid` with a bound identity but NO
  # `players/<name>` home dir (the ephemeral shape). Node-signed.
  defp seed_homeless_presence!(ctx, room_uuid, name) do
    {:ok, node_ctx} = Commonplace.Crypto.NodeIdentity.signing_context()
    fname = "#{name}.usr"
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :map, fname)
    doc = ContentType.set_key(doc, "name", name)
    doc = ContentType.set_key(doc, "type", "usr")
    doc = ContentType.set_key(doc, "bound_identity", UUID.uuid4())
    update = Encoding.encode_update(doc)
    {metadata, commit_opts} = SignedWrite.opts_for(uuid, store: ctx.store, signing_context: node_ctx)
    _ = CommitStoreClient.create_commit(ctx.store, uuid, update, nil, metadata, commit_opts)

    {:ok, schema} = Commonplace.MUD.Schemas.load_dir_schema(room_uuid, ctx.store)
    schema = Schema.add_file(schema, fname, uuid)
    {rmeta, ropts} = SignedWrite.opts_for(room_uuid, store: ctx.store, signing_context: node_ctx)
    _ = CommitStoreClient.create_chained_commit(ctx.store, room_uuid, Encoding.encode_update(schema), rmeta, ropts)
    :ok
  end
end
