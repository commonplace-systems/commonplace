defmodule Commonplace.Sync.CheckoutRegistryTest do
  @moduledoc """
  Tests for CheckoutRegistry — the central coordinator for multi-checkout.

  Verifies registration, unregistration, rerooting, persistence across
  restarts, file checkout support, and duplicate rejection.
  """
  use ExUnit.Case

  alias Commonplace.Sync.CheckoutRegistry
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType

  setup do
    store_dir = Path.join(System.tmp_dir!(), "cp_reg_store_#{:rand.uniform(1_000_000)}")
    work_dir = Path.join(System.tmp_dir!(), "cp_reg_work_#{:rand.uniform(1_000_000)}")
    config_dir = Path.join(work_dir, ".commonplace")
    config_path = Path.join(config_dir, "checkouts.json")
    File.mkdir_p!(store_dir)
    File.mkdir_p!(config_dir)

    store_name = :"reg_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: store_dir, name: store_name})

    # CheckoutRegistry needs the DynamicSupervisor and SchemaCoordinator infra
    ensure_checkout_supervisor()
    ensure_schema_infra()

    on_exit(fn ->
      File.rm_rf!(store_dir)
      File.rm_rf!(work_dir)
    end)

    %{
      store: store_name,
      config_path: config_path,
      work_dir: work_dir
    }
  end

  defp ensure_checkout_supervisor do
    unless Process.whereis(Commonplace.Checkout.Supervisor) do
      start_supervised!(
        {DynamicSupervisor, name: Commonplace.Checkout.Supervisor, strategy: :one_for_one}
      )
    end
  end

  defp ensure_schema_infra do
    reg_name = Commonplace.SchemaCoordinator.Registry
    sup_name = Commonplace.SchemaCoordinator.Supervisor

    unless registry_alive?(reg_name) do
      start_supervised!({Registry, keys: :unique, name: reg_name})
    end

    unless Process.whereis(sup_name) do
      start_supervised!({DynamicSupervisor, name: sup_name, strategy: :one_for_one})
    end
  end

  defp registry_alive?(name) do
    case Registry.lookup(name, "__probe__") do
      _ -> true
    end
  rescue
    ArgumentError -> false
  end

  defp seed_schema(store, uuid) do
    doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  defp seed_text_doc(store, uuid, content) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "file.txt")

    doc =
      if content != "" do
        ContentType.insert_text(doc, 0, content)
      else
        doc
      end

    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  defp start_registry(config_path, store) do
    {:ok, pid} =
      CheckoutRegistry.start_link(
        config_path: config_path,
        store: store
      )

    pid
  end

  describe "register and list" do
    test "register a dir checkout, list returns it", %{
      store: store,
      config_path: config_path,
      work_dir: work_dir
    } do
      schema_uuid = UUID.uuid4()
      seed_schema(store, schema_uuid)

      sync_dir = Path.join(work_dir, "checkout_a")
      pid = start_registry(config_path, store)

      assert {:ok, checkout} = CheckoutRegistry.register(pid, sync_dir, schema_uuid, :dir)
      assert checkout.sync_dir == sync_dir
      assert checkout.uuid == schema_uuid
      assert checkout.type == :dir
      assert is_pid(checkout.pid)

      checkouts = CheckoutRegistry.list(pid)
      assert length(checkouts) == 1
      [first] = checkouts
      assert first.sync_dir == sync_dir
      assert first.uuid == schema_uuid
      assert first.type == :dir

      GenServer.stop(pid)
    end
  end

  describe "unregister" do
    test "register then unregister, list returns empty", %{
      store: store,
      config_path: config_path,
      work_dir: work_dir
    } do
      schema_uuid = UUID.uuid4()
      seed_schema(store, schema_uuid)

      sync_dir = Path.join(work_dir, "checkout_b")
      pid = start_registry(config_path, store)

      {:ok, _checkout} = CheckoutRegistry.register(pid, sync_dir, schema_uuid, :dir)
      assert length(CheckoutRegistry.list(pid)) == 1

      assert :ok = CheckoutRegistry.unregister(pid, sync_dir)
      assert CheckoutRegistry.list(pid) == []

      GenServer.stop(pid)
    end

    test "unregister non-existent returns error", %{
      store: store,
      config_path: config_path
    } do
      pid = start_registry(config_path, store)

      assert {:error, :not_found} = CheckoutRegistry.unregister(pid, "/nonexistent")

      GenServer.stop(pid)
    end
  end

  describe "reroot" do
    test "register, reroot to different uuid, list shows new uuid", %{
      store: store,
      config_path: config_path,
      work_dir: work_dir
    } do
      old_uuid = UUID.uuid4()
      new_uuid = UUID.uuid4()
      seed_schema(store, old_uuid)
      seed_schema(store, new_uuid)

      sync_dir = Path.join(work_dir, "checkout_c")
      pid = start_registry(config_path, store)

      {:ok, _checkout} = CheckoutRegistry.register(pid, sync_dir, old_uuid, :dir)

      [first] = CheckoutRegistry.list(pid)
      assert first.uuid == old_uuid
      old_agent_pid = first.pid

      {:ok, rerooted} = CheckoutRegistry.reroot(pid, sync_dir, new_uuid)
      assert rerooted.uuid == new_uuid
      assert rerooted.type == :dir
      # New agent process should be different from old one
      refute rerooted.pid == old_agent_pid

      [updated] = CheckoutRegistry.list(pid)
      assert updated.uuid == new_uuid

      # Old agent should be dead
      refute Process.alive?(old_agent_pid)

      GenServer.stop(pid)
    end

    test "reroot non-existent returns error", %{
      store: store,
      config_path: config_path
    } do
      pid = start_registry(config_path, store)

      assert {:error, :not_found} = CheckoutRegistry.reroot(pid, "/nonexistent", "new-uuid")

      GenServer.stop(pid)
    end
  end

  describe "persistence" do
    test "register, stop registry, restart, list shows persisted checkout", %{
      store: store,
      config_path: config_path,
      work_dir: work_dir
    } do
      schema_uuid = UUID.uuid4()
      seed_schema(store, schema_uuid)

      sync_dir = Path.join(work_dir, "checkout_persist")
      pid1 = start_registry(config_path, store)

      {:ok, _checkout} = CheckoutRegistry.register(pid1, sync_dir, schema_uuid, :dir)
      GenServer.stop(pid1)

      # Verify JSON file was written
      assert File.exists?(config_path)

      # Restart registry — should reload from JSON
      pid2 = start_registry(config_path, store)

      checkouts = CheckoutRegistry.list(pid2)
      assert length(checkouts) == 1
      [restored] = checkouts
      assert restored.sync_dir == sync_dir
      assert restored.uuid == schema_uuid
      assert restored.type == :dir
      assert is_pid(restored.pid)

      GenServer.stop(pid2)
    end
  end

  describe "file checkout" do
    test "register with type: :file", %{
      store: store,
      config_path: config_path,
      work_dir: work_dir
    } do
      doc_uuid = UUID.uuid4()
      seed_text_doc(store, doc_uuid, "hello world")

      file_path = Path.join(work_dir, "standalone.txt")
      pid = start_registry(config_path, store)

      {:ok, checkout} = CheckoutRegistry.register(pid, file_path, doc_uuid, :file)
      assert checkout.type == :file
      assert checkout.sync_dir == file_path
      assert is_pid(checkout.pid)

      checkouts = CheckoutRegistry.list(pid)
      assert length(checkouts) == 1
      assert hd(checkouts).type == :file

      GenServer.stop(pid)
    end
  end

  describe "duplicate sync_dir rejected" do
    test "registering same sync_dir twice returns error", %{
      store: store,
      config_path: config_path,
      work_dir: work_dir
    } do
      uuid1 = UUID.uuid4()
      uuid2 = UUID.uuid4()
      seed_schema(store, uuid1)
      seed_schema(store, uuid2)

      sync_dir = Path.join(work_dir, "checkout_dup")
      pid = start_registry(config_path, store)

      {:ok, _checkout} = CheckoutRegistry.register(pid, sync_dir, uuid1, :dir)
      assert {:error, :already_registered} = CheckoutRegistry.register(pid, sync_dir, uuid2, :dir)

      # Still only one checkout
      assert length(CheckoutRegistry.list(pid)) == 1

      GenServer.stop(pid)
    end
  end

  describe "breadcrumb files" do
    test "creates .commonplace-ref on register and removes on unregister", %{
      store: store,
      config_path: config_path
    } do
      schema_uuid = UUID.uuid4()
      seed_schema(store, schema_uuid)

      # Use a directory outside the .commonplace tree
      out_of_tree = Path.join(System.tmp_dir!(), "cp_oot_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(out_of_tree)

      on_exit(fn -> File.rm_rf!(out_of_tree) end)

      pid = start_registry(config_path, store)

      {:ok, _checkout} = CheckoutRegistry.register(pid, out_of_tree, schema_uuid, :dir)

      ref_path = Path.join(out_of_tree, ".commonplace-ref")
      assert File.exists?(ref_path)
      assert File.read!(ref_path) == Path.dirname(config_path)

      CheckoutRegistry.unregister(pid, out_of_tree)
      refute File.exists?(ref_path)

      GenServer.stop(pid)
    end

    test "creates .commonplace-ref in parent dir for file checkouts", %{
      store: store,
      config_path: config_path
    } do
      doc_uuid = UUID.uuid4()
      seed_text_doc(store, doc_uuid, "content")

      out_dir = Path.join(System.tmp_dir!(), "cp_oot_file_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(out_dir)
      file_path = Path.join(out_dir, "todo.txt")

      on_exit(fn -> File.rm_rf!(out_dir) end)

      pid = start_registry(config_path, store)

      {:ok, _checkout} = CheckoutRegistry.register(pid, file_path, doc_uuid, :file)

      ref_path = Path.join(out_dir, ".commonplace-ref")
      assert File.exists?(ref_path)

      CheckoutRegistry.unregister(pid, file_path)
      refute File.exists?(ref_path)

      GenServer.stop(pid)
    end
  end
end
