defmodule Commonplace.MUD.MoveTest do
  use ExUnit.Case, async: false

  alias Commonplace.Green.Bursar
  alias Commonplace.MUD.{Move, Schemas}
  alias Commonplace.MUD.Schemas.Object
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_mud_move_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    bursar_name = :"bursar_#{:rand.uniform(1_000_000)}"

    {:ok, bpid} =
      Bursar.start_link(
        root_uuid: UUID.uuid4(),
        store: store_name,
        name: bursar_name,
        sweep_interval: 60_000
      )

    on_exit(fn -> if Process.alive?(bpid), do: GenServer.stop(bpid) end)

    %{store: store_name, bursar: bursar_name, opts: [store: store_name, bursar: bursar_name]}
  end

  defp make_dir_with_object(store, obj_name) do
    obj_json = Schemas.encode_object(%Object{name: obj_name, description: "An object."})
    obj_dir = Schemas.create_dir_with_meta(Schemas.object_filename(), obj_json, store)

    parent = UUID.uuid4()
    schema = Schema.new_schema() |> Schema.add_directory("#{obj_name}.obj", obj_dir)
    update = Encoding.encode_update(schema)
    CommitStore.create_commit(store, parent, update, nil)

    {parent, obj_dir}
  end

  defp empty_dir(store) do
    uuid = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, uuid, update, nil)
    uuid
  end

  defp load(uuid, store) do
    {:ok, schema} = Schemas.load_dir_schema(uuid, store)
    schema
  end

  describe "move semantics (preserved from MoveServer v0)" do
    test "successful move adds to dest and removes from source", %{store: store, opts: opts} do
      {source, obj_dir} = make_dir_with_object(store, "cloak")
      dest = empty_dir(store)

      :ok = Move.move(obj_dir, "cloak.obj", source, dest, opts)

      assert :error = Schema.get_entry(load(source, store), "cloak.obj")
      {:ok, entry} = Schema.get_entry(load(dest, store), "cloak.obj")
      assert entry.node_id == obj_dir
      assert entry.type == :dir
    end

    test "race-loser gets :gone", %{store: store, opts: opts} do
      {source, obj_dir} = make_dir_with_object(store, "sword")
      dest_a = empty_dir(store)
      dest_b = empty_dir(store)

      :ok = Move.move(obj_dir, "sword.obj", source, dest_a, opts)
      {:error, :gone} = Move.move(obj_dir, "sword.obj", source, dest_b, opts)
    end

    test "moving to same dir is a no-op", %{store: store, opts: opts} do
      {source, obj_dir} = make_dir_with_object(store, "torch")
      :ok = Move.move(obj_dir, "torch.obj", source, source, opts)
      {:ok, entry} = Schema.get_entry(load(source, store), "torch.obj")
      assert entry.node_id == obj_dir
    end

    test "missing entry at source returns :gone", %{store: store, opts: opts} do
      source = empty_dir(store)
      dest = empty_dir(store)
      {:error, :gone} = Move.move(UUID.uuid4(), "ghost.obj", source, dest, opts)
    end

    test "name collision at dest returns :collision", %{store: store, opts: opts} do
      {source, obj_dir} = make_dir_with_object(store, "cloak")
      {dest, _other} = make_dir_with_object(store, "cloak")
      {:error, :collision} = Move.move(obj_dir, "cloak.obj", source, dest, opts)
    end
  end

  describe "green-token locking (move #4)" do
    test "tokens are released after a successful move", ctx do
      {source, obj_dir} = make_dir_with_object(ctx.store, "cloak")
      dest = empty_dir(ctx.store)

      :ok = Move.move(obj_dir, "cloak.obj", source, dest, ctx.opts)

      assert :available = Bursar.query(ctx.bursar, source)
      assert :available = Bursar.query(ctx.bursar, dest)
    end

    test "tokens are released on the error path", ctx do
      source = empty_dir(ctx.store)
      dest = empty_dir(ctx.store)

      {:error, :gone} = Move.move(UUID.uuid4(), "ghost.obj", source, dest, ctx.opts)

      assert :available = Bursar.query(ctx.bursar, source)
      assert :available = Bursar.query(ctx.bursar, dest)
    end

    test "tokens are released when the move crashes mid-flight", ctx do
      # A dead store makes do_move exit after the tokens are acquired;
      # try/after must still release them.
      {source, obj_dir} = make_dir_with_object(ctx.store, "cloak")
      dest = empty_dir(ctx.store)

      catch_exit(
        Move.move(obj_dir, "cloak.obj", source, dest,
          store: :no_such_store, bursar: ctx.bursar)
      )

      assert :available = Bursar.query(ctx.bursar, source)
      assert :available = Bursar.query(ctx.bursar, dest)
    end

    test "contended dir → bounded retry → {:error, :busy}, nothing left held", ctx do
      {source, obj_dir} = make_dir_with_object(ctx.store, "sword")
      dest = empty_dir(ctx.store)

      # Another holder owns the dest dir's token.
      {:ok, _} = Bursar.acquire(ctx.bursar, dest, "someone-else")

      assert {:error, :busy} =
               Move.move(obj_dir, "sword.obj", source, dest,
                 ctx.opts ++ [retries: 2, retry_ms: 10])

      # The loser must not leave its partial acquisition behind.
      assert :available = Bursar.query(ctx.bursar, source)
      assert {:held, %{holder: "someone-else"}} = Bursar.query(ctx.bursar, dest)

      # And the move must NOT have happened.
      {:ok, entry} = Schema.get_entry(load(source, ctx.store), "sword.obj")
      assert entry.node_id == obj_dir
    end

    test "no bursar reachable → {:error, :bursar_unavailable}, move does not happen", ctx do
      {source, obj_dir} = make_dir_with_object(ctx.store, "sword")
      dest = empty_dir(ctx.store)

      assert {:error, :bursar_unavailable} =
               Move.move(obj_dir, "sword.obj", source, dest,
                 store: ctx.store, bursar: :no_such_bursar)

      {:ok, entry} = Schema.get_entry(load(source, ctx.store), "sword.obj")
      assert entry.node_id == obj_dir
    end
  end
end
