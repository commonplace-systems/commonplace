defmodule Commonplace.Store.DocCommitIndexTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Commonplace.SiblingMerger
  alias Commonplace.Store.{Commit, CommitStore}
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  @index_state_key {:doc_commit_index, :state}

  defp tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp start_store(dir) do
    name = :"doc_commit_index_#{System.unique_integer([:positive])}"

    start_supervised!(Supervisor.child_spec({CommitStore, data_dir: dir, name: name}, id: name))

    name
  end

  defp text_update(client_id, text) do
    doc = Doc.new(client_id: client_id)
    {doc, _type} = Doc.get_or_create_type(doc, "t", :text)
    doc = Text.insert(doc, "t", 0, text)
    Encoding.encode_update(doc)
  end

  defp seed_legacy_store(dir, doc_count, commits_per_doc) do
    commits_dir = Path.join(dir, "commits")
    File.mkdir_p!(commits_dir)

    {:ok, db} =
      CubDB.start_link(data_dir: commits_dir, auto_file_sync: false, auto_compact: false)

    rows =
      for doc_n <- 1..doc_count,
          commit_n <- 1..commits_per_doc do
        uuid = "doc-#{doc_n}"
        commit = Commit.new(uuid, "payload-#{doc_n}-#{commit_n}", nil, %{})
        {{:commit, commit.id}, commit}
      end

    :ok = CubDB.put_multi(db, rows)
    :ok = CubDB.stop(db)
    rows
  end

  test "commit row construction is centralized in the row-pair choke" do
    source_path =
      System.get_env("CP_COMMIT_STORE_SOURCE_PATH") ||
        Path.expand("../../../lib/commonplace/store/commit_store.ex", __DIR__)

    source = File.read!(source_path)

    # This is intentionally a source-shape test, like invariant_choke_test:
    # the guarantee is structural. There are exactly two commit tuple forms:
    # the constructor in commit_rows/1 and the read pattern in the startup
    # backfill. Another writer-side tuple would make a commit row possible
    # without its index row and must fail review mechanically.
    assert length(Regex.scan(~r/\{\{:commit,/, source)) == 2

    assert source =~
             "[{{:commit, id}, commit}, {{:doc_commit, doc_uuid, id}, true}]"
  end

  test "one-doc lookup reads only that doc's bounded index range" do
    dir = tmp_dir("doc_commit_cost")
    _rows = seed_legacy_store(dir, 500, 10)
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

    db = CommitStore.db_handle(store)

    old_range_rows =
      CubDB.select(db,
        min_key: {:commit, ""},
        max_key: {:commit, :binary.copy(<<255>>, 64)}
      )
      |> Enum.count()

    ids = CommitStore.all_commit_ids_for_doc(store, "doc-250")

    IO.puts(
      "CX-3an0 current one-doc read: store_commits=5000 store_docs=500 " <>
        "target_commits=10 rows_read=#{old_range_rows}"
    )

    assert_receive {:index_read, %{rows_read: rows_read}, %{doc_uuid: "doc-250"}}

    IO.puts(
      "CX-3an0 one-doc read: store_commits=5000 store_docs=500 target_commits=10 " <>
        "before_rows_read=#{old_range_rows} after_rows_read=#{rows_read}"
    )

    assert MapSet.size(ids) == 10
    assert old_range_rows == 5_000
    assert rows_read == 11
  end

  test "sibling imported outside put_latest remains discoverable by SiblingMerger" do
    dir = tmp_dir("doc_commit_sibling")
    store = start_store(dir)
    uuid = "sibling-doc"

    local = CommitStore.create_commit(store, uuid, text_update(1, "local"), nil)
    sibling = Commit.new(uuid, text_update(2, "remote"), local.parent_id, %{})

    :ok = CommitStore.import_commit(store, sibling, validator: fn _ -> :ok end)

    assert {:error, {:siblings_unmergeable, [{sibling_id, :no_common_ancestor}]}} =
             SiblingMerger.maybe_merge_siblings(store, uuid)

    assert sibling_id == sibling.id
  end

  test "piggybacked genesis and advancing commit are both indexed from written rows" do
    dir = tmp_dir("doc_commit_genesis")
    store = start_store(dir)
    uuid = "piggyback-doc"

    commit = CommitStore.create_commit(store, uuid, text_update(1, "first"), nil)
    genesis = Commit.genesis(uuid)
    db = CommitStore.db_handle(store)

    assert CubDB.get(db, {:doc_commit, uuid, genesis.id}) == true
    assert CubDB.get(db, {:doc_commit, uuid, commit.id}) == true
    assert CommitStore.all_commit_ids_for_doc(store, uuid) == MapSet.new([genesis.id, commit.id])
  end

  test "ensure_genesis bare commit write is indexed" do
    dir = tmp_dir("doc_commit_ensure_genesis")
    store = start_store(dir)
    uuid = "bare-genesis-doc"

    assert {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)
    assert CommitStore.all_commit_ids_for_doc(store, uuid) == MapSet.new([genesis.id])
  end

  test "missing index rebuilds and a dirty marker refuses reads until restart repair" do
    dir = tmp_dir("doc_commit_repair")
    [{{:commit, commit_id}, commit}] = seed_legacy_store(dir, 1, 1)

    missing_log =
      capture_log(fn ->
        store = start_store(dir)

        assert CommitStore.all_commit_ids_for_doc(store, commit.doc_uuid) ==
                 MapSet.new([commit_id])

        assert CubDB.get(CommitStore.db_handle(store), @index_state_key) == {:ready, 1}
      end)

    assert missing_log =~ "doc commit index"
    assert missing_log =~ "missing"

    dirty_dir = tmp_dir("doc_commit_dirty")
    store = start_store(dirty_dir)
    db = CommitStore.db_handle(store)
    CubDB.put(db, @index_state_key, {:dirty, 1, "dirty-doc"})
    CubDB.put(db, {:doc_commit, "dirty-doc", "bogus"}, true)

    dirty_log =
      capture_log(fn ->
        assert_raise RuntimeError, ~r/doc commit index unavailable.*dirty-doc/, fn ->
          CommitStore.all_commit_ids_for_doc(store, "dirty-doc")
        end
      end)

    assert dirty_log =~ "refusing silent full-scan fallback"
    assert dirty_log =~ "dirty-doc"

    stop_supervised(store)

    interrupted_log =
      capture_log(fn ->
        repaired_store = start_store(dirty_dir)
        repaired_db = CommitStore.db_handle(repaired_store)

        assert CubDB.get(repaired_db, {:doc_commit, "dirty-doc", "bogus"}) == nil

        assert CommitStore.all_commit_ids_for_doc(repaired_store, "positive-control") ==
                 MapSet.new()
      end)

    assert interrupted_log =~ "doc commit index interrupted"
    assert interrupted_log =~ "dirty-doc"
  end
end
