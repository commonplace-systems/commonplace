defmodule Commonplace.MUD.TakeTest do
  @moduledoc """
  CX-ix9n — TAKE under enforce: the push-not-pull elevated node
  transfer (`Commonplace.MUD.Take`). Covers the unblock, the
  fixed-scenery guard (via `Verbs.dispatch`), the single-winner token
  race, the identity-bound-holder forge check, rollback on move
  failure, and the no-elevation-without-node-ownership guard.

  Setup mirrors `VerbsSafeDispatchTest`'s `Commonplace.Store.Supervisor`
  + `Commonplace.Green.Bursar` bring-up (needed for both the green-token
  possession layer and the `Move`-backed tree relocation).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Green.{Bursar, BursarClient}
  alias Commonplace.MUD.{Parser, SignedWrite, Schemas, Take, Verbs}
  alias Commonplace.MUD.Schemas.{Object, Room}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_take_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"take_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"take_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"take_tss_#{n}",
       pending_imports_name: :"take_pi_#{n}"}
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
    {:ok, node_identity} = NodeIdentity.identity()

    %{store: store, node_ctx: node_ctx, node_identity: node_identity}
  end

  # ---- seed helpers ----

  defp mk_room!(store, signing_ctx, name \\ "The Yard") do
    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: name, description: "a plain place"}),
        store,
        signing_context: signing_ctx
      )

    uuid
  end

  defp mk_inventory!(store, signing_ctx) do
    {:ok, uuid} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: signing_ctx)
    uuid
  end

  defp mk_object!(store, signing_ctx, opts) do
    name = Keyword.get(opts, :name, "widget")
    fixed = Keyword.get(opts, :fixed, false)

    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: name, fixed: fixed}),
        store,
        signing_context: signing_ctx
      )

    uuid
  end

  defp add_dir_entry!(store, parent_uuid, name, child_uuid, signing_ctx) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_directory(schema, name, child_uuid)
    update = Encoding.encode_update(schema)
    {metadata, commit_opts} = SignedWrite.opts_for(parent_uuid, store: store, signing_context: signing_ctx)

    case CommitStoreClient.create_chained_commit(store, parent_uuid, update, metadata, commit_opts) do
      {:error, _} = err -> raise "seed write failed: #{inspect(err)}"
      _commit -> :ok
    end
  end

  defp add_file_entry!(store, parent_uuid, name, child_uuid, signing_ctx) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_file(schema, name, child_uuid)
    update = Encoding.encode_update(schema)
    {metadata, commit_opts} = SignedWrite.opts_for(parent_uuid, store: store, signing_context: signing_ctx)

    case CommitStoreClient.create_chained_commit(store, parent_uuid, update, metadata, commit_opts) do
      {:error, _} = err -> raise "seed write failed: #{inspect(err)}"
      _commit -> :ok
    end
  end

  defp entry_names(store, dir_uuid) do
    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    schema |> Schema.entries() |> Map.keys()
  end

  defp fresh_identity do
    {pub, priv} = Signing.generate_keypair()
    id = UUID.uuid4()
    ctx = %SigningContext{identity_uuid: id, public_key: pub, private_key: priv}
    {id, ctx}
  end

  # ---- 1. THE UNBLOCK ----

  test "under enforce, a taker with no authority over the dirs takes a node-owned item", %{
    store: store,
    node_ctx: node_ctx
  } do
    room = mk_room!(store, node_ctx)
    inventory = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "widget.obj")
    add_dir_entry!(store, room, "widget.obj", item, node_ctx)

    {taker_id, _taker_ctx} = fresh_identity()

    assert :ok = Take.take(item, "widget.obj", room, inventory, taker_id, store: store)

    refute "widget.obj" in entry_names(store, room)
    assert "widget.obj" in entry_names(store, inventory)

    assert {:held, %{holder: ^taker_id}} = BursarClient.query(Bursar, item)
  end

  # ---- 2. Fixed scenery ----

  test "fixed object refuses take, no token transfer, item stays", %{store: store, node_ctx: node_ctx} do
    room = mk_room!(store, node_ctx)
    inventory = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "statue", fixed: true)
    add_dir_entry!(store, room, "statue.obj", item, node_ctx)

    {taker_id, taker_sc} = fresh_identity()

    ctx = %{
      player_name: "taker",
      current_room_uuid: room,
      inventory_uuid: inventory,
      store: store,
      signing_context: taker_sc,
      cert_cids: [],
      signer_id: Signing.signer_id(taker_id, taker_sc.public_key)
    }

    cmd = %Parser.Command{verb: "take", args: "statue", argv: ["statue"]}
    assert {:error, msg} = Verbs.dispatch(cmd, ctx)
    assert msg =~ "fixed in place"

    assert "statue.obj" in entry_names(store, room)
    refute "statue.obj" in entry_names(store, inventory)
    assert :available = BursarClient.query(Bursar, item)
  end

  # ---- 3. Double-take single-winner ----

  test "two concurrent takes of the same item: exactly one wins, the other is refused", %{
    store: store,
    node_ctx: node_ctx
  } do
    room = mk_room!(store, node_ctx)
    inv_a = mk_inventory!(store, node_ctx)
    inv_b = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "gem")
    add_dir_entry!(store, room, "gem", item, node_ctx)

    {id_a, _} = fresh_identity()
    {id_b, _} = fresh_identity()

    task_a = Task.async(fn -> Take.take(item, "gem", room, inv_a, id_a, store: store) end)
    task_b = Task.async(fn -> Take.take(item, "gem", room, inv_b, id_b, store: store) end)

    result_a = Task.await(task_a)
    result_b = Task.await(task_b)

    results = [result_a, result_b]
    losing_reasons = [{:error, :taken}, {:error, :item_unavailable}, {:error, :gone}]

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 in losing_reasons)) == 1

    winner_id = if result_a == :ok, do: id_a, else: id_b
    winner_inv = if result_a == :ok, do: inv_a, else: inv_b
    loser_inv = if result_a == :ok, do: inv_b, else: inv_a

    refute "gem" in entry_names(store, room)
    assert "gem" in entry_names(store, winner_inv)
    refute "gem" in entry_names(store, loser_inv)

    assert {:held, %{holder: ^winner_id}} = BursarClient.query(Bursar, item)
  end

  # ---- 4. Identity-bound holder is not forgeable ----

  test "after A takes, B cannot forge a transfer claiming to be the holder", %{
    store: store,
    node_ctx: node_ctx
  } do
    room = mk_room!(store, node_ctx)
    inv_a = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "ring")
    add_dir_entry!(store, room, "ring", item, node_ctx)

    {id_a, _} = fresh_identity()
    {id_b, _} = fresh_identity()

    assert :ok = Take.take(item, "ring", room, inv_a, id_a, store: store)

    # B claims to be the holder (impersonating A as authenticated_as B —
    # the from_holder param doesn't match the authenticated caller).
    assert {:error, :holder_mismatch} =
             BursarClient.transfer(Bursar, item, id_a, id_b, authenticated_as: id_b)

    assert {:held, %{holder: ^id_a}} = BursarClient.query(Bursar, item)
  end

  # ---- 5. Rollback on move failure ----

  test "move failure after token transfer rolls the token back to the node", %{
    store: store,
    node_ctx: node_ctx,
    node_identity: node_identity
  } do
    room = mk_room!(store, node_ctx)
    inventory = mk_inventory!(store, node_ctx)
    item = mk_object!(store, node_ctx, name: "coin")
    add_dir_entry!(store, room, "coin", item, node_ctx)

    # collide: an entry named "coin" already lives in the dest inventory.
    other_item = mk_object!(store, node_ctx, name: "coin")
    add_file_entry!(store, inventory, "coin", other_item, node_ctx)

    {taker_id, _} = fresh_identity()

    assert {:error, :collision} = Take.take(item, "coin", room, inventory, taker_id, store: store)

    # item entry unchanged in the room.
    assert "coin" in entry_names(store, room)

    # the token rolled back to the node.
    assert {:held, %{holder: ^node_identity}} = BursarClient.query(Bursar, item)
  end

  # ---- 6. Non-node-owned dir -> no elevation ----

  test "a non-node-owned room refuses take with no elevation, no token movement", %{store: store} do
    {other_id, other_ctx} = fresh_identity()

    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{other_id => Signing.encode_key(other_ctx.public_key)}
    })

    room = mk_room!(store, other_ctx)
    node_ctx = elem(NodeIdentity.signing_context(), 1)
    inventory = mk_inventory!(store, node_ctx)
    item = mk_object!(store, other_ctx, name: "trinket")
    add_dir_entry!(store, room, "trinket", item, other_ctx)

    {taker_id, _} = fresh_identity()

    assert {:error, :not_takeable_here} = Take.take(item, "trinket", room, inventory, taker_id, store: store)

    assert "trinket" in entry_names(store, room)
    assert :available = BursarClient.query(Bursar, item)
  end
end
