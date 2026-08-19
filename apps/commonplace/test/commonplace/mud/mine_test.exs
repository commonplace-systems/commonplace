defmodule Commonplace.MUD.MineTest do
  @moduledoc """
  CX-cj3t (items epic phase 2) — MINE under enforce:
  `Commonplace.MUD.Mint.extract_from_vein/4`'s lazy-regen decrement +
  node-signed mint. Covers the attack catalog from
  `2026-07-08-mine-smith-under-enforce-design.md` §4: M1 (type
  confusion), M2 (protected-field forgery / spin-up), M3 (depletion +
  regen cap), M4 (concurrent double-mine of the last charge), and the
  identity-bound mint token.

  Setup mirrors `TakeTest`'s `Commonplace.Store.Supervisor` +
  `Commonplace.Green.Bursar` bring-up (needed for both the vein-lock and
  the mint token layer).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Green.{Bursar, BursarClient}
  alias Commonplace.MUD.{Mint, Parser, SignedWrite, Schemas, Verbs}
  alias Commonplace.MUD.Schemas.{Object, Room}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  @ore_template %{
    "name" => "iron ore",
    "aliases" => ["ore"],
    "description" => "A rough chunk of iron ore."
  }

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_mine_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"mine_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"mine_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"mine_tss_#{n}",
       pending_imports_name: :"mine_pi_#{n}"}
    )

    old_data_dir = Application.get_env(:commonplace, :data_dir)
    old_trust = Application.get_env(:commonplace, :trust)
    old_knob = Application.get_env(:commonplace, :local_write_gate)
    Application.put_env(:commonplace, :data_dir, dir)
    Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})
    Application.put_env(:commonplace, :local_write_gate, :enforce)

    on_exit(fn ->
      restore = fn key, v ->
        if is_nil(v),
          do: Application.delete_env(:commonplace, key),
          else: Application.put_env(:commonplace, key, v)
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

    {:ok, bursar_pid} =
      Bursar.start_link(root_uuid: UUID.uuid4(), store: store, sweep_interval: 60_000)

    on_exit(fn ->
      if Process.alive?(bursar_pid),
        do:
          (try do
             GenServer.stop(bursar_pid)
           catch
             (:exit, _ -> :ok)
           end)
    end)

    {:ok, node_ctx} = NodeIdentity.signing_context()
    {:ok, node_identity} = NodeIdentity.identity()

    %{store: store, node_ctx: node_ctx, node_identity: node_identity}
  end

  # ---- seed helpers ----

  defp mk_dir!(store, signing_ctx) do
    {:ok, uuid} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: signing_ctx)
    uuid
  end

  defp mk_inventory!(store, signing_ctx), do: mk_dir!(store, signing_ctx)

  defp mk_room!(store, signing_ctx, name \\ "The Mine") do
    {:ok, uuid} =
      Schemas.create_dir_with_meta(
        Schemas.room_filename(),
        Schemas.encode_room(%Room{name: name, description: "a dusty tunnel"}),
        store,
        signing_context: signing_ctx
      )

    uuid
  end

  defp mk_vein!(store, signing_ctx, opts \\ []) do
    obj = %Object{
      name: Keyword.get(opts, :name, "iron vein"),
      aliases: Keyword.get(opts, :aliases, ["vein"]),
      description: "A vein of raw iron.",
      fixed: true,
      kind: "vein",
      yield_type: Keyword.get(opts, :yield_type, @ore_template),
      yield_max: Keyword.get(opts, :yield_max, 5),
      regen_per_ms: Keyword.get(opts, :regen_per_ms, 0),
      yield_remaining: Keyword.get(opts, :yield_remaining, 5),
      last_regen_at: Keyword.get(opts, :last_regen_at, 0)
    }

    {:ok, uuid} =
      Schemas.create_dir_with_meta(Schemas.object_filename(), Schemas.encode_object(obj), store,
        signing_context: signing_ctx
      )

    uuid
  end

  defp add_dir_entry!(store, parent_uuid, name, child_uuid, signing_ctx) do
    {:ok, schema} = Schemas.load_dir_schema(parent_uuid, store)
    schema = Schema.add_directory(schema, name, child_uuid)
    update = Encoding.encode_update(schema)

    {metadata, commit_opts} =
      SignedWrite.opts_for(parent_uuid, store: store, signing_context: signing_ctx)

    case CommitStoreClient.create_chained_commit(
           store,
           parent_uuid,
           update,
           metadata,
           commit_opts
         ) do
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

  defp load_vein!(store, uuid) do
    {:ok, %Object{} = obj} = Schemas.load_object(uuid, store)
    obj
  end

  # ---- M1: type confusion ----

  test "mining a vein mints exactly the vein's yield_type — never a different item", %{
    store: store,
    node_ctx: node_ctx
  } do
    vein =
      mk_vein!(store, node_ctx,
        yield_type: %{"name" => "diamond seed?", "aliases" => [], "description" => "no"}
      )

    inv = mk_inventory!(store, node_ctx)
    {miner_id, _} = fresh_identity()

    assert {:ok, item_uuid, "diamond seed?"} =
             Mint.extract_from_vein(vein, inv, miner_id, store: store)

    assert {:ok, %Object{name: "diamond seed?"}} = Schemas.load_object(item_uuid, store)
    refute {:ok, %Object{name: "iron ore"}} == Schemas.load_object(item_uuid, store)
  end

  # ---- M2: the elevated write cannot spin the protected fields up ----

  test "the elevated vein-write only ever changes yield_remaining (down) + last_regen_at (forward)",
       %{
         store: store,
         node_ctx: node_ctx
       } do
    vein = mk_vein!(store, node_ctx, yield_max: 5, yield_remaining: 5, regen_per_ms: 0)
    inv = mk_inventory!(store, node_ctx)
    {miner_id, _} = fresh_identity()

    before = load_vein!(store, vein)

    assert {:ok, _item_uuid, "iron ore"} =
             Mint.extract_from_vein(vein, inv, miner_id, store: store)

    afterward = load_vein!(store, vein)

    # Protected fields byte-unchanged.
    assert afterward.yield_type == before.yield_type
    assert afterward.yield_max == before.yield_max
    assert afterward.regen_per_ms == before.regen_per_ms

    # yield_remaining only ever decreased (no regen here).
    assert afterward.yield_remaining == before.yield_remaining - 1
    assert afterward.yield_remaining < before.yield_remaining
  end

  test "extract_from_vein exposes no argument that can set yield_type/yield_max/regen_per_ms", %{
    store: store,
    node_ctx: node_ctx
  } do
    # Structural: the function's arity/opts have no channel for a caller
    # to supply a protected field. Confirm the values landed are exactly
    # the ones present on the loaded doc, not any opts-supplied value —
    # there IS no such opt to supply, this pins that down by inspecting
    # the actual function clause (extract_from_vein/4 takes vein_uuid,
    # dest_inventory_uuid, miner_identity, opts — opts is used ONLY for
    # :store/:bursar/:ttl/:retries/:retry_ms, verified by reading
    # mint.ex's `Keyword.get` call sites).
    vein = mk_vein!(store, node_ctx, yield_max: 5, yield_remaining: 5)
    inv = mk_inventory!(store, node_ctx)
    {miner_id, _} = fresh_identity()

    # Passing bogus/forged-looking keys in opts has zero effect on the
    # protected fields — they are never read from opts at all.
    assert {:ok, _item_uuid, "iron ore"} =
             Mint.extract_from_vein(vein, inv, miner_id,
               store: store,
               yield_type: %{"name" => "diamond"},
               yield_max: 999_999,
               regen_per_ms: 999_999
             )

    afterward = load_vein!(store, vein)
    assert afterward.yield_max == 5
    assert afterward.regen_per_ms == 0
  end

  # ---- M3: depletion refuses gracefully; regen caps at max ----

  test "a depleted, non-regenerating vein refuses gracefully — no mint, no token, vein unchanged",
       %{
         store: store,
         node_ctx: node_ctx
       } do
    vein = mk_vein!(store, node_ctx, yield_remaining: 0, regen_per_ms: 0)
    inv = mk_inventory!(store, node_ctx)
    {miner_id, _} = fresh_identity()

    before = load_vein!(store, vein)

    assert {:error, :depleted} = Mint.extract_from_vein(vein, inv, miner_id, store: store)

    assert entry_names(store, inv) == []
    assert load_vein!(store, vein) == before
  end

  test "regen clamps at yield_max even after a huge elapsed delta", %{
    store: store,
    node_ctx: node_ctx
  } do
    long_ago = System.system_time(:millisecond) - 1_000_000_000

    vein =
      mk_vein!(store, node_ctx,
        yield_max: 5,
        yield_remaining: 0,
        regen_per_ms: 1,
        last_regen_at: long_ago
      )

    inv = mk_inventory!(store, node_ctx)
    {miner_id, _} = fresh_identity()

    assert {:ok, _item_uuid, "iron ore"} =
             Mint.extract_from_vein(vein, inv, miner_id, store: store)

    afterward = load_vein!(store, vein)
    # Regen would compute to a huge number without the cap; clamped at
    # yield_max, then one unit consumed by this mine.
    assert afterward.yield_remaining == 4
  end

  # ---- M4: concurrent double-mine of the last charge ----

  test "two concurrent mines of the last charge: exactly one mints, the other refuses", %{
    store: store,
    node_ctx: node_ctx
  } do
    vein = mk_vein!(store, node_ctx, yield_max: 1, yield_remaining: 1, regen_per_ms: 0)
    inv_a = mk_inventory!(store, node_ctx)
    inv_b = mk_inventory!(store, node_ctx)
    {id_a, _} = fresh_identity()
    {id_b, _} = fresh_identity()

    task_a = Task.async(fn -> Mint.extract_from_vein(vein, inv_a, id_a, store: store) end)
    task_b = Task.async(fn -> Mint.extract_from_vein(vein, inv_b, id_b, store: store) end)

    result_a = Task.await(task_a, 10_000)
    result_b = Task.await(task_b, 10_000)

    results = [result_a, result_b]
    wins = Enum.count(results, &match?({:ok, _, _}, &1))
    losses = Enum.count(results, &(&1 == {:error, :depleted}))

    assert wins == 1
    assert losses == 1

    afterward = load_vein!(store, vein)
    assert afterward.yield_remaining == 0
  end

  # ---- mint token: identity-bound to the producer ----

  test "after a successful mine, the ore's possession token holder is the miner", %{
    store: store,
    node_ctx: node_ctx
  } do
    vein = mk_vein!(store, node_ctx)
    inv = mk_inventory!(store, node_ctx)
    {miner_id, _} = fresh_identity()

    assert {:ok, item_uuid, _name} = Mint.extract_from_vein(vein, inv, miner_id, store: store)
    assert {:held, %{holder: ^miner_id}} = BursarClient.query(Bursar, item_uuid)
    assert "iron ore" in Enum.map(entry_names(store, inv), &strip_ext/1)
  end

  # ---- bad-arg / non-vein target ----

  test "extract_from_vein refuses a nil/blank miner identity", %{store: store, node_ctx: node_ctx} do
    vein = mk_vein!(store, node_ctx)
    inv = mk_inventory!(store, node_ctx)

    assert {:error, :bad_arg} = Mint.extract_from_vein(vein, inv, nil, store: store)
    assert {:error, :bad_arg} = Mint.extract_from_vein(vein, inv, "", store: store)
  end

  test "extract_from_vein refuses a plain (non-vein) object", %{store: store, node_ctx: node_ctx} do
    {:ok, plain_uuid} =
      Schemas.create_dir_with_meta(
        Schemas.object_filename(),
        Schemas.encode_object(%Object{name: "rock"}),
        store,
        signing_context: node_ctx
      )

    inv = mk_inventory!(store, node_ctx)
    {miner_id, _} = fresh_identity()

    assert {:error, :not_a_vein} = Mint.extract_from_vein(plain_uuid, inv, miner_id, store: store)
  end

  # ---- end-to-end via Verbs.dispatch ----

  test "Verbs.dispatch 'mine' extracts ore into inventory and narrates", %{
    store: store,
    node_ctx: node_ctx
  } do
    room = mk_room!(store, node_ctx)
    vein = mk_vein!(store, node_ctx)
    add_dir_entry!(store, room, "iron-vein.obj", vein, node_ctx)
    inv = mk_inventory!(store, node_ctx)

    {_miner_id, miner_ctx} = fresh_identity()

    ctx = %{
      store: store,
      current_room_uuid: room,
      inventory_uuid: inv,
      player_name: "Miner",
      presence_filename: ".usr",
      signing_context: miner_ctx,
      cert_cids: [],
      signer_id: nil,
      root_uuid: nil
    }

    cmd = Parser.parse("mine iron vein")
    assert {:reply, msg} = Verbs.dispatch(cmd, ctx)
    assert msg =~ "iron ore"
    assert "iron ore" in Enum.map(entry_names(store, inv), &strip_ext/1)
  end

  defp strip_ext(name) do
    name
    |> String.replace(~r/-[0-9a-f]{8}\.obj$/, "")
  end
end
