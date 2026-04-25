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

    # CX-71ej: with the per-dir cursor, a checkpoint over an unchanged tree
    # must short-circuit — same reflog_commit_id, no new commits anywhere in
    # the reflog chain. Eliminates the ~2k writes-per-1000-dir-checkpoint that
    # were starving CommitStore (CX-0nkq).
    test "two checkpoints on an unchanged tree return the same reflog_commit_id (CX-71ej)",
         %{store: store} do
      Snapshot.clear_cursor()

      file_uuid = create_text_doc(store, "stable.txt", "no edits here")

      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      root_doc = Schema.add_file(root_doc, "stable.txt", file_uuid)
      CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(root_doc), nil)

      {:ok, cid1} = Snapshot.checkpoint(root_uuid, store)
      {:ok, cid2} = Snapshot.checkpoint(root_uuid, store)

      assert cid1 == cid2,
             "second checkpoint over unchanged tree should reuse the cursor's cached reflog_commit_id"

      # The snapshot doc's chain should be just genesis + one checkpoint write
      # — the second call must not have appended a new commit.
      {:ok, owner_uuid} = Snapshot.ensure_reflog_branch(root_uuid, "server", store)
      owner_schema = load_schema(owner_uuid, store)
      {:ok, snap_entry} = Schema.get_entry(owner_schema, "__snapshot")

      log = CommitStore.commit_log(store, snap_entry.node_id)

      assert length(log) == 2,
             "snapshot chain should be genesis + 1 checkpoint, got #{length(log)}"
    end

    # CX-71ej: change in a leaf bubbles up — only the path from root to that
    # file should produce new reflog commits. Sibling subtrees stay cached.
    test "modifying one file only writes new reflogs along its path (CX-71ej)",
         %{store: store} do
      Snapshot.clear_cursor()

      changed_file = create_text_doc(store, "changed.txt", "v1")
      stable_file = create_text_doc(store, "stable.txt", "fixed")

      sub_a_uuid = UUID.uuid4()
      sub_a = Schema.new_schema()
      sub_a = Schema.add_file(sub_a, "changed.txt", changed_file)
      CommitStore.create_commit(store, sub_a_uuid, Yelixer.Encoding.encode_update(sub_a), nil)

      sub_b_uuid = UUID.uuid4()
      sub_b = Schema.new_schema()
      sub_b = Schema.add_file(sub_b, "stable.txt", stable_file)
      CommitStore.create_commit(store, sub_b_uuid, Yelixer.Encoding.encode_update(sub_b), nil)

      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      root_doc = Schema.add_directory(root_doc, "sub_a", sub_a_uuid)
      root_doc = Schema.add_directory(root_doc, "sub_b", sub_b_uuid)
      CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(root_doc), nil)

      {:ok, _cid1} = Snapshot.checkpoint(root_uuid, store)

      # Capture sub_b's reflog snapshot commit_id BEFORE the second checkpoint
      {:ok, owner_uuid} = Snapshot.ensure_reflog_branch(root_uuid, "server", store)
      owner_schema = load_schema(owner_uuid, store)
      {:ok, sub_b_reflog_dir} = Schema.get_entry(owner_schema, "sub_b")
      sub_b_reflog_schema_before = load_schema(sub_b_reflog_dir.node_id, store)
      {:ok, sub_b_snap_entry_before} = Schema.get_entry(sub_b_reflog_schema_before, "__snapshot")

      {:ok, sub_b_snap_before} =
        CommitStore.latest_commit(store, sub_b_snap_entry_before.node_id)

      # Modify the file in sub_a only
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "changed.txt")
      doc = ContentType.insert_text(doc, 0, "v2")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_chained_commit(store, changed_file, update)

      {:ok, _cid2} = Snapshot.checkpoint(root_uuid, store)

      # sub_b's snapshot doc latest must be unchanged — no new commit was written
      {:ok, sub_b_snap_after} =
        CommitStore.latest_commit(store, sub_b_snap_entry_before.node_id)

      assert sub_b_snap_before.id == sub_b_snap_after.id,
             "sub_b's reflog snapshot should NOT have advanced when only sub_a's file changed"
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
