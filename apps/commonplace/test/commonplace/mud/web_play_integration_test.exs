defmodule Commonplace.MUD.WebPlayIntegrationTest do
  @moduledoc """
  CX-gjpi: the end-to-end web-play trust proof, as a PlayerSession-level
  integration (what `CommonplaceWebWeb.MudLive` drives from a browser).

  Under strict + `local_write_gate: :enforce`, a freshly-provisioned
  citizen:

    * spawns IN the home room they OWN (`:spawn_room_uuid`),
    * `@desc here …` in that home room LANDS (their `{:docs}` home-zone
      cert covers the home `__room.json`),
    * walks `out` to the shared (unowned) `start` room,
    * `@desc here …` there is REFUSED (no cert covers `start`'s meta),

  proving the M1 zone-ownership thesis over the browser path: edit your
  own room, can't edit others.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.MUD.{Citizenship, PlayerSession, Schemas}
  alias Commonplace.MUD.Schemas.Room
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Commonplace.Document.ContentType

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_webplay_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"webplay_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"webplay_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"webplay_tss_#{n}",
       pending_imports_name: :"webplay_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)
    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      restore = fn key, v ->
        if is_nil(v), do: Application.delete_env(:commonplace, key), else: Application.put_env(:commonplace, key, v)
      end

      restore.(:data_dir, old_data_dir)
      restore.(:trust, old_trust)
      restore.(:local_write_gate, old_knob)
      File.rm_rf!(dir)
    end)

    # Moves take green tokens — start a Bursar against this store under
    # its default name so World.move's default route finds it (same
    # scaffold bot_test/containers_test use; the live serve runs one).
    case GenServer.whereis(Commonplace.Green.Bursar) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, bursar_pid} =
      Commonplace.Green.Bursar.start_link(root_uuid: UUID.uuid4(), store: store, sweep_interval: 60_000)

    on_exit(fn -> if Process.alive?(bursar_pid), do: GenServer.stop(bursar_pid) end)

    {:ok, node_ctx} = NodeIdentity.signing_context()

    # world root + a shared, UNOWNED `start` room (node-signed).
    root = UUID.uuid4()
    CommitStore.create_commit(store, root, Yelixer.Encoding.encode_update(Schema.new_schema()), nil, %{}, signing_context: node_ctx)

    start_json = Schemas.encode_room(%Room{name: "The Commons", description: "A shared square. Nobody owns it.", exits: %{}})
    {:ok, start_dir} = Schemas.create_dir_with_meta(Schemas.room_filename(), start_json, store, signing_context: node_ctx)
    add_child(store, root, "start", start_dir, node_ctx)

    %{store: store, root: root, start_dir: start_dir}
  end

  test "citizen spawns in owned home → @desc here LANDS; walks out → @desc here REFUSED",
       %{store: store, root: root, start_dir: start_dir} do
    # a fresh :5199-local player identity (keypair == custody).
    {pub, priv} = Signing.generate_keypair()
    identity = UUID.uuid4()
    player_ctx = %SigningContext{identity_uuid: identity, public_key: pub, private_key: priv}

    assert {:ok, %{cert_cids: cert_cids, home_room_uuid: home_uuid, home_room_meta_uuid: home_meta}} =
             Citizenship.ensure(identity, pub, "arwen", root, store)

    {:ok, pid} =
      GenServer.start(PlayerSession,
        player_name: "arwen",
        root_uuid: root,
        store: store,
        buffered: true,
        signing_context: player_ctx,
        signer_id: Signing.signer_id(identity, pub),
        cert_cids: cert_cids,
        spawn_room_uuid: home_uuid
      )

    # spawned IN the home room they own.
    look = drive(pid, "look")
    assert look =~ "arwen's Home"

    # @desc here in the OWNED home room → LANDS.
    desc_home = drive(pid, "@desc here A warm den, filled with my own things.")
    assert desc_home =~ "Updated room"
    assert room_desc(store, home_meta) =~ "A warm den"

    # walk "out" to the shared start room.
    _ = drive(pid, "out")
    here = drive(pid, "look")
    assert here =~ "The Commons"

    # @desc here in the UNOWNED start room → REFUSED (no cert covers it).
    start_meta = room_meta_uuid(store, start_dir)
    before = room_desc(store, start_meta)
    desc_start = drive(pid, "@desc here I scrawl my name on the commons.")
    refute desc_start =~ "Updated room"
    # the shared room's description is untouched.
    assert room_desc(store, start_meta) == before

    PlayerSession.stop(pid)
  end

  defp drive(pid, line) do
    :ok = PlayerSession.input_sync(pid, line)
    PlayerSession.drain_buffer(pid) |> Enum.map(&line_text/1) |> Enum.join("\n")
  end

  defp line_text(s) when is_binary(s), do: s
  defp line_text(%{text: t}), do: t
  defp line_text(other), do: inspect(other)

  defp room_meta_uuid(store, room_dir) do
    {:ok, schema} = Schemas.load_dir_schema(room_dir, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.room_filename())
    entry.node_id
  end

  defp room_desc(store, meta_uuid) do
    {:ok, doc} = DocBuilder.reconstruct_doc(store, meta_uuid)
    {:ok, %{"description" => d}} = Jason.decode(ContentType.get_content(doc))
    d
  end

  defp add_child(store, parent, name, child, node_ctx) do
    {:ok, schema} = Schemas.load_dir_schema(parent, store)
    update = Yelixer.Encoding.encode_update(Schema.add_directory(schema, name, child))
    CommitStore.create_chained_commit(store, parent, update, %{}, signing_context: node_ctx)
  end
end
