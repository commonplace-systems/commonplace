defmodule Commonplace.Sync.SchemaCoordinatorTest do
  @moduledoc """
  Tests for SchemaCoordinator — serialized schema mutation.

  Verifies that concurrent mutations to the same schema UUID are
  serialized through a single GenServer, preventing CRDT corruption.
  """
  use ExUnit.Case

  alias Commonplace.Sync.SchemaCoordinator
  alias Commonplace.Tree.{Schema, DocBuilder}
  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_coord_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"coord_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})

    # SchemaCoordinator relies on Registry + DynamicSupervisor from application.ex
    # These are started by the application, but in tests we need to ensure they exist.
    reg_name = Commonplace.SchemaCoordinator.Registry
    sup_name = Commonplace.SchemaCoordinator.Supervisor

    unless Process.whereis(reg_name) || registry_alive?(reg_name) do
      start_supervised!({Registry, keys: :unique, name: reg_name})
    end

    unless Process.whereis(sup_name) do
      start_supervised!({DynamicSupervisor, name: sup_name, strategy: :one_for_one})
    end

    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name}
  end

  defp registry_alive?(name) do
    case Registry.lookup(name, "__probe__") do
      _ -> true
    end
  rescue
    ArgumentError -> false
  end

  defp seed_schema(store, uuid) do
    doc =
      Schema.new_schema()
      |> Schema.add_file("existing.txt", UUID.uuid4())

    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_chained_commit(store, uuid, update)
  end

  describe "mutate/3" do
    test "serializes concurrent mutations to the same schema", %{store: store} do
      schema_uuid = UUID.uuid4()
      seed_schema(store, schema_uuid)

      # Launch two concurrent mutations
      task_a =
        Task.async(fn ->
          SchemaCoordinator.mutate(schema_uuid, store, fn doc ->
            uuid_a = UUID.uuid4()
            doc = Schema.add_file(doc, "file_a.txt", uuid_a)
            {doc, {:added, "file_a.txt", uuid_a}}
          end)
        end)

      task_b =
        Task.async(fn ->
          SchemaCoordinator.mutate(schema_uuid, store, fn doc ->
            uuid_b = UUID.uuid4()
            doc = Schema.add_file(doc, "file_b.txt", uuid_b)
            {doc, {:added, "file_b.txt", uuid_b}}
          end)
        end)

      assert {:ok, {:added, "file_a.txt", _}} = Task.await(task_a)
      assert {:ok, {:added, "file_b.txt", _}} = Task.await(task_b)

      # Reconstruct the final schema — both entries should be present.
      # Note: each mutation reconstructs from the full commit chain,
      # so the second mutation sees the first mutation's commit.
      {:ok, final_doc} = DocBuilder.reconstruct_doc(store, schema_uuid)
      entries = Schema.entries(final_doc)

      assert Map.has_key?(entries, "existing.txt")
      assert Map.has_key?(entries, "file_a.txt")
      assert Map.has_key?(entries, "file_b.txt")
    end

    test "returns the mutation function's result", %{store: store} do
      schema_uuid = UUID.uuid4()
      seed_schema(store, schema_uuid)

      result =
        SchemaCoordinator.mutate(schema_uuid, store, fn doc ->
          doc = Schema.add_file(doc, "result_test.txt", "uuid-rt")
          {doc, :my_custom_result}
        end)

      assert {:ok, :my_custom_result} = result
    end

    test "returns error when schema has no commits", %{store: store} do
      missing_uuid = UUID.uuid4()

      result =
        SchemaCoordinator.mutate(missing_uuid, store, fn doc ->
          {doc, :should_not_reach}
        end)

      assert {:error, :no_schema} = result
    end

    test "reuses the same coordinator process for the same UUID", %{store: store} do
      schema_uuid = UUID.uuid4()
      seed_schema(store, schema_uuid)

      # First call — starts the coordinator
      SchemaCoordinator.mutate(schema_uuid, store, fn doc ->
        {doc, :first}
      end)

      [{pid1, _}] = Registry.lookup(Commonplace.SchemaCoordinator.Registry, schema_uuid)

      # Second call — reuses the coordinator
      SchemaCoordinator.mutate(schema_uuid, store, fn doc ->
        {doc, :second}
      end)

      [{pid2, _}] = Registry.lookup(Commonplace.SchemaCoordinator.Registry, schema_uuid)

      assert pid1 == pid2
      assert Process.alive?(pid1)
    end

    test "different UUIDs get different coordinator processes", %{store: store} do
      uuid_1 = UUID.uuid4()
      uuid_2 = UUID.uuid4()
      seed_schema(store, uuid_1)
      seed_schema(store, uuid_2)

      SchemaCoordinator.mutate(uuid_1, store, fn doc ->
        {doc, :ok}
      end)

      SchemaCoordinator.mutate(uuid_2, store, fn doc ->
        {doc, :ok}
      end)

      [{pid1, _}] = Registry.lookup(Commonplace.SchemaCoordinator.Registry, uuid_1)
      [{pid2, _}] = Registry.lookup(Commonplace.SchemaCoordinator.Registry, uuid_2)

      assert pid1 != pid2
    end
  end
end
