defmodule Commonplace.Sync.EntryAgentTest do
  @moduledoc """
  Tests for the per-file bidirectional sync agent.

  EntryAgent handles one file: reading disk changes into CRDT commits
  and writing CRDT changes to disk.
  """
  use ExUnit.Case

  alias Commonplace.Sync.EntryAgent
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore

  setup do
    store_dir = Path.join(System.tmp_dir!(), "cp_entry_store_#{:rand.uniform(1_000_000)}")
    sync_dir = Path.join(System.tmp_dir!(), "cp_entry_sync_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(store_dir)
    File.mkdir_p!(sync_dir)

    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: store_dir, name: store_name})

    on_exit(fn ->
      File.rm_rf!(store_dir)
      File.rm_rf!(sync_dir)
    end)

    %{store: store_name, sync_dir: sync_dir}
  end

  defp read_doc_content(store, uuid) do
    {:ok, commit} = CommitStore.latest_commit(store, uuid)
    doc = Yelixer.Doc.new()
    {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
    ContentType.get_content(doc)
  end

  defp create_text_commit(store, uuid, content) do
    doc = Yelixer.Doc.new()
    doc = ContentType.create(doc, :text, "file.txt")
    doc = ContentType.insert_text(doc, 0, content)
    update = Yelixer.Encoding.encode_update(doc)
    CommitStore.create_chained_commit(store, uuid, update)
  end

  describe "inbound sync (CRDT → disk)" do
    test "writes file when CRDT has content", %{store: store, sync_dir: dir} do
      doc_uuid = UUID.uuid4()
      file_path = Path.join(dir, "hello.txt")

      create_text_commit(store, doc_uuid, "hello from CRDT")

      {:ok, pid} =
        EntryAgent.start_link(
          doc_uuid: doc_uuid,
          file_path: file_path,
          store: store
        )

      EntryAgent.sync_once(pid)

      assert File.read!(file_path) == "hello from CRDT"

      EntryAgent.stop(pid)
    end

    test "file creation on first inbound sync (no file on disk)", %{store: store, sync_dir: dir} do
      doc_uuid = UUID.uuid4()
      file_path = Path.join(dir, "new_file.txt")

      # No file on disk yet
      refute File.exists?(file_path)

      create_text_commit(store, doc_uuid, "created by CRDT")

      {:ok, pid} =
        EntryAgent.start_link(
          doc_uuid: doc_uuid,
          file_path: file_path,
          store: store
        )

      EntryAgent.sync_once(pid)

      # File should now exist with the CRDT content
      assert File.exists?(file_path)
      assert File.read!(file_path) == "created by CRDT"

      EntryAgent.stop(pid)
    end

    test "skips write when content hash matches", %{store: store, sync_dir: dir} do
      doc_uuid = UUID.uuid4()
      file_path = Path.join(dir, "stable.txt")

      create_text_commit(store, doc_uuid, "stable content")

      {:ok, pid} =
        EntryAgent.start_link(
          doc_uuid: doc_uuid,
          file_path: file_path,
          store: store
        )

      # First sync writes the file
      EntryAgent.sync_once(pid)
      assert File.read!(file_path) == "stable content"

      # Record file mtime to verify it doesn't get rewritten
      stat_before = File.stat!(file_path)

      # Create a new commit with the same text content.
      # This simulates a metadata-only change — the content itself is identical.
      # We need to create a doc with the exact same text to get the same hash.
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "stable.txt")
      doc = ContentType.insert_text(doc, 0, "stable content")
      update = Yelixer.Encoding.encode_update(doc)
      CommitStore.create_chained_commit(store, doc_uuid, update)

      # Wait a bit so mtime would differ if a write occurred
      Process.sleep(1100)

      EntryAgent.sync_once(pid)

      # File should still have the same content
      assert File.read!(file_path) == "stable content"

      # File should NOT have been rewritten (mtime unchanged)
      stat_after = File.stat!(file_path)
      assert stat_before.mtime == stat_after.mtime

      EntryAgent.stop(pid)
    end
  end

  describe "CX-dvtj: inbound-clobber guard (ports CX-60wl)" do
    test "unreconciled disk edit is not clobbered by inbound; converges next cycle",
         %{store: store, sync_dir: dir} do
      doc_uuid = UUID.uuid4()
      file_path = Path.join(dir, "guarded.txt")

      create_text_commit(store, doc_uuid, "v1")

      {:ok, pid} =
        EntryAgent.start_link(
          doc_uuid: doc_uuid,
          file_path: file_path,
          store: store
        )

      EntryAgent.sync_once(pid)
      assert File.read!(file_path) == "v1"

      state = :sys.get_state(pid)

      # Simulate the race the guard closes: a local edit lands on disk
      # (e.g. mid-cycle, after outbound last looked) while, separately, the
      # CRDT advances (e.g. a remote peer's commit) — WITHOUT outbound
      # having folded the local edit into a commit yet.
      File.write!(file_path, "local edit")
      create_text_commit(store, doc_uuid, "remote v2")

      # Exercise sync_inbound directly against the pre-race state, the way
      # agent_test.exs exercises the legacy guard's invariants.
      guarded_state = EntryAgent.sync_inbound(state)

      # The unreconciled local edit must survive — inbound must not
      # clobber it with the remote CRDT content.
      assert File.read!(file_path) == "local edit"

      # Left unreconciled (state untouched) so a subsequent cycle retries.
      assert guarded_state == state

      # A full sync cycle then converges: outbound picks up the local
      # edit (disk hash differs from known_hash) and commits it; the CRDT
      # catches up to hold the local edit.
      EntryAgent.sync_once(pid)
      assert read_doc_content(store, doc_uuid) == "local edit"
      assert File.read!(file_path) == "local edit"

      EntryAgent.stop(pid)
    end

    test "disk matching CRDT content is recorded as reconciled without rewriting",
         %{store: store, sync_dir: dir} do
      doc_uuid = UUID.uuid4()
      file_path = Path.join(dir, "matching.txt")

      create_text_commit(store, doc_uuid, "v1")

      {:ok, pid} =
        EntryAgent.start_link(
          doc_uuid: doc_uuid,
          file_path: file_path,
          store: store
        )

      EntryAgent.sync_once(pid)
      state = :sys.get_state(pid)

      # A new commit lands whose content happens to already match disk
      # (e.g. another writer wrote the same bytes independently).
      create_text_commit(store, doc_uuid, "v1")
      stat_before = File.stat!(file_path)
      Process.sleep(1100)

      new_state = EntryAgent.sync_inbound(state)

      assert File.stat!(file_path).mtime == stat_before.mtime

      assert new_state.known_hash ==
               Base.encode16(:crypto.hash(:sha256, "v1"), case: :lower)

      refute new_state.last_written_commit_id == state.last_written_commit_id

      EntryAgent.stop(pid)
    end
  end

  describe "outbound sync (disk → CRDT)" do
    test "creates commit when file changes", %{store: store, sync_dir: dir} do
      doc_uuid = UUID.uuid4()
      file_path = Path.join(dir, "editable.txt")

      # First: create CRDT content, sync to disk
      create_text_commit(store, doc_uuid, "original")

      {:ok, pid} =
        EntryAgent.start_link(
          doc_uuid: doc_uuid,
          file_path: file_path,
          store: store
        )

      EntryAgent.sync_once(pid)
      assert File.read!(file_path) == "original"

      # Now modify the file on disk
      File.write!(file_path, "modified on disk")

      EntryAgent.sync_once(pid)

      # The CRDT should now have the updated content
      assert read_doc_content(store, doc_uuid) == "modified on disk"

      EntryAgent.stop(pid)
    end

    test "creates commit for new file on disk (no prior CRDT)", %{store: store, sync_dir: dir} do
      doc_uuid = UUID.uuid4()
      file_path = Path.join(dir, "brand_new.txt")

      # Write the file to disk first (no CRDT content yet)
      File.write!(file_path, "brand new file")

      {:ok, pid} =
        EntryAgent.start_link(
          doc_uuid: doc_uuid,
          file_path: file_path,
          store: store
        )

      EntryAgent.sync_once(pid)

      # A commit should now exist
      assert {:ok, _commit} = CommitStore.latest_commit(store, doc_uuid)
      assert read_doc_content(store, doc_uuid) == "brand new file"

      EntryAgent.stop(pid)
    end
  end

  describe "idempotence" do
    test "no-op when nothing changed", %{store: store, sync_dir: dir} do
      doc_uuid = UUID.uuid4()
      file_path = Path.join(dir, "idempotent.txt")

      create_text_commit(store, doc_uuid, "immutable content")

      {:ok, pid} =
        EntryAgent.start_link(
          doc_uuid: doc_uuid,
          file_path: file_path,
          store: store
        )

      # First sync
      EntryAgent.sync_once(pid)
      assert File.read!(file_path) == "immutable content"

      # Count commits after first sync
      log_after_first = CommitStore.commit_log(store, doc_uuid)
      count_after_first = length(log_after_first)

      # Second sync — nothing changed on disk or CRDT
      EntryAgent.sync_once(pid)

      # Third sync
      EntryAgent.sync_once(pid)

      # No new commits should have been created
      log_after_third = CommitStore.commit_log(store, doc_uuid)
      assert length(log_after_third) == count_after_first

      EntryAgent.stop(pid)
    end
  end

  describe "bidirectional" do
    test "alternating disk and CRDT edits both sync", %{store: store, sync_dir: dir} do
      doc_uuid = UUID.uuid4()
      file_path = Path.join(dir, "bidir.txt")

      # Start with CRDT content
      create_text_commit(store, doc_uuid, "version 1")

      {:ok, pid} =
        EntryAgent.start_link(
          doc_uuid: doc_uuid,
          file_path: file_path,
          store: store
        )

      EntryAgent.sync_once(pid)
      assert File.read!(file_path) == "version 1"

      # Edit on disk
      File.write!(file_path, "version 2 from disk")
      EntryAgent.sync_once(pid)
      assert read_doc_content(store, doc_uuid) == "version 2 from disk"

      # Edit in CRDT
      create_text_commit(store, doc_uuid, "version 3 from CRDT")
      EntryAgent.sync_once(pid)
      assert File.read!(file_path) == "version 3 from CRDT"

      EntryAgent.stop(pid)
    end
  end

  describe "producer-side snapshot hook (CX-tvyb)" do
    test "writer-local snapshot fires after threshold regular commits",
         %{store: store, sync_dir: dir} do
      doc_uuid = UUID.uuid4()
      file_path = Path.join(dir, "producer_snap.txt")

      {:ok, agent} =
        EntryAgent.start_link(
          doc_uuid: doc_uuid,
          file_path: file_path,
          store: store,
          snapshot_chain_threshold: 3
        )

      # Four disk writes across four sync cycles. Chain length after
      # each regular commit: 1, 2, 3, 4. At length 3, the producer hook
      # cuts a snapshot (chain_length resets to 0), and the fourth
      # write chains a single regular commit on top of the snapshot.
      for content <- ["a", "ab", "abc", "abcd"] do
        File.write!(file_path, content)
        EntryAgent.sync_once(agent)
      end

      snapshot_commits =
        store
        |> CommitStore.all_commit_ids_for_doc(doc_uuid)
        |> MapSet.to_list()
        |> Enum.map(fn id ->
          {:ok, commit} = CommitStore.get_commit(store, id)
          commit
        end)
        |> Enum.filter(fn c -> c.metadata[:kind] == :snapshot end)
        # Genesis for fresh docs is stamped kind :genesis not :snapshot,
        # so anything that clears this filter is a producer-cut snapshot.
        |> Enum.reject(fn c -> c.metadata[:kind] == :genesis end)

      refute Enum.empty?(snapshot_commits),
             "expected a producer-side snapshot after crossing threshold=3"

      EntryAgent.stop(agent)
    end
  end

  describe "lifecycle" do
    test "stop/1 shuts down gracefully", %{store: store, sync_dir: dir} do
      doc_uuid = UUID.uuid4()
      file_path = Path.join(dir, "lifecycle.txt")

      {:ok, pid} =
        EntryAgent.start_link(
          doc_uuid: doc_uuid,
          file_path: file_path,
          store: store
        )

      assert Process.alive?(pid)
      EntryAgent.stop(pid)
      refute Process.alive?(pid)
    end
  end
end
