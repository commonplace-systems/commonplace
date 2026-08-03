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

    # CX-o8tx: the CX-71ej cursor short-circuits the WRITES on an unchanged
    # subtree but still READS every file/dir's latest_commit to detect
    # change. Amortization: when a subtree is known-clean (no commits since
    # last checkpoint via the dirty-set fed by telemetry), skip reads
    # entirely and return the cached reflog_commit_id.
    test "fast-path: clean subtree skips reads after warming (CX-o8tx)",
         %{store: store} do
      Snapshot.clear_cursor()
      Snapshot.clear_amortization_state()

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

      # Warm checkpoint — populates cursor + parent_index + clears any
      # dirty bits accumulated during the setup commits.
      {:ok, _cid1} = Snapshot.checkpoint(root_uuid, store)
      Snapshot.clear_dirty_set()

      ref = :erlang.unique_integer([:positive])
      parent = self()

      :ok =
        :telemetry.attach(
          {:cx_o8tx_test, ref},
          [:commonplace, :commit, :latest_read],
          fn _e, _m, %{doc_uuid: uuid}, _c -> send(parent, {:read, uuid}) end,
          nil
        )

      try do
        # Modify changed_file. CommitStore broadcasts :commit, :create →
        # the application-level dirty-tracker handler calls Snapshot.mark_dirty,
        # which (via parent_index) marks sub_a and root as dirty. sub_b stays
        # clean — its data_dir has nothing under the changed_file's parent
        # chain.
        doc = Yelixer.Doc.new()
        doc = ContentType.create(doc, :text, "changed.txt")
        doc = ContentType.insert_text(doc, 0, "v2")
        update = Yelixer.Encoding.encode_update(doc)
        CommitStore.create_chained_commit(store, changed_file, update)

        # Drain reads from create_chained_commit — we only care about
        # what the second checkpoint reads.
        flush_reads()

        {:ok, _cid2} = Snapshot.checkpoint(root_uuid, store)

        reads = collect_reads()

        refute sub_b_uuid in reads,
               "sub_b's data dir was read during the second checkpoint — amortization fast-path failed"

        refute stable_file in reads,
               "stable.txt was read during the second checkpoint — amortization fast-path failed"

        assert sub_a_uuid in reads or changed_file in reads,
               "expected at least one read on sub_a's subtree, got reads=#{inspect(reads)}"
      after
        :telemetry.detach({:cx_o8tx_test, ref})
      end
    end

    # CX-o8tx cold-start safety: with empty cursor / empty parent_index,
    # the very first checkpoint must walk the whole tree (no fast-path
    # skips), populating the index so subsequent checkpoints can amortize.
    test "cold start with empty amortization state walks the whole tree (CX-o8tx)",
         %{store: store} do
      Snapshot.clear_cursor()
      Snapshot.clear_amortization_state()

      file1 = create_text_doc(store, "a.txt", "a")
      file2 = create_text_doc(store, "b.txt", "b")

      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      root_doc = Schema.add_file(root_doc, "a.txt", file1)
      root_doc = Schema.add_file(root_doc, "b.txt", file2)
      CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(root_doc), nil)

      {:ok, _cid} = Snapshot.checkpoint(root_uuid, store)

      # The root snapshot doc must record both files' commit_ids — i.e.
      # the cold-start walk did NOT skip them just because dirty bits
      # were absent.
      {:ok, owner_uuid} = Snapshot.ensure_reflog_branch(root_uuid, "server", store)
      owner_schema = load_schema(owner_uuid, store)
      {:ok, snap_entry} = Schema.get_entry(owner_schema, "__snapshot")

      content = Snapshot.read_snapshot(snap_entry.node_id, store)
      assert is_map(content)
      assert Map.has_key?(content, "a.txt")
      assert Map.has_key?(content, "b.txt")
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

  describe "writer identity — stable per-doc hand (CX-41qg.3)" do
    # Checkpoints fire on every sync tick (Sync.Agent) plus periodically
    # (CheckpointTimer). Before this fix, `build_reflog_doc/2` rebuilt
    # the `__snapshot` doc from scratch via a bare `Doc.new()` on every
    # non-idempotent round (a cursor miss), minting a fresh random
    # client_id each time — so the snapshot doc's state vector bloated
    # one slot PER CHECKPOINT ROUND. The fix pins it to
    # `WriterHand.for_doc(snapshot_uuid)`.
    defp sv_client_ids(doc) do
      Yelixer.BlockStore.state_vector(doc.store).clocks
      |> Map.keys()
      |> MapSet.new()
    end

    test "15 checkpoints over a repeatedly-changing file keep the snapshot doc's client-id set bounded",
         %{store: store} do
      Snapshot.clear_cursor()

      file_uuid = create_text_doc(store, "test.txt", "version 0")

      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      root_doc = Schema.add_file(root_doc, "test.txt", file_uuid)
      CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(root_doc), nil)

      Enum.each(1..15, fn n ->
        doc = Yelixer.Doc.new()
        doc = ContentType.create(doc, :text, "test.txt")
        doc = ContentType.insert_text(doc, 0, "version #{n}")
        update = Yelixer.Encoding.encode_update(doc)
        CommitStore.create_chained_commit(store, file_uuid, update)

        assert {:ok, _cid} = Snapshot.checkpoint(root_uuid, store)
      end)

      {:ok, owner_uuid} = Snapshot.ensure_reflog_branch(root_uuid, "server", store)
      owner_schema = load_schema(owner_uuid, store)
      {:ok, snap_entry} = Schema.get_entry(owner_schema, "__snapshot")

      {:ok, snap_doc} = Commonplace.Tree.DocBuilder.reconstruct_doc(store, snap_entry.node_id)
      client_ids = sv_client_ids(snap_doc)

      assert MapSet.size(client_ids) <= 2,
             "expected a bounded (<=2) set of client ids after 15 checkpoint rounds, " <>
               "got #{MapSet.size(client_ids)}: #{inspect(client_ids)}"
    end
  end

  describe "node-signed checkpoints (CX-0t2r SIGNING)" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "cp_reflog_signing_test_#{:rand.uniform(1_000_000)}")

      File.mkdir_p!(dir)
      prior_data_dir = Application.get_env(:commonplace, :data_dir)
      Application.put_env(:commonplace, :data_dir, dir)

      on_exit(fn ->
        Application.put_env(:commonplace, :data_dir, prior_data_dir || "tmp/test_data")
        File.rm_rf!(dir)
      end)

      :ok
    end

    test "checkpoint commits carry the node identity's signer_id", %{store: store} do
      {:ok, node_identity} = Commonplace.Crypto.NodeIdentity.identity()
      {:ok, node_pub} = Commonplace.Crypto.NodeIdentity.public_key()
      expected_signer_id = Commonplace.Crypto.Signing.signer_id(node_identity, node_pub)

      file_uuid = create_text_doc(store, "signed.txt", "hi")

      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      root_doc = Schema.add_file(root_doc, "signed.txt", file_uuid)
      CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(root_doc), nil)

      {:ok, _reflog_cid} = Snapshot.checkpoint(root_uuid, store)

      {:ok, owner_uuid} = Snapshot.ensure_reflog_branch(root_uuid, "server", store)
      owner_schema = load_schema(owner_uuid, store)
      {:ok, snap_entry} = Schema.get_entry(owner_schema, "__snapshot")

      {:ok, commit} = CommitStore.latest_commit(store, snap_entry.node_id)

      assert commit.signer_id == expected_signer_id,
             "expected the __snapshot doc's latest commit to be node-signed"

      assert commit.signature != nil
    end
  end

  describe "presence exclusion (CX-0t2r EXCLUSION, CX-dm54 precedent)" do
    test "a .usr entry is not recorded in the snapshot map", %{store: store} do
      Snapshot.clear_cursor()
      Snapshot.clear_amortization_state()

      file_uuid = create_text_doc(store, "foo.txt", "hello")
      usr_uuid = create_text_doc(store, "bob.usr", "presence-blob")

      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      root_doc = Schema.add_file(root_doc, "foo.txt", file_uuid)
      root_doc = Schema.add_file(root_doc, "bob.usr", usr_uuid)
      CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(root_doc), nil)

      {:ok, _reflog_cid} = Snapshot.checkpoint(root_uuid, store)

      {:ok, owner_uuid} = Snapshot.ensure_reflog_branch(root_uuid, "server", store)
      owner_schema = load_schema(owner_uuid, store)
      {:ok, snap_entry} = Schema.get_entry(owner_schema, "__snapshot")

      content = Snapshot.read_snapshot(snap_entry.node_id, store)

      assert Map.has_key?(content, "foo.txt")
      refute Map.has_key?(content, "bob.usr")
    end

    test "a subsequent .usr-only change produces no new reflog commit (cursor skip)",
         %{store: store} do
      Snapshot.clear_cursor()
      Snapshot.clear_amortization_state()

      file_uuid = create_text_doc(store, "foo.txt", "hello")
      usr_uuid = create_text_doc(store, "bob.usr", "presence-blob-v1")

      root_uuid = UUID.uuid4()
      root_doc = Schema.new_schema()
      root_doc = Schema.add_file(root_doc, "foo.txt", file_uuid)
      root_doc = Schema.add_file(root_doc, "bob.usr", usr_uuid)
      CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(root_doc), nil)

      {:ok, cid1} = Snapshot.checkpoint(root_uuid, store)

      {:ok, owner_uuid} = Snapshot.ensure_reflog_branch(root_uuid, "server", store)
      owner_schema = load_schema(owner_uuid, store)
      {:ok, snap_entry} = Schema.get_entry(owner_schema, "__snapshot")
      log_before = CommitStore.commit_log(store, snap_entry.node_id)

      # Heartbeat churn: rewrite the .usr doc only. This fires the dirty
      # telemetry handler on bob.usr's uuid, but bob.usr was never
      # registered in root_uuid's parent_index (it's excluded from
      # `entries` before `populate_parent_index/2` runs), so propagation
      # stops there and root_uuid is never (re-)marked dirty.
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "bob.usr")
      doc = ContentType.insert_text(doc, 0, "presence-blob-v2")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_chained_commit(store, usr_uuid, update)

      {:ok, cid2} = Snapshot.checkpoint(root_uuid, store)

      assert cid1 == cid2,
             "a .usr-only change should cursor-skip to the same reflog_commit_id"

      log_after = CommitStore.commit_log(store, snap_entry.node_id)

      assert length(log_after) == length(log_before),
             "a .usr-only change should not have appended a new reflog commit"
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

  defp flush_reads do
    receive do
      {:read, _} -> flush_reads()
    after
      0 -> :ok
    end
  end

  defp collect_reads(acc \\ []) do
    receive do
      {:read, uuid} -> collect_reads([uuid | acc])
    after
      0 -> acc
    end
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
