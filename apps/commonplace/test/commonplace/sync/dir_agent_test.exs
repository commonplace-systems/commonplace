defmodule Commonplace.Sync.DirAgentTest do
  @moduledoc """
  Tests for DirAgent — per-directory schema watcher.

  Verifies that DirAgent manages child EntryAgents and DirAgents,
  reconciles disk state with schema state, and handles edge cases
  like sync:false entries and .commonplace files.
  """
  use ExUnit.Case

  alias Commonplace.Sync.DirAgent
  alias Commonplace.Tree.{Schema, DocBuilder}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore

  setup do
    store_dir = Path.join(System.tmp_dir!(), "cp_dir_store_#{:rand.uniform(1_000_000)}")
    sync_dir = Path.join(System.tmp_dir!(), "cp_dir_sync_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(store_dir)
    File.mkdir_p!(sync_dir)

    store_name = :"dir_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: store_dir, name: store_name})

    # SchemaCoordinator depends on Registry + DynamicSupervisor
    reg_name = Commonplace.SchemaCoordinator.Registry
    sup_name = Commonplace.SchemaCoordinator.Supervisor

    unless registry_alive?(reg_name) do
      start_supervised!({Registry, keys: :unique, name: reg_name})
    end

    unless Process.whereis(sup_name) do
      start_supervised!({DynamicSupervisor, name: sup_name, strategy: :one_for_one})
    end

    on_exit(fn ->
      File.rm_rf!(store_dir)
      File.rm_rf!(sync_dir)
    end)

    %{store: store_name, sync_dir: sync_dir}
  end

  defp registry_alive?(name) do
    case Registry.lookup(name, "__probe__") do
      _ -> true
    end
  rescue
    ArgumentError -> false
  end

  # Create a schema with file entries and persist it
  defp seed_schema(store, uuid, entries) do
    doc = Schema.new_schema()

    doc =
      Enum.reduce(entries, doc, fn {name, type, node_id}, doc ->
        case type do
          :doc -> Schema.add_file(doc, name, node_id)
          :dir -> Schema.add_directory(doc, name, node_id)
        end
      end)

    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  # Create a text doc commit so EntryAgent has content to sync
  defp create_text_commit(store, uuid, filename, content) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, filename)

    doc =
      if content != "" do
        ContentType.insert_text(doc, 0, content)
      else
        doc
      end

    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  # Create an empty schema commit (for subdirectories)
  defp seed_empty_schema(store, uuid) do
    doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
  end

  describe "spawns EntryAgents for schema entries" do
    test "creates files on disk from schema entries after sync", %{store: store, sync_dir: dir} do
      schema_uuid = UUID.uuid4()
      file_a_uuid = UUID.uuid4()
      file_b_uuid = UUID.uuid4()

      # Create schema with 2 file entries
      seed_schema(store, schema_uuid, [
        {"hello.txt", :doc, file_a_uuid},
        {"world.txt", :doc, file_b_uuid}
      ])

      # Create CRDT docs for those files
      create_text_commit(store, file_a_uuid, "hello.txt", "hello content")
      create_text_commit(store, file_b_uuid, "world.txt", "world content")

      {:ok, pid} = DirAgent.start_link(
        schema_uuid: schema_uuid,
        dir_path: dir,
        store: store
      )

      # Sync to write CRDT content to disk
      DirAgent.sync_once(pid)

      assert File.read!(Path.join(dir, "hello.txt")) == "hello content"
      assert File.read!(Path.join(dir, "world.txt")) == "world content"

      DirAgent.stop(pid)
    end
  end

  describe "new file on disk" do
    test "adds to schema and spawns EntryAgent", %{store: store, sync_dir: dir} do
      schema_uuid = UUID.uuid4()

      # Start with empty schema
      seed_empty_schema(store, schema_uuid)

      {:ok, pid} = DirAgent.start_link(
        schema_uuid: schema_uuid,
        dir_path: dir,
        store: store
      )

      # Create a file on disk
      File.write!(Path.join(dir, "new_file.txt"), "new content")

      # Sync — should detect the new file and add to schema
      DirAgent.sync_once(pid)

      # Verify schema has the entry
      {:ok, schema_doc} = DocBuilder.reconstruct_doc(store, schema_uuid)
      entries = Schema.entries(schema_doc)
      assert Map.has_key?(entries, "new_file.txt")
      assert entries["new_file.txt"]["type"] == "doc"

      DirAgent.stop(pid)
    end
  end

  describe "file deleted from disk" do
    test "removes from schema and stops agent", %{store: store, sync_dir: dir} do
      schema_uuid = UUID.uuid4()
      file_uuid = UUID.uuid4()

      # Schema with one file
      seed_schema(store, schema_uuid, [{"doomed.txt", :doc, file_uuid}])
      create_text_commit(store, file_uuid, "doomed.txt", "soon to be deleted")

      {:ok, pid} = DirAgent.start_link(
        schema_uuid: schema_uuid,
        dir_path: dir,
        store: store
      )

      # First sync to write the file to disk
      DirAgent.sync_once(pid)
      assert File.exists?(Path.join(dir, "doomed.txt"))

      # Delete the file
      File.rm!(Path.join(dir, "doomed.txt"))

      # Sync again — should detect deletion and remove from schema
      DirAgent.sync_once(pid)

      {:ok, schema_doc} = DocBuilder.reconstruct_doc(store, schema_uuid)
      entries = Schema.entries(schema_doc)
      refute Map.has_key?(entries, "doomed.txt")

      DirAgent.stop(pid)
    end
  end

  describe "subdirectory handling" do
    test "spawns child DirAgent for dir entries", %{store: store, sync_dir: dir} do
      schema_uuid = UUID.uuid4()
      sub_uuid = UUID.uuid4()

      # Schema with a directory entry
      seed_schema(store, schema_uuid, [{"subdir", :dir, sub_uuid}])
      seed_empty_schema(store, sub_uuid)

      {:ok, pid} = DirAgent.start_link(
        schema_uuid: schema_uuid,
        dir_path: dir,
        store: store
      )

      # The subdirectory should be created on disk
      assert File.dir?(Path.join(dir, "subdir"))

      DirAgent.stop(pid)
    end
  end

  describe "sync:false entries" do
    test "skips entries with sync:false", %{store: store, sync_dir: dir} do
      schema_uuid = UUID.uuid4()
      file_uuid = UUID.uuid4()

      # Create schema, then deactivate an entry
      doc = Schema.new_schema()
      doc = Schema.add_file(doc, "skipped.txt", file_uuid)
      doc = Schema.deactivate(doc, "skipped.txt")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_commit(store, schema_uuid, update, nil)

      # Create the CRDT doc
      create_text_commit(store, file_uuid, "skipped.txt", "should not sync")

      {:ok, pid} = DirAgent.start_link(
        schema_uuid: schema_uuid,
        dir_path: dir,
        store: store
      )

      # Sync — the file should NOT be written to disk (no agent spawned)
      DirAgent.sync_once(pid)

      refute File.exists?(Path.join(dir, "skipped.txt"))

      DirAgent.stop(pid)
    end
  end

  describe "ignores .commonplace files" do
    test "does not pick up .commonplace-shadow as a new file", %{store: store, sync_dir: dir} do
      schema_uuid = UUID.uuid4()
      seed_empty_schema(store, schema_uuid)

      # Create .commonplace directories and files that should be ignored
      File.mkdir_p!(Path.join(dir, ".commonplace-shadow"))
      File.mkdir_p!(Path.join(dir, ".commonplace"))
      File.write!(Path.join(dir, ".commonplace-ref"), "ref data")

      {:ok, pid} = DirAgent.start_link(
        schema_uuid: schema_uuid,
        dir_path: dir,
        store: store
      )

      DirAgent.sync_once(pid)

      # Schema should remain empty — none of the .commonplace items should be added
      {:ok, schema_doc} = DocBuilder.reconstruct_doc(store, schema_uuid)
      entries = Schema.entries(schema_doc)
      assert entries == %{}

      DirAgent.stop(pid)
    end
  end
end
