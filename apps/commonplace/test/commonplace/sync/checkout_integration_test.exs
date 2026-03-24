defmodule Commonplace.Sync.CheckoutIntegrationTest do
  @moduledoc """
  Integration tests exercising the full checkout lifecycle end-to-end.

  Tests the interaction between CheckoutRegistry, DirAgent, EntryAgent,
  and the filesystem — verifying that edits flow in both directions
  (disk -> CRDT and CRDT -> disk) through the sparse sync system.
  """
  use ExUnit.Case

  alias Commonplace.Sync.{CheckoutRegistry, DirAgent, EntryAgent}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType

  setup do
    store_dir = Path.join(System.tmp_dir!(), "cp_int_store_#{:rand.uniform(1_000_000)}")
    work_dir = Path.join(System.tmp_dir!(), "cp_int_work_#{:rand.uniform(1_000_000)}")
    config_dir = Path.join(work_dir, ".commonplace")
    config_path = Path.join(config_dir, "checkouts.json")
    File.mkdir_p!(store_dir)
    File.mkdir_p!(config_dir)

    store_name = :"int_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: store_dir, name: store_name})

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

  # --- Helpers ---

  defp create_text_doc(store, content) do
    uuid = UUID.uuid4()
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
    uuid
  end

  defp create_schema_doc(store, entries) do
    uuid = UUID.uuid4()

    schema =
      Enum.reduce(entries, Schema.new_schema(), fn {name, type, node_id}, schema ->
        case type do
          :doc -> Schema.add_file(schema, name, node_id)
          :dir -> Schema.add_directory(schema, name, node_id)
        end
      end)

    update = Yelixer.Encoding.encode_update(schema)
    CommitStore.create_commit(store, uuid, update, nil)
    uuid
  end

  defp read_doc_content(store, uuid) do
    {:ok, commit} = CommitStore.latest_commit(store, uuid)
    doc = Yelixer.Doc.new()
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
    ContentType.get_content(doc)
  end

  defp start_registry(config_path, store) do
    {:ok, pid} =
      CheckoutRegistry.start_link(
        config_path: config_path,
        store: store
      )

    pid
  end

  describe "full checkout lifecycle" do
    test "checkout -> edit on disk -> sync -> verify CRDT -> edit CRDT -> sync -> verify disk",
         %{store: store, config_path: config_path, work_dir: work_dir} do
      # 1. Create a CommitStore with a root schema containing 2 file entries
      readme_uuid = create_text_doc(store, "# README")
      config_uuid = create_text_doc(store, "key=value")

      root_uuid =
        create_schema_doc(store, [
          {"readme.md", :doc, readme_uuid},
          {"config.txt", :doc, config_uuid}
        ])

      # 2. Create a temp directory for the checkout
      sync_dir = Path.join(work_dir, "checkout_lifecycle")

      # 3. Start CheckoutRegistry
      registry = start_registry(config_path, store)

      # 4. Register a directory checkout pointing at the root schema
      {:ok, checkout} = CheckoutRegistry.register(registry, sync_dir, root_uuid, :dir)

      # 5. Trigger sync
      DirAgent.sync_once(checkout.pid)

      # 6. Verify both files appear on disk with correct content
      assert File.read!(Path.join(sync_dir, "readme.md")) == "# README"
      assert File.read!(Path.join(sync_dir, "config.txt")) == "key=value"

      # 7. Modify "readme.md" on disk
      File.write!(Path.join(sync_dir, "readme.md"), "# Updated README")

      # 8. Sync again
      DirAgent.sync_once(checkout.pid)

      # 9. Verify the CommitStore has a new commit for readme.md with modified content
      assert read_doc_content(store, readme_uuid) == "# Updated README"

      # 10. Modify the CRDT for "config.txt" (create a new commit directly)
      new_doc = Yelixer.Doc.new()
      new_doc = ContentType.create(new_doc, :text, "config.txt")
      new_doc = ContentType.insert_text(new_doc, 0, "key=new_value")
      new_update = Yelixer.Encoding.encode_update(new_doc)
      CommitStore.create_chained_commit(store, config_uuid, new_update)

      # 11. Sync again
      DirAgent.sync_once(checkout.pid)

      # 12. Verify "config.txt" on disk has the new CRDT content
      assert File.read!(Path.join(sync_dir, "config.txt")) == "key=new_value"

      GenServer.stop(registry)
    end
  end

  describe "overlapping checkouts sync through CRDT" do
    test "changes in one checkout propagate to another via shared CRDT",
         %{store: store, config_path: config_path, work_dir: work_dir} do
      # 1. Create a CommitStore with a root schema containing "shared.txt"
      shared_uuid = create_text_doc(store, "shared content")
      root_uuid = create_schema_doc(store, [{"shared.txt", :doc, shared_uuid}])

      # 2. Create two temp directories
      checkout_a = Path.join(work_dir, "checkout_a")
      checkout_b = Path.join(work_dir, "checkout_b")

      # 3. Start CheckoutRegistry, register both dirs pointing at same root
      registry = start_registry(config_path, store)
      {:ok, co_a} = CheckoutRegistry.register(registry, checkout_a, root_uuid, :dir)
      {:ok, co_b} = CheckoutRegistry.register(registry, checkout_b, root_uuid, :dir)

      # 4. Sync both
      DirAgent.sync_once(co_a.pid)
      DirAgent.sync_once(co_b.pid)

      # 5. Verify "shared.txt" appears in both dirs with same content
      assert File.read!(Path.join(checkout_a, "shared.txt")) == "shared content"
      assert File.read!(Path.join(checkout_b, "shared.txt")) == "shared content"

      # 6. Modify "shared.txt" in checkout_a dir
      File.write!(Path.join(checkout_a, "shared.txt"), "updated by checkout A")

      # 7. Sync checkout_a (disk -> CRDT)
      DirAgent.sync_once(co_a.pid)

      # 8. Sync checkout_b (CRDT -> disk)
      DirAgent.sync_once(co_b.pid)

      # 9. Verify checkout_b now has the modified content
      assert File.read!(Path.join(checkout_b, "shared.txt")) == "updated by checkout A"

      GenServer.stop(registry)
    end
  end

  describe "reroot changes content" do
    test "rerooting to a different branch switches the files on disk",
         %{store: store, config_path: config_path, work_dir: work_dir} do
      # 1. Create two branches (branch_a with "a.txt", branch_b with "b.txt")
      a_uuid = create_text_doc(store, "content of a")
      b_uuid = create_text_doc(store, "content of b")

      branch_a_uuid = create_schema_doc(store, [{"a.txt", :doc, a_uuid}])
      branch_b_uuid = create_schema_doc(store, [{"b.txt", :doc, b_uuid}])

      sync_dir = Path.join(work_dir, "checkout_reroot")

      # 2. Register checkout pointing at branch_a
      registry = start_registry(config_path, store)
      {:ok, co} = CheckoutRegistry.register(registry, sync_dir, branch_a_uuid, :dir)

      # 3. Sync -- verify "a.txt" on disk
      DirAgent.sync_once(co.pid)
      assert File.read!(Path.join(sync_dir, "a.txt")) == "content of a"

      # 4. Reroot to branch_b
      {:ok, rerooted} = CheckoutRegistry.reroot(registry, sync_dir, branch_b_uuid)

      # 5. Sync -- verify "b.txt" on disk
      DirAgent.sync_once(rerooted.pid)
      assert File.read!(Path.join(sync_dir, "b.txt")) == "content of b"

      GenServer.stop(registry)
    end
  end

  describe "file checkout" do
    test "single file checkout syncs bidirectionally",
         %{store: store, config_path: config_path, work_dir: work_dir} do
      # 1. Create a single text doc with content
      doc_uuid = create_text_doc(store, "standalone content")

      # 2. Register a file checkout pointing at it
      file_path = Path.join(work_dir, "standalone.txt")
      registry = start_registry(config_path, store)
      {:ok, co} = CheckoutRegistry.register(registry, file_path, doc_uuid, :file)

      # 3. Sync
      EntryAgent.sync_once(co.pid)

      # 4. Verify file on disk
      assert File.read!(file_path) == "standalone content"

      # 5. Modify file on disk
      File.write!(file_path, "modified standalone")

      # 6. Sync
      EntryAgent.sync_once(co.pid)

      # 7. Verify CRDT updated
      assert read_doc_content(store, doc_uuid) == "modified standalone"

      GenServer.stop(registry)
    end
  end
end
