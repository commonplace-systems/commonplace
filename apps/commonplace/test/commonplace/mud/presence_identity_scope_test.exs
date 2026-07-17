defmodule Commonplace.MUD.PresenceIdentityScopeTest do
  @moduledoc """
  CX-vhnj: a `<name>.usr` presence is reused on login ONLY when its
  `bound_identity` matches the logging-in session's identity. A fresh player
  whose NAME collides with a stale migration ghost (no bound_identity) or a
  foreign player's presence must NOT be hijacked into that presence's room —
  they spawn fresh in their own home. Conversely, a returning player whose OWN
  bound presence exists MUST reuse it (idempotent). Gate-independent (it's an
  identity comparison), so this runs permissive to isolate the reuse logic from
  cert machinery.
  """
  use ExUnit.Case

  alias Commonplace.Crypto.{Signing, SigningContext}
  alias Commonplace.MUD.PlayerSession
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType
  alias Yelixer.{Doc, Encoding}

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_vhnj_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"store_vhnj_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    case GenServer.whereis(Commonplace.Green.Bursar) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, bursar} =
      Commonplace.Green.Bursar.start_link(root_uuid: UUID.uuid4(), store: store, sweep_interval: 60_000)

    on_exit(fn -> if Process.alive?(bursar), do: (try do GenServer.stop(bursar) catch (:exit, _ -> :ok) end) end)

    # permissive gate: unsigned world-build writes land, so this isolates the
    # presence-reuse decision (identity comparison) from cert/enforce concerns.
    old = Application.get_env(:commonplace, :local_write_gate)
    Application.put_env(:commonplace, :local_write_gate, :off)
    on_exit(fn -> if old, do: Application.put_env(:commonplace, :local_write_gate, old), else: Application.delete_env(:commonplace, :local_write_gate) end)

    root = UUID.uuid4()
    genesis(store, root, Schema.new_schema())

    home = room(store, "Home")
    other = room(store, "Elsewhere")
    link(store, root, "home", home)
    link(store, root, "elsewhere", other)

    %{store: store, root: root, home: home, other: other}
  end

  test "a fresh signed player is NOT hijacked by a stale same-name presence (spawns in home)", ctx do
    # Stale migration ghost: "alice.usr" with NO bound_identity, sitting in the
    # OTHER room (not alice's home).
    seed_presence(ctx.store, ctx.other, "alice.usr", nil)

    sctx = %SigningContext{identity_uuid: "alice-real", public_key: pk(), private_key: sk()}

    {:ok, pid} =
      PlayerSession.start_link(
        player_name: "alice",
        root_uuid: ctx.root,
        store: ctx.store,
        buffered: true,
        signing_context: sctx,
        spawn_room_uuid: ctx.home
      )

    room = :sys.get_state(pid).current_room_uuid
    assert room == ctx.home, "fresh signed alice must spawn in home, not the stale ghost's room"
    refute room == ctx.other
    PlayerSession.stop(pid)
  end

  test "a returning player WITH their own bound presence reuses it (idempotent)", ctx do
    # alice's OWN presence (bound to her identity) already sits in the OTHER room
    # — a legit prior location; she must reconnect THERE, not re-spawn in home.
    seed_presence(ctx.store, ctx.other, "alice.usr", "alice-real")

    sctx = %SigningContext{identity_uuid: "alice-real", public_key: pk(), private_key: sk()}

    {:ok, pid} =
      PlayerSession.start_link(
        player_name: "alice",
        root_uuid: ctx.root,
        store: ctx.store,
        buffered: true,
        signing_context: sctx,
        spawn_room_uuid: ctx.home
      )

    assert :sys.get_state(pid).current_room_uuid == ctx.other,
           "a returning player must reuse their OWN bound presence's room"

    PlayerSession.stop(pid)
  end

  test "a fresh player is NOT hijacked by a FOREIGN player's same-name presence", ctx do
    # A different identity's "alice.usr" (bound to someone else) in the other room.
    seed_presence(ctx.store, ctx.other, "alice.usr", "alice-imposter")

    sctx = %SigningContext{identity_uuid: "alice-real", public_key: pk(), private_key: sk()}

    {:ok, pid} =
      PlayerSession.start_link(
        player_name: "alice",
        root_uuid: ctx.root,
        store: ctx.store,
        buffered: true,
        signing_context: sctx,
        spawn_room_uuid: ctx.home
      )

    assert :sys.get_state(pid).current_room_uuid == ctx.home
    PlayerSession.stop(pid)
  end

  # ---- helpers ----

  defp genesis(store, uuid, doc), do: CommitStore.create_commit(store, uuid, Encoding.encode_update(doc), nil)

  defp room(store, name) do
    meta = UUID.uuid4()
    mdoc = Doc.new() |> ContentType.create(:text, "meta")
    mdoc = ContentType.insert_text(mdoc, 0, Jason.encode!(%{"kind" => "room", "name" => name, "exits" => %{}}))
    CommitStore.create_commit(store, meta, Encoding.encode_update(mdoc), nil)

    dir = UUID.uuid4()
    genesis(store, dir, Schema.add_file(Schema.new_schema(), "__room.json", meta))
    dir
  end

  defp link(store, parent, name, child) do
    {:ok, schema} = Commonplace.MUD.Schemas.load_dir_schema(parent, store)
    CommitStore.create_chained_commit(store, parent, Encoding.encode_update(Schema.add_directory(schema, name, child)), %{})
  end

  defp seed_presence(store, room_dir, filename, bound_identity) do
    uuid = UUID.uuid4()
    doc = Doc.new() |> ContentType.create(:map, filename)
    doc = ContentType.set_key(doc, "name", String.trim_trailing(filename, ".usr"))
    doc = ContentType.set_key(doc, "type", "usr")
    doc = if bound_identity, do: ContentType.set_key(doc, "bound_identity", bound_identity), else: doc
    CommitStore.create_commit(store, uuid, Encoding.encode_update(doc), nil)

    {:ok, schema} = Commonplace.MUD.Schemas.load_dir_schema(room_dir, store)
    CommitStore.create_chained_commit(store, room_dir, Encoding.encode_update(Schema.add_file(schema, filename, uuid)), %{})
    uuid
  end

  defp pk, do: elem(kp(), 0)
  defp sk, do: elem(kp(), 1)
  defp kp, do: Process.get(:vhnj_kp) || (kp = Signing.generate_keypair(); Process.put(:vhnj_kp, kp); kp)
end
