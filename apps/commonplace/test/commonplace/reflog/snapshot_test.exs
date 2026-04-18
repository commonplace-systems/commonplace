defmodule Commonplace.Reflog.SnapshotTest do
  use ExUnit.Case

  alias Commonplace.Reflog.Snapshot
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_reflog_snapshot_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"commit_store_reflog_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name}
  end

  describe "ensure_reflog_branch/3" do
    test "creates __reflog/server/ structure", %{store: store} do
      root_uuid = create_root_schema(store)

      {:ok, owner_uuid} = Snapshot.ensure_reflog_branch(root_uuid, "server", store)

      # Root should now have __reflog entry
      {:ok, root_commit} = CommitStore.latest_commit(store, root_uuid)
      {:ok, root_schema} = Yelixer.Encoding.apply_update(Schema.new_schema(), root_commit.update)
      {:ok, reflog_entry} = Schema.get_entry(root_schema, "__reflog")
      assert reflog_entry.type == :dir

      # __reflog should have "server" entry
      {:ok, reflog_commit} = CommitStore.latest_commit(store, reflog_entry.node_id)
      {:ok, reflog_schema} = Yelixer.Encoding.apply_update(Schema.new_schema(), reflog_commit.update)
      {:ok, server_entry} = Schema.get_entry(reflog_schema, "server")
      assert server_entry.type == :dir
      assert server_entry.node_id == owner_uuid
    end

    test "is idempotent", %{store: store} do
      root_uuid = create_root_schema(store)

      {:ok, uuid1} = Snapshot.ensure_reflog_branch(root_uuid, "server", store)
      {:ok, uuid2} = Snapshot.ensure_reflog_branch(root_uuid, "server", store)

      assert uuid1 == uuid2
    end
  end

  describe "checkpoint/3" do
    test "records commit_ids for two files", %{store: store} do
      file1_uuid = create_text_doc(store, "file1.txt", "hello")
      file2_uuid = create_text_doc(store, "file2.txt", "world")

      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      root_doc = Schema.add_file(root_doc, "file1.txt", file1_uuid)
      root_doc = Schema.add_file(root_doc, "file2.txt", file2_uuid)
      CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(root_doc), nil)

      {:ok, reflog_cid} = Snapshot.checkpoint(root_uuid, store)

      assert is_binary(reflog_cid)

      # Find the snapshot doc to read it
      {:ok, owner_uuid} = Snapshot.ensure_reflog_branch(root_uuid, "server", store)
      owner_schema = load_schema(owner_uuid, store)
      {:ok, snap_entry} = Schema.get_entry(owner_schema, "__snapshot")

      content = Snapshot.read_snapshot(snap_entry.node_id, store)
      assert is_map(content)

      # Both files should be recorded
      {:ok, f1_commit} = CommitStore.latest_commit(store, file1_uuid)
      {:ok, f2_commit} = CommitStore.latest_commit(store, file2_uuid)

      assert content["file1.txt"] == Base.encode16(f1_commit.id, case: :lower)
      assert content["file2.txt"] == Base.encode16(f2_commit.id, case: :lower)
    end

    test "records recursive reflog for subdirectory", %{store: store} do
      inner_file = create_text_doc(store, "inner.txt", "nested content")

      inner_uuid = UUID.uuid4()
      inner_doc = Schema.new_schema()
      inner_doc = Schema.add_file(inner_doc, "inner.txt", inner_file)
      CommitStore.create_commit(store, inner_uuid, Yelixer.Encoding.encode_update(inner_doc), nil)

      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      root_doc = Schema.add_directory(root_doc, "subdir", inner_uuid)
      CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(root_doc), nil)

      {:ok, _reflog_cid} = Snapshot.checkpoint(root_uuid, store)

      # Read root snapshot — subdir should have a reflog commit_id
      {:ok, owner_uuid} = Snapshot.ensure_reflog_branch(root_uuid, "server", store)
      owner_schema = load_schema(owner_uuid, store)
      {:ok, snap_entry} = Schema.get_entry(owner_schema, "__snapshot")

      content = Snapshot.read_snapshot(snap_entry.node_id, store)
      assert is_map(content)
      assert Map.has_key?(content, "subdir")

      # The subdir value should be a valid hex commit_id
      subdir_cid_hex = content["subdir"]
      assert is_binary(subdir_cid_hex)
      assert String.length(subdir_cid_hex) > 0

      # The child reflog dir should also have a __snapshot with inner.txt
      {:ok, subdir_reflog_entry} = Schema.get_entry(owner_schema, "subdir")
      child_reflog_schema = load_schema(subdir_reflog_entry.node_id, store)
      {:ok, child_snap_entry} = Schema.get_entry(child_reflog_schema, "__snapshot")

      child_content = Snapshot.read_snapshot(child_snap_entry.node_id, store)
      assert is_map(child_content)

      {:ok, inner_commit} = CommitStore.latest_commit(store, inner_file)
      assert child_content["inner.txt"] == Base.encode16(inner_commit.id, case: :lower)
    end

    test "records __schema_cid for directory verification", %{store: store} do
      file_uuid = create_text_doc(store, "test.txt", "data")

      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      root_doc = Schema.add_file(root_doc, "test.txt", file_uuid)
      CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(root_doc), nil)

      {:ok, _reflog_cid} = Snapshot.checkpoint(root_uuid, store)

      {:ok, owner_uuid} = Snapshot.ensure_reflog_branch(root_uuid, "server", store)
      owner_schema = load_schema(owner_uuid, store)
      {:ok, snap_entry} = Schema.get_entry(owner_schema, "__snapshot")

      content = Snapshot.read_snapshot(snap_entry.node_id, store)

      # __schema_cid should be present and match root's commit
      assert Map.has_key?(content, "__schema_cid")
      {:ok, root_commit} = CommitStore.latest_commit(store, root_uuid)
      assert content["__schema_cid"] == Base.encode16(root_commit.id, case: :lower)
    end

    test "two checkpoints create a chain with different commit_ids", %{store: store} do
      file_uuid = create_text_doc(store, "test.txt", "version 1")

      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      root_doc = Schema.add_file(root_doc, "test.txt", file_uuid)
      CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(root_doc), nil)

      {:ok, cid1} = Snapshot.checkpoint(root_uuid, store)

      # Modify the file
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "test.txt")
      doc = ContentType.insert_text(doc, 0, "version 2")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_chained_commit(store, file_uuid, update)

      {:ok, cid2} = Snapshot.checkpoint(root_uuid, store)

      assert cid1 != cid2

      # Both should be valid binary commit ids
      assert is_binary(cid1)
      assert is_binary(cid2)

      # The snapshot doc should have a chain of 2 commits
      {:ok, owner_uuid} = Snapshot.ensure_reflog_branch(root_uuid, "server", store)
      owner_schema = load_schema(owner_uuid, store)
      {:ok, snap_entry} = Schema.get_entry(owner_schema, "__snapshot")

      log = CommitStore.commit_log(store, snap_entry.node_id)
      # Post-CX-m3x: fresh docs get a deterministic genesis as their first
      # commit, so the snapshot's commit chain is genesis + two checkpoints.
      assert length(log) == 3
    end
  end

  # --- Helpers ---

  defp create_text_doc(store, name, content) do
    uuid = UUID.uuid4()
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, name)
    doc = if content != "", do: ContentType.insert_text(doc, 0, content), else: doc
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
    uuid
  end

  defp create_root_schema(store) do
    uuid = UUID.uuid4()
    doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_commit(store, uuid, update, nil)
    uuid
  end

  defp load_schema(uuid, store) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        {:ok, doc} = Yelixer.Encoding.apply_update(Schema.new_schema(), commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end
end
