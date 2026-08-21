defmodule Commonplace.Store.CommitReaderTest do
  @moduledoc """
  BUILD-2a's reader half: the cell-scoped read seam over CommitStore.

  Proves the four functions delegate correctly, and — the load-bearing part —
  that `at/3`'s cell scoping is ENFORCED by the authoritative `{:doc_commit}`
  index, not the commit struct's `.doc_uuid` trace, and that `inventory/3`
  reports one cell WITHOUT enumerating the workspace (acceptance §5.3).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.{Commit, CommitReader, CommitStore}
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  defp tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp start_store(dir) do
    name = :"commit_reader_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({CommitStore, data_dir: dir, name: name}, id: name))
    name
  end

  defp text_update(client_id, text) do
    doc = Doc.new(client_id: client_id)
    {doc, _type} = Doc.get_or_create_type(doc, "t", :text)
    doc = Text.insert(doc, "t", 0, text)
    Encoding.encode_update(doc)
  end

  defp seed_legacy_docs(dir, doc_count, commits_per_doc) do
    commits_dir = Path.join(dir, "commits")
    File.mkdir_p!(commits_dir)

    {:ok, db} =
      CubDB.start_link(data_dir: commits_dir, auto_file_sync: false, auto_compact: false)

    rows =
      for doc_n <- 1..doc_count, commit_n <- 1..commits_per_doc do
        commit = Commit.new("doc-#{doc_n}", "payload-#{doc_n}-#{commit_n}", nil, %{})
        {{:commit, commit.id}, commit}
      end

    :ok = CubDB.put_multi(db, rows)
    :ok = CubDB.stop(db)
  end

  test "history/heads delegate to the doc's commit log and accepted-head index" do
    store = start_store(tmp_dir("reader_hist"))
    uuid = "hist-doc"

    _c1 = CommitStore.create_commit(store, uuid, text_update(1, "one"), nil)
    latest = CommitStore.latest_commit(store, uuid)

    # history mirrors commit_log (behavior-preserving delegation). Both sides
    # carry an explicit :limit so the bound is visible at the call site
    # (CommitLogLimitCallersTest) — history forwards opts verbatim, so the
    # limit reaches commit_log unchanged.
    assert CommitReader.history(store, uuid, limit: 5) ==
             CommitStore.commit_log(store, uuid, limit: 5)

    history = CommitReader.history(store, uuid, limit: 5)
    assert is_list(history) and history != []

    # heads mirrors the durable accepted-head set
    assert CommitReader.heads(store, uuid) == CommitStore.accepted_heads_indexed(store, uuid)

    case latest do
      {:ok, commit} ->
        assert {:ok, heads} = CommitReader.heads(store, uuid)
        assert MapSet.member?(heads, commit.id)

      :none ->
        flunk("expected a latest commit")
    end
  end

  test "at/3 returns a commit only for a cell that owns it" do
    store = start_store(tmp_dir("reader_at"))
    uuid = "at-doc"

    commit = CommitStore.create_commit(store, uuid, text_update(1, "hello"), nil)

    assert {:ok, ^commit} = CommitReader.at(store, uuid, commit.id)
    # a cell that does not index this commit gets nothing — not another cell's data
    assert CommitReader.at(store, "other-cell", commit.id) == :none
  end

  test "at/3 scopes by the {:doc_commit} index KEY, not the struct's .doc_uuid trace" do
    # The World-B keeper: a commit struct's `.doc_uuid` is a debug trace of the
    # first writer, stale after forks / shared across imported ids. Ownership is
    # the index key. Construct the collision: a real commit under doc-A, then a
    # second doc-B claiming the SAME id in the index (what an imported,
    # convergent-id commit does). at(doc-B, id) must return it; at(doc-C, id)
    # (which does not index it) must not — proving the KEY governs, not the
    # struct field (which says doc-A throughout).
    store = start_store(tmp_dir("reader_at_trap"))
    commit = CommitStore.create_commit(store, "doc-A", text_update(1, "shared"), nil)
    assert commit.doc_uuid == "doc-A"

    db = CommitStore.db_handle(store)
    CubDB.put(db, {:doc_commit, "doc-B", commit.id}, true)

    # doc-B owns it per the index even though the struct names doc-A
    assert {:ok, returned} = CommitReader.at(store, "doc-B", commit.id)
    assert returned.id == commit.id
    assert returned.doc_uuid == "doc-A"

    # doc-A owns it too (it is genuinely indexed under doc-A)
    assert {:ok, _} = CommitReader.at(store, "doc-A", commit.id)

    # doc-C does not index it
    assert CommitReader.at(store, "doc-C", commit.id) == :none
  end

  test "inventory/3 reports a cell's commit ids and a frontier delta" do
    store = start_store(tmp_dir("reader_inv"))
    uuid = "inv-doc"

    c1 = CommitStore.create_commit(store, uuid, text_update(1, "a"), nil)
    all = CommitStore.all_commit_ids_for_doc(store, uuid)

    inv = CommitReader.inventory(store, uuid, MapSet.new())
    assert inv.cell_id == uuid
    assert inv.commit_ids == all
    assert inv.delta == all

    # frontier the requester already holds is subtracted from the delta
    delta = CommitReader.inventory(store, uuid, MapSet.new([c1.id])).delta
    refute MapSet.member?(delta, c1.id)
    assert MapSet.member?(all, c1.id)

    # frontier accepts a plain list too
    assert CommitReader.inventory(store, uuid, [c1.id]).delta == delta
  end

  test "inventory/3 reads only the cell's bounded range, not the whole workspace (§5.3)" do
    # Acceptance §5.3 proven by MEASUREMENT: with 200 other docs present, an
    # inventory of one cell must read only that cell's {:doc_commit} range
    # (~N+1 rows), never the whole store. Reuse the store's own read telemetry.
    dir = tmp_dir("reader_inv_bounded")
    seed_legacy_docs(dir, 200, 5)
    store = start_store(dir)

    test_pid = self()
    handler_id = {__MODULE__, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:commonplace, :commit_store, :doc_commit_index_read],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:index_read, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    inv = CommitReader.inventory(store, "doc-100", MapSet.new())

    assert MapSet.size(inv.commit_ids) == 5
    assert_receive {:index_read, %{rows_read: rows_read}, %{doc_uuid: "doc-100"}}
    # 5 commits for the cell + 1 readiness point-read == 6, NOT 1000 (the store total)
    assert rows_read == 6
  end
end
