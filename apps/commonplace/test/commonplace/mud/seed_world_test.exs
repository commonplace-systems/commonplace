defmodule Commonplace.MUD.SeedWorldTest do
  @moduledoc """
  CX-lr73 (self-hosting slice 2, part A) — `Commonplace.MUD.SeedWorld`
  imports the MUD seed world from `priv/mud_seed_world.json` instead of
  `Commonplace.MUD.Bootstrap` holding it as Elixir literals.

  (1) parity — the imported content matches the pre-CX-lr73 hardcoded
      strings/numbers exactly; (2) idempotence — a second import changes
      nothing; (3) enforce — every write lands node-signed, so seeding
      plays under `local_write_gate: :enforce`; (4) decoupling — the
      phase-runner invokes every phase regardless of an earlier phase's
      error, returning the FIRST error (CX-g5lb(b)).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Crypto.{NodeIdentity, Signing}
  alias Commonplace.MUD.{Schemas, SeedWorld}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_seed_world_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    store = :"seed_world_store_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    root_uuid = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root_uuid, update, nil)

    %{store: store, root: root_uuid}
  end

  defp entry_uuid!(dir_uuid, name, store) do
    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    {:ok, entry} = Schema.get_entry(schema, name)
    entry.node_id
  end

  describe "(1) parity" do
    test "rooms carry the exact names/descriptions/exits", ctx do
      assert {:ok, :ready} = SeedWorld.import(ctx.root, ctx.store)

      start_uuid = entry_uuid!(ctx.root, "start", ctx.store)
      forest_uuid = entry_uuid!(ctx.root, "forest-path", ctx.store)
      clearing_uuid = entry_uuid!(ctx.root, "clearing", ctx.store)

      assert {:ok, start} = Schemas.load_room(start_uuid, ctx.store)
      assert start.name == "The Start Room"
      assert start.description == "A cozy stone chamber. Exits lead north and east."
      assert start.exits == %{"north" => forest_uuid, "east" => clearing_uuid}

      assert {:ok, forest} = Schemas.load_room(forest_uuid, ctx.store)
      assert forest.name == "A Forest Path"

      assert forest.description ==
               "Tall oaks line a winding dirt path. The Start Room lies south."

      assert forest.exits == %{"south" => start_uuid}

      assert {:ok, clearing} = Schemas.load_room(clearing_uuid, ctx.store)
      assert clearing.name == "A Sunlit Clearing"

      assert clearing.description ==
               "A grassy clearing dappled with sunlight. The Start Room lies west."

      assert clearing.exits == %{"west" => start_uuid}
    end

    test "cloak (start) and fountain (clearing) carry exact field parity", ctx do
      assert {:ok, :ready} = SeedWorld.import(ctx.root, ctx.store)

      start_uuid = entry_uuid!(ctx.root, "start", ctx.store)
      clearing_uuid = entry_uuid!(ctx.root, "clearing", ctx.store)

      cloak_uuid = entry_uuid!(start_uuid, "cloak.obj", ctx.store)
      assert {:ok, cloak} = Schemas.load_object(cloak_uuid, ctx.store)
      assert cloak.name == "cloak"
      assert cloak.aliases == ["cape", "black cloak"]
      assert cloak.description == "A heavy black cloak. It looks warm."
      assert cloak.fixed == false
      assert cloak.tick_interval_ms == nil
      assert cloak.tick_message == nil

      fountain_uuid = entry_uuid!(clearing_uuid, "fountain.obj", ctx.store)
      assert {:ok, fountain} = Schemas.load_object(fountain_uuid, ctx.store)
      assert fountain.name == "fountain"
      assert fountain.aliases == ["water"]
      assert fountain.description == "A stone fountain murmurs softly."
      assert fountain.fixed == true
      assert fountain.tick_interval_ms == 8_000
      assert fountain.tick_message == "The fountain burbles softly."
    end

    test "the iron vein carries exact economy numbers (regen_per_ms == 1/30_000 precisely)",
         ctx do
      assert {:ok, :ready} = SeedWorld.import(ctx.root, ctx.store)

      forest_uuid = entry_uuid!(ctx.root, "forest-path", ctx.store)
      vein_uuid = entry_uuid!(forest_uuid, "iron-vein.obj", ctx.store)

      assert {:ok, vein} = Schemas.load_object(vein_uuid, ctx.store)
      assert vein.name == "iron vein"
      assert vein.aliases == ["vein", "iron"]
      assert vein.description == "A vein of raw iron runs through the rock here."
      assert vein.fixed == true
      assert vein.kind == "vein"

      assert vein.yield_type == %{
               "name" => "iron ore",
               "aliases" => ["ore"],
               "description" => "A rough chunk of iron ore."
             }

      assert vein.yield_max == 5
      assert vein.regen_per_ms == 1 / 30_000
      assert vein.yield_remaining == 5
      assert vein.last_regen_at == 0
    end

    test "the iron-ingot recipe is exact", ctx do
      assert {:ok, :ready} = SeedWorld.import(ctx.root, ctx.store)

      recipes_dir = entry_uuid!(ctx.root, "__recipes", ctx.store)
      recipe_uuid = entry_uuid!(recipes_dir, "iron-ingot", ctx.store)

      assert {:ok, recipe} = Schemas.load_recipe(recipe_uuid, ctx.store)
      assert recipe.name == "iron ingot"
      assert recipe.inputs == [%{"type" => "iron ore", "qty" => 2}]

      assert recipe.output == %{
               "name" => "iron ingot",
               "aliases" => ["ingot"],
               "description" => "A sturdy bar of smelted iron."
             }

      assert recipe.station == nil
    end
  end

  describe "(2) idempotence" do
    test "a second import changes nothing (same commit ids, seed-once marker respected)", ctx do
      assert {:ok, :ready} = SeedWorld.import(ctx.root, ctx.store)

      start_uuid = entry_uuid!(ctx.root, "start", ctx.store)

      {:ok, %Commonplace.Store.Commit{id: start_commit_before}} =
        CommitStore.latest_commit(ctx.store, start_uuid)

      cloak_uuid_before = entry_uuid!(start_uuid, "cloak.obj", ctx.store)

      assert {:ok, :ready} = SeedWorld.import(ctx.root, ctx.store)

      {:ok, %Commonplace.Store.Commit{id: start_commit_after}} =
        CommitStore.latest_commit(ctx.store, start_uuid)

      assert start_commit_before == start_commit_after

      cloak_uuid_after = entry_uuid!(start_uuid, "cloak.obj", ctx.store)
      assert cloak_uuid_before == cloak_uuid_after
    end

    test "taking the seeded cloak then re-importing does not re-mint it (CX-k8lq)", ctx do
      assert {:ok, :ready} = SeedWorld.import(ctx.root, ctx.store)
      start_uuid = entry_uuid!(ctx.root, "start", ctx.store)

      {:ok, start_schema} = Schemas.load_dir_schema(start_uuid, ctx.store)
      schema = Schema.remove_entry(start_schema, "cloak.obj")
      update = Encoding.encode_update(schema)

      %Commonplace.Store.Commit{} =
        CommitStore.create_chained_commit(ctx.store, start_uuid, update)

      assert {:ok, :ready} = SeedWorld.import(ctx.root, ctx.store)

      {:ok, start_schema_after} = Schemas.load_dir_schema(start_uuid, ctx.store)
      assert :error = Schema.get_entry(start_schema_after, "cloak.obj")
    end
  end

  describe "(3) enforce" do
    setup %{store: store} do
      old_data_dir = Application.get_env(:commonplace, :data_dir)
      old_trust = Application.get_env(:commonplace, :trust)
      old_knob = Application.get_env(:commonplace, :local_write_gate)

      node_dir =
        Path.join(System.tmp_dir!(), "cp_seed_world_node_#{:rand.uniform(1_000_000_000)}")

      File.mkdir_p!(node_dir)
      Application.put_env(:commonplace, :data_dir, node_dir)

      {:ok, node_ctx} = NodeIdentity.signing_context()
      node_signer_id = Signing.signer_id(node_ctx.identity_uuid, node_ctx.public_key)

      Application.put_env(:commonplace, :trust, %{accept_unsigned: false, trusted_identities: %{}})

      Application.put_env(:commonplace, :local_write_gate, :enforce)

      on_exit(fn ->
        case old_data_dir do
          nil -> Application.delete_env(:commonplace, :data_dir)
          v -> Application.put_env(:commonplace, :data_dir, v)
        end

        case old_trust do
          nil -> Application.delete_env(:commonplace, :trust)
          v -> Application.put_env(:commonplace, :trust, v)
        end

        case old_knob do
          nil -> Application.delete_env(:commonplace, :local_write_gate)
          v -> Application.put_env(:commonplace, :local_write_gate, v)
        end

        File.rm_rf!(node_dir)
      end)

      # A fresh, NODE-SIGNED root (mirrors `CitizenshipTest`'s enforce
      # fixture) — the outer `setup`'s root was minted before this block
      # flipped the gate to `:enforce` and is unsigned; this block's own
      # writes (via `SeedWorld.import/2`) are what's under test, so the
      # root itself should be a legitimate accountable commit too.
      root_uuid = UUID.uuid4()
      update = Encoding.encode_update(Schema.new_schema())

      assert %Commonplace.Store.Commit{} =
               CommitStore.create_commit(store, root_uuid, update, nil, %{},
                 signing_context: node_ctx
               )

      %{node_ctx: node_ctx, node_signer_id: node_signer_id, store: store, root: root_uuid}
    end

    test "import seeds green under strict+enforce, and every write is node-signed", ctx do
      assert {:ok, :ready} = SeedWorld.import(ctx.root, ctx.store)

      start_uuid = entry_uuid!(ctx.root, "start", ctx.store)
      forest_uuid = entry_uuid!(ctx.root, "forest-path", ctx.store)
      clearing_uuid = entry_uuid!(ctx.root, "clearing", ctx.store)
      cloak_uuid = entry_uuid!(start_uuid, "cloak.obj", ctx.store)
      fountain_uuid = entry_uuid!(clearing_uuid, "fountain.obj", ctx.store)
      vein_uuid = entry_uuid!(forest_uuid, "iron-vein.obj", ctx.store)
      recipes_dir = entry_uuid!(ctx.root, "__recipes", ctx.store)
      recipe_uuid = entry_uuid!(recipes_dir, "iron-ingot", ctx.store)

      for uuid <- [
            ctx.root,
            start_uuid,
            forest_uuid,
            clearing_uuid,
            cloak_uuid,
            fountain_uuid,
            vein_uuid,
            recipes_dir,
            recipe_uuid
          ] do
        assert {:ok, %Commonplace.Store.Commit{signer_id: signer}} =
                 CommitStore.latest_commit(ctx.store, uuid)

        assert signer == ctx.node_signer_id, "expected #{uuid} to be node-signed"
      end
    end
  end

  describe "(4) phase decoupling (CX-g5lb(b))" do
    test "run_phases/1 invokes every thunk regardless of an earlier error, and reports the FIRST error" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      record = fn tag -> Agent.update(agent, &(&1 ++ [tag])) end

      result =
        SeedWorld.run_phases([
          fn ->
            record.(:rooms)
            {:error, :rooms_denied}
          end,
          fn ->
            record.(:objects)
            :ok
          end,
          fn ->
            record.(:veins)
            :ok
          end,
          fn ->
            record.(:recipes)
            :ok
          end
        ])

      assert result == {:error, :rooms_denied}
      assert Agent.get(agent, & &1) == [:rooms, :objects, :veins, :recipes]
    end

    test "run_phases/1 returns the FIRST error when multiple phases fail" do
      result =
        SeedWorld.run_phases([
          fn -> :ok end,
          fn -> {:error, :second_denied} end,
          fn -> {:error, :third_denied} end,
          fn -> :ok end
        ])

      assert result == {:error, :second_denied}
    end

    test "run_phases/1 returns {:ok, :ready} when every phase is clean" do
      assert {:ok, :ready} = SeedWorld.run_phases([fn -> :ok end, fn -> :ok end])
    end
  end
end
