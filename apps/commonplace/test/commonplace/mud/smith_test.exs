defmodule Commonplace.MUD.SmithTest do
  @moduledoc """
  CX-cj3t (items epic phase 2) — SMITH under enforce:
  `Commonplace.MUD.Mint.smith/4`'s mint-before-consume saga under an
  inventory-dir move-lock. Covers the design §4 attack catalog: S1
  (output type recipe-defined), S2/S3 (validate-fail → inputs intact,
  consume ⊆ declared), S4 (concurrent double-craft — the inventory-dir
  lock serializes, exactly one wins), S5 (a player-forged recipe write is
  refused under enforce).

  Setup mirrors `MineTest`/`TakeTest`.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing, SigningContext}
  alias Commonplace.Green.{Bursar, BursarClient}
  alias Commonplace.MUD.{Mint, SignedWrite, Schemas}
  alias Commonplace.MUD.Schemas.{Object, Recipe}
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  @ore %{"name" => "iron ore", "aliases" => ["ore"], "description" => "A rough chunk of iron ore."}
  @ingot %{"name" => "iron ingot", "aliases" => ["ingot"], "description" => "A bar of iron."}

  setup do
    Application.ensure_all_started(:phoenix_pubsub)

    case Phoenix.PubSub.Supervisor.start_link(name: Commonplace.PubSub) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    dir = Path.join(System.tmp_dir!(), "cp_smith_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000_000)
    store = :"smith_store_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"smith_sup_#{n}",
       commit_store_name: store,
       trust_side_store_name: :"smith_tss_#{n}",
       pending_imports_name: :"smith_pi_#{n}"}
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
    on_exit(fn -> if Process.alive?(bursar_pid), do: (try do GenServer.stop(bursar_pid) catch (:exit, _ -> :ok) end) end)

    {:ok, node_ctx} = NodeIdentity.signing_context()
    {:ok, node_identity} = NodeIdentity.identity()

    # A minimal world: root with a __recipes dir + a crafter inventory.
    root = mk_dir!(store, node_ctx)
    recipes_dir = mk_dir!(store, node_ctx)
    add_dir_entry!(store, root, "__recipes", recipes_dir, node_ctx)

    %{store: store, node_ctx: node_ctx, node_identity: node_identity, root: root, recipes_dir: recipes_dir}
  end

  # ---- helpers ----

  defp mk_dir!(store, ctx) do
    {:ok, uuid} = Schemas.create_dir_with_meta(nil, nil, store, signing_context: ctx)
    uuid
  end

  defp add_dir_entry!(store, parent, name, child, ctx) do
    {:ok, schema} = Schemas.load_dir_schema(parent, store)
    update = Encoding.encode_update(Schema.add_directory(schema, name, child))
    {metadata, commit_opts} = SignedWrite.opts_for(parent, store: store, signing_context: ctx)

    case CommitStoreClient.create_chained_commit(store, parent, update, metadata, commit_opts) do
      {:error, _} = err -> err
      _ -> :ok
    end
  end

  defp seed_recipe!(ctx, name, inputs, output) do
    {:ok, recipe_uuid} =
      Schemas.create_dir_with_meta(
        Schemas.recipe_filename(),
        Schemas.encode_recipe(%Recipe{name: name, inputs: inputs, output: output}),
        ctx.store,
        signing_context: ctx.node_ctx
      )

    :ok = add_dir_entry!(ctx.store, ctx.recipes_dir, "r-#{String.slice(recipe_uuid, 0, 8)}", recipe_uuid, ctx.node_ctx)
  end

  # Give `crafter` `count` held items of `template` in `inventory` via the
  # real mint path (each lands node-signed + token acquired to the crafter).
  defp stock!(ctx, inventory, crafter, template, count) do
    for _ <- 1..count do
      {:ok, uuid} = Mint.mint_item(template, inventory, crafter, store: ctx.store)
      uuid
    end
  end

  defp inventory_item_names(store, inventory) do
    {:ok, schema} = Schemas.load_dir_schema(inventory, store)

    schema
    |> Schema.list_entries()
    |> Enum.filter(&(&1.type == :dir))
    |> Enum.map(fn e ->
      case Schemas.load_object(e.node_id, store) do
        {:ok, %Object{name: name}} -> name
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp fresh_identity do
    {pub, priv} = Signing.generate_keypair()
    id = UUID.uuid4()
    {id, %SigningContext{identity_uuid: id, public_key: pub, private_key: priv}}
  end

  # ---- tests ----

  test "happy path: 2 iron ore -> 1 iron ingot; ore consumed, ingot minted + held", ctx do
    inv = mk_dir!(ctx.store, ctx.node_ctx)
    {crafter, _} = fresh_identity()
    ore_uuids = stock!(ctx, inv, crafter, @ore, 2)
    seed_recipe!(ctx, "iron ingot", [%{"type" => "iron ore", "qty" => 2}], @ingot)

    assert {:ok, "iron ingot"} =
             Mint.smith("iron ingot", inv, crafter, root_uuid: ctx.root, store: ctx.store)

    names = inventory_item_names(ctx.store, inv)
    assert "iron ingot" in names
    refute "iron ore" in names
    # inputs consumed: their tokens released (available), the ingot held by crafter
    for ore <- ore_uuids, do: assert(:available = BursarClient.query(Bursar, ore))

    ingot_uuid =
      elem(Enum.find(entries_with_names(ctx.store, inv), fn {_u, nm} -> nm == "iron ingot" end), 0)

    assert {:held, %{holder: ^crafter}} = BursarClient.query(Bursar, ingot_uuid)
  end

  test "validate fail (missing input) refuses, consumes NOTHING, mints NOTHING (S2/S3)", ctx do
    inv = mk_dir!(ctx.store, ctx.node_ctx)
    {crafter, _} = fresh_identity()
    [ore] = stock!(ctx, inv, crafter, @ore, 1)
    seed_recipe!(ctx, "iron ingot", [%{"type" => "iron ore", "qty" => 2}], @ingot)

    assert {:error, {:missing_input, "iron ore"}} =
             Mint.smith("iron ingot", inv, crafter, root_uuid: ctx.root, store: ctx.store)

    # the one ore is still present + still held; no ingot was minted.
    names = inventory_item_names(ctx.store, inv)
    assert "iron ore" in names
    refute "iron ingot" in names
    assert {:held, %{holder: ^crafter}} = BursarClient.query(Bursar, ore)
  end

  test "unknown recipe refuses gracefully", ctx do
    inv = mk_dir!(ctx.store, ctx.node_ctx)
    {crafter, _} = fresh_identity()

    assert {:error, :no_recipe} =
             Mint.smith("mithril blade", inv, crafter, root_uuid: ctx.root, store: ctx.store)
  end

  test "concurrent double-craft of the same 2 ore: exactly one wins (S4 — inventory-lock serializes)", ctx do
    inv = mk_dir!(ctx.store, ctx.node_ctx)
    {crafter, _} = fresh_identity()
    stock!(ctx, inv, crafter, @ore, 2)
    seed_recipe!(ctx, "iron ingot", [%{"type" => "iron ore", "qty" => 2}], @ingot)

    t1 = Task.async(fn -> Mint.smith("iron ingot", inv, crafter, root_uuid: ctx.root, store: ctx.store) end)
    t2 = Task.async(fn -> Mint.smith("iron ingot", inv, crafter, root_uuid: ctx.root, store: ctx.store) end)
    results = [Task.await(t1), Task.await(t2)]

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:missing_input, _}}, &1)) == 1

    # exactly one ingot exists; both ore consumed.
    names = inventory_item_names(ctx.store, inv)
    assert Enum.count(names, &(&1 == "iron ingot")) == 1
    refute "iron ore" in names
  end

  test "a player-forged recipe write is REFUSED under enforce (S5)", ctx do
    {_pid, player_ctx} = fresh_identity()

    # A visitor tries to author a recipe doc (the mint-authority) under the
    # node-owned __recipes dir. Under enforce (accept_unsigned: false,
    # trusted: {}), a non-node-signed write is denied — no forged recipe lands.
    forged =
      Schemas.encode_recipe(%Recipe{
        name: "master key",
        inputs: [%{"type" => "iron ore", "qty" => 1}],
        output: %{"name" => "master key"}
      })

    # The player-signed recipe-doc CREATE is itself denied by the write-gate
    # (untrusted signer under enforce) — the mint-authority doc never lands.
    assert {:error, {:trust_rejected, _}} =
             Schemas.create_dir_with_meta(Schemas.recipe_filename(), forged, ctx.store, signing_context: player_ctx)

    # So there is no forged recipe for smith to resolve.
    inv = mk_dir!(ctx.store, ctx.node_ctx)
    {crafter, _} = fresh_identity()

    assert {:error, :no_recipe} =
             Mint.smith("master key", inv, crafter, root_uuid: ctx.root, store: ctx.store)
  end

  defp entries_with_names(store, inventory) do
    {:ok, schema} = Schemas.load_dir_schema(inventory, store)

    schema
    |> Schema.list_entries()
    |> Enum.filter(&(&1.type == :dir))
    |> Enum.map(fn e ->
      name =
        case Schemas.load_object(e.node_id, store) do
          {:ok, %Object{name: nm}} -> nm
          _ -> nil
        end

      {e.node_id, name}
    end)
  end
end
