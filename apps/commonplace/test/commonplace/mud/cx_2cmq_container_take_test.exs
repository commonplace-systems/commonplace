defmodule Commonplace.MUD.Cx2cmqContainerTakeTest do
  @moduledoc """
  CX-2cmq — containers were "roach motels": a visitor can put an item into a
  container in a foreign zone but never take it back out. This pins the
  intended policy (commonplace-plan #8006): open-by-default SYMMETRIC extraction
  that ELEVATES to node authority ONLY for a node-owned/curated container
  (mirror of CX-5c78's deposit-elevate), while a citizen's own container stays
  on the normal zone-write path (a visitor cannot extract without a grant).

  Enforce harness mirrors DropGiveTest / TakeTest.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Green.Bursar
  alias Commonplace.MUD.{Schemas, Take, World}
  alias Commonplace.MUD.Schemas.{Object, Room}
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_2cmq_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"cx2cmq_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"cx2cmq_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"cx2cmq_tss_#{n}",
       pending_imports_name: :"cx2cmq_pi_#{n}"}
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

    case GenServer.whereis(Bursar) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    {:ok, bursar_pid} = Bursar.start_link(root_uuid: UUID.uuid4(), store: store, sweep_interval: 60_000)
    on_exit(fn -> if Process.alive?(bursar_pid), do: GenServer.stop(bursar_pid) end)

    {:ok, node_ctx} = NodeIdentity.signing_context()

    root = mk_dir!(store, node_ctx)
    players = mk_dir!(store, node_ctx)
    add_dir_entry!(store, root, "players", players, node_ctx)

    %{store: store, node_ctx: node_ctx, root: root, players: players}
  end

  test "CURATED container: a visitor can withdraw an item they deposited (symmetric, no roach-motel)", %{
    store: store,
    node_ctx: node_ctx,
    root: root
  } do
    # A curated room reachable from root (NOT under players/), with a
    # node-owned container in it.
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    shelf = mk_container!(store, node_ctx, "shelf")
    add_dir_entry!(store, room, "shelf.obj", shelf, node_ctx)

    # A visitor with a node-owned inventory.
    {visitor_id, _} = fresh_identity()
    visitor_inv = mk_inventory!(store, node_ctx)

    # An item in the room; visitor takes it (token → visitor), then deposits
    # it into the shelf (token → node), then withdraws it.
    item = mk_object!(store, node_ctx, "key")
    add_dir_entry!(store, room, "key.obj", item, node_ctx)

    assert :ok = Take.take(item, "key.obj", room, visitor_inv, visitor_id, store: store, root_uuid: root)

    assert :ok =
             World.deposit_item(item, "key.obj", visitor_inv, shelf, visitor_id,
               store: store, root_uuid: root)

    assert "key.obj" in entry_names(store, shelf), "sanity: item deposited into the shelf"

    # THE WITHDRAWAL — currently the roach-motel denial.
    result = Take.take(item, "key.obj", shelf, visitor_inv, visitor_id, store: store, root_uuid: root)
    assert result == :ok, "visitor could not withdraw from a curated container: #{inspect(result)}"

    assert "key.obj" in entry_names(store, visitor_inv)
    refute "key.obj" in entry_names(store, shelf)
  end

  test "PLAYER-HOME container: a visitor CANNOT withdraw (stays denied — correct, not over-elevated)", %{
    store: store,
    node_ctx: node_ctx,
    root: root,
    players: players
  } do
    # fable's home + a container fable owns, inside players/fable (pruned from
    # the curated-reachable set).
    fable_home = mk_room!(store, node_ctx, "Fable's Loft")
    add_dir_entry!(store, players, "fable", fable_home, node_ctx)
    shelf = mk_container!(store, node_ctx, "shelf")
    add_dir_entry!(store, fable_home, "shelf.obj", shelf, node_ctx)

    {visitor_id, _} = fresh_identity()
    visitor_inv = mk_inventory!(store, node_ctx)

    # An item already sitting in fable's container, node-held.
    item = mk_object!(store, node_ctx, "gem")
    add_dir_entry!(store, shelf, "gem.obj", item, node_ctx)

    result = Take.take(item, "gem.obj", shelf, visitor_inv, visitor_id, store: store, root_uuid: root)
    refute result == :ok, "visitor should NOT extract from a citizen's home container: #{inspect(result)}"
  end

  test "CITIZEN-HOME container: visitor deposit is now DENIED (symmetric-closed) — the roach-motel is dissolved", %{
    store: store,
    node_ctx: node_ctx,
    root: root,
    players: players
  } do
    fable_home = mk_room!(store, node_ctx, "Fable's Loft")
    add_dir_entry!(store, players, "fable", fable_home, node_ctx)
    shelf = mk_container!(store, node_ctx, "shelf")
    add_dir_entry!(store, fable_home, "shelf.obj", shelf, node_ctx)

    # A curated room the visitor can legitimately take from, to obtain an item.
    room = share!(store, root, mk_room!(store, node_ctx), node_ctx)
    {visitor_id, _} = fresh_identity()
    visitor_inv = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, "key")
    add_dir_entry!(store, room, "key.obj", item, node_ctx)
    assert :ok = Take.take(item, "key.obj", room, visitor_inv, visitor_id, store: store, root_uuid: root)

    # Deposit INTO fable's citizen-home container is REFUSED (over-elevation
    # closed) — so no item can be stranded. Symmetric with the withdraw denial
    # in the test above: a container a visitor can't take from, they can't put
    # into either. The item stays in the visitor's own inventory.
    deposit =
      World.deposit_item(item, "key.obj", visitor_inv, shelf, visitor_id, store: store, root_uuid: root)

    refute deposit == :ok, "deposit into a citizen-home container should be refused, got #{inspect(deposit)}"
    refute "key.obj" in entry_names(store, shelf), "nothing should land in the citizen container"
    assert "key.obj" in entry_names(store, visitor_inv), "the item stays with the visitor (not eaten)"
  end

  # ---- helpers ----

  defp mk_dir!(store, ctx) do
    {:ok, uuid} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: ctx)
    uuid
  end

  defp mk_room!(store, ctx, name \\ "The Yard") do
    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: name, description: "a place"}),
        store,
        signing_context: ctx
      )

    uuid
  end

  defp mk_object!(store, ctx, name) do
    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: name}),
        store,
        signing_context: ctx
      )

    uuid
  end

  defp mk_container!(store, ctx, name) do
    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: name, container?: true}),
        store,
        signing_context: ctx
      )

    uuid
  end

  defp mk_inventory!(store, ctx), do: mk_dir!(store, ctx)

  defp share!(store, root, room_uuid, ctx) do
    add_dir_entry!(store, root, "room-#{String.slice(room_uuid, 0, 8)}", room_uuid, ctx)
    room_uuid
  end

  defp add_dir_entry!(store, parent_uuid, name, child_uuid, ctx) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_directory(schema, name, child_uuid)
    {metadata, commit_opts} = Commonplace.MUD.SignedWrite.opts_for(parent_uuid, store: store, signing_context: ctx)

    case Commonplace.Store.CommitStoreClient.create_chained_commit(store, parent_uuid, Encoding.encode_update(schema), metadata, commit_opts) do
      {:error, _} = err -> raise "seed write failed: #{inspect(err)}"
      _ -> :ok
    end
  end

  defp entry_names(store, dir_uuid) do
    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    schema |> Schema.entries() |> Map.keys()
  end

  defp fresh_identity do
    {pub, priv} = Signing.generate_keypair()
    id = UUID.uuid4()
    {id, %SigningContext{identity_uuid: id, public_key: pub, private_key: priv}}
  end
end
