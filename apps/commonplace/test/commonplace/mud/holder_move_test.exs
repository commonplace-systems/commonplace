defmodule Commonplace.MUD.HolderMoveTest do
  @moduledoc """
  CX-fg1e — DIRECT unit coverage for `Commonplace.MUD.HolderMove.push/7`,
  which had none (only indirect exercise via `World.drop_item/give_item/
  deposit_item` in `Commonplace.MUD.DropGiveTest`). This file calls
  `push/7` itself and targets branches `DropGiveTest` doesn't reach:

    * the FAST path (`invoker_can_write_all?` true skips the whole
      token-transfer machinery — `Move.move/5` runs invoker-signed).
    * the `elevated_push` `:bad_arg` guard (nil/empty holder).
    * the `ensure_mover_holds` `from_holder == node_identity` disjunct
      (acquiring an `:available` token as the NODE mover, not via the
      own-inventory re-anchor `DropGiveTest` already covers).
    * rollback on move failure when the token was FRESHLY ACQUIRED
      (`acquired? == true` — release back to `:available`), the sibling
      of `DropGiveTest`'s rollback test which only exercises the
      already-HELD-token transfer-back branch (`acquired? == false`).
    * the plain held-by-other refusal, called directly.

  Setup mirrors `Commonplace.MUD.DropGiveTest`'s store + Bursar bring-up.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Green.{Bursar, BursarClient}
  alias Commonplace.MUD.{HolderMove, Schemas}
  alias Commonplace.MUD.Schemas.Object
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_holdermove_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"holdermove_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"holdermove_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"holdermove_tss_#{n}",
       pending_imports_name: :"holdermove_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)
    Application.put_env(:commonplace, :data_dir, dir)
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
    on_exit(fn -> if Process.alive?(bursar_pid), do: (try do GenServer.stop(bursar_pid) catch (:exit, _ -> :ok) end) end)

    {:ok, node_ctx} = NodeIdentity.signing_context()
    {:ok, node_identity} = NodeIdentity.identity()

    # Strict trust, node identity pinned as trusted (mirrors DropGiveTest,
    # plus the pin section_ownership-style tests use for the node).
    Application.put_env(:commonplace, :trust, %{
      accept_unsigned: false,
      trusted_identities: %{node_identity => Signing.encode_key(node_ctx.public_key)}
    })

    %{store: store, node_ctx: node_ctx, node_identity: node_identity}
  end

  defp mk_dir!(store, signing_ctx) do
    {:ok, uuid} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: signing_ctx)
    uuid
  end

  defp mk_object!(store, signing_ctx, name) do
    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: name, fixed: false}),
        store,
        signing_context: signing_ctx
      )

    uuid
  end

  defp add_dir_entry!(store, parent_uuid, name, child_uuid, signing_ctx) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_directory(schema, name, child_uuid)
    update = Encoding.encode_update(schema)
    {metadata, commit_opts} = Commonplace.MUD.SignedWrite.opts_for(parent_uuid, store: store, signing_context: signing_ctx)

    case CommitStoreClient.create_chained_commit(store, parent_uuid, update, metadata, commit_opts) do
      {:error, _} = err -> raise "seed write failed: #{inspect(err)}"
      _commit -> :ok
    end
  end

  defp add_file_entry!(store, parent_uuid, name, child_uuid, signing_ctx) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_file(schema, name, child_uuid)
    update = Encoding.encode_update(schema)
    {metadata, commit_opts} = Commonplace.MUD.SignedWrite.opts_for(parent_uuid, store: store, signing_context: signing_ctx)

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

  # ---- 1. FAST PATH — invoker already authorized to write both dirs ----

  test "push: an invoker with write authority over BOTH dirs runs the plain move, no token transfer at all", %{
    store: store,
    node_ctx: node_ctx
  } do
    from_dir = mk_dir!(store, node_ctx)
    to_dir = mk_dir!(store, node_ctx)
    item = mk_object!(store, node_ctx, "trusted.obj")
    add_dir_entry!(store, from_dir, "trusted.obj", item, node_ctx)

    # The item's token was never touched — still :available going in.
    assert :available = BursarClient.query(Bursar, item)

    # node_ctx is pinned trusted, so invoker_can_write_all? is true for
    # both dirs -> the fast Move.move/5 path, not elevated_push at all.
    assert :ok =
             HolderMove.push(item, "trusted.obj", from_dir, to_dir, "irrelevant-from", "irrelevant-to",
               store: store,
               signing_context: node_ctx,
               cert_cids: []
             )

    refute "trusted.obj" in entry_names(store, from_dir)
    assert "trusted.obj" in entry_names(store, to_dir)
    # THE POINT: the fast path never touches the Bursar — the token is
    # exactly as untouched as before the call (still :available), because
    # `from_holder`/`to_holder` are arbitrary placeholders on this path.
    assert :available = BursarClient.query(Bursar, item)
  end

  # ---- 2. elevated_push :bad_arg guard ----

  test "push: an elevated caller (no write authority) with a nil/empty holder is refused :bad_arg before any write", %{
    store: store,
    node_ctx: node_ctx
  } do
    from_dir = mk_dir!(store, node_ctx)
    to_dir = mk_dir!(store, node_ctx)
    item = mk_object!(store, node_ctx, "widget.obj")
    add_dir_entry!(store, from_dir, "widget.obj", item, node_ctx)

    # No signing_context/cert_cids -> invoker_can_write_all? is false ->
    # elevated_push, which guards on the holder args before touching
    # the Bursar or the tree at all.
    assert {:error, :bad_arg} = HolderMove.push(item, "widget.obj", from_dir, to_dir, nil, "someone", store: store)
    assert {:error, :bad_arg} = HolderMove.push(item, "widget.obj", from_dir, to_dir, "", "someone", store: store)
    assert {:error, :bad_arg} = HolderMove.push(item, "widget.obj", from_dir, to_dir, "someone", nil, store: store)
    assert {:error, :bad_arg} = HolderMove.push(item, "widget.obj", from_dir, to_dir, "someone", "", store: store)

    assert "widget.obj" in entry_names(store, from_dir)
    assert :available = BursarClient.query(Bursar, item)
  end

  # ---- 3. elevated success: held token transfers and the tree write elevates ----

  test "push: elevated path transfers a HELD token and moves the item (node-elevated write)", %{
    store: store,
    node_ctx: node_ctx,
    node_identity: node_identity
  } do
    from_dir = mk_dir!(store, node_ctx)
    to_dir = mk_dir!(store, node_ctx)
    item = mk_object!(store, node_ctx, "coin.obj")
    add_dir_entry!(store, from_dir, "coin.obj", item, node_ctx)

    {holder_id, _} = fresh_identity()
    assert {:ok, _} = BursarClient.acquire(Bursar, item, holder_id, authenticated_as: holder_id, ttl: nil)

    assert :ok = HolderMove.push(item, "coin.obj", from_dir, to_dir, holder_id, node_identity, store: store)

    refute "coin.obj" in entry_names(store, from_dir)
    assert "coin.obj" in entry_names(store, to_dir)
    assert {:held, %{holder: ^node_identity}} = BursarClient.query(Bursar, item)
  end

  # ---- 4. held-by-OTHER refuses :not_holder, called directly ----

  test "push: a from_holder who does not actually hold the token is refused :not_holder — the authorization check IS the transfer", %{
    store: store,
    node_ctx: node_ctx,
    node_identity: node_identity
  } do
    from_dir = mk_dir!(store, node_ctx)
    to_dir = mk_dir!(store, node_ctx)
    item = mk_object!(store, node_ctx, "gem.obj")
    add_dir_entry!(store, from_dir, "gem.obj", item, node_ctx)

    {actual_holder, _} = fresh_identity()
    {claimant, _} = fresh_identity()
    assert {:ok, _} = BursarClient.acquire(Bursar, item, actual_holder, authenticated_as: actual_holder, ttl: nil)

    assert {:error, :not_holder} =
             HolderMove.push(item, "gem.obj", from_dir, to_dir, claimant, node_identity, store: store)

    # Nothing moved, and the real holder's token is untouched.
    assert "gem.obj" in entry_names(store, from_dir)
    assert {:held, %{holder: ^actual_holder}} = BursarClient.query(Bursar, item)
  end

  # ---- 5. CX-cogd: NODE mover acquires an :available token (not the own-inventory re-anchor path) ----

  test "push: the node, as mover, acquires an :available token on the node-owned source dir and completes the move", %{
    store: store,
    node_ctx: node_ctx,
    node_identity: node_identity
  } do
    from_dir = mk_dir!(store, node_ctx)
    to_dir = mk_dir!(store, node_ctx)
    item = mk_object!(store, node_ctx, "loose.obj")
    # Seeded straight in — :available, no prior holder.
    add_file_entry!(store, from_dir, "loose.obj", item, node_ctx)
    assert :available = BursarClient.query(Bursar, item)

    {recipient_id, _} = fresh_identity()

    # from_holder == node_identity -> ensure_mover_holds's first disjunct
    # fires regardless of write authority over from_dir.
    assert :ok =
             HolderMove.push(item, "loose.obj", from_dir, to_dir, node_identity, recipient_id, store: store)

    refute "loose.obj" in entry_names(store, from_dir)
    assert "loose.obj" in entry_names(store, to_dir)
    assert {:held, %{holder: ^recipient_id}} = BursarClient.query(Bursar, item)
  end

  test "push: an :available token is NOT acquired for a non-node mover with no write authority and no own-inventory opt", %{
    store: store,
    node_ctx: node_ctx,
    node_identity: node_identity
  } do
    from_dir = mk_dir!(store, node_ctx)
    to_dir = mk_dir!(store, node_ctx)
    item = mk_object!(store, node_ctx, "unclaimed.obj")
    add_file_entry!(store, from_dir, "unclaimed.obj", item, node_ctx)
    assert :available = BursarClient.query(Bursar, item)

    {mover_id, _} = fresh_identity()

    assert {:error, :not_holder} =
             HolderMove.push(item, "unclaimed.obj", from_dir, to_dir, mover_id, node_identity, store: store)

    assert "unclaimed.obj" in entry_names(store, from_dir)
    assert :available = BursarClient.query(Bursar, item)
  end

  # ---- 6. rollback on move failure — the FRESHLY-ACQUIRED branch (acquired? == true) ----
  #
  # DropGiveTest's rollback test only exercises a token already HELD before
  # the call (acquired? == false -> transfer-back). This is the sibling: the
  # token starts :available, gets acquired by the node mover, and the move
  # then fails -> rollback must RELEASE (back to :available), not transfer.

  test "push: move failure after a FRESH acquire releases the token back to :available (not transfer-back)", %{
    store: store,
    node_ctx: node_ctx,
    node_identity: node_identity
  } do
    from_dir = mk_dir!(store, node_ctx)
    to_dir = mk_dir!(store, node_ctx)
    item = mk_object!(store, node_ctx, "collider.obj")
    add_file_entry!(store, from_dir, "collider.obj", item, node_ctx)
    assert :available = BursarClient.query(Bursar, item)

    # Seed a same-named entry at the destination so the elevated Move.move
    # fails with a collision AFTER the token has already transferred.
    other_item = mk_object!(store, node_ctx, "collider.obj")
    add_file_entry!(store, to_dir, "collider.obj", other_item, node_ctx)

    {recipient_id, _} = fresh_identity()

    assert {:error, :collision} =
             HolderMove.push(item, "collider.obj", from_dir, to_dir, node_identity, recipient_id, store: store)

    # The item never moved, and the freshly-acquired token was released
    # back to :available (never left dangling on either party).
    assert "collider.obj" in entry_names(store, from_dir)
    assert :available = BursarClient.query(Bursar, item)
  end
end
