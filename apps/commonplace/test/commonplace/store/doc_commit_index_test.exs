defmodule Commonplace.Store.DocCommitIndexTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Commonplace.SiblingMerger
  alias Commonplace.Store.{Commit, CommitStore}
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  @index_state_key {:doc_commit_index, :state}
  @project_root Path.expand("../../../../..", __DIR__)
  @commit_row_checker Path.join(@project_root, "scripts/check_commonplace_commit_row_writes.exs")

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

  test "every production commit-row writer is an enumerated row-pair site" do
    {output, status} =
      System.cmd("elixir", [@commit_row_checker, @project_root], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "commonplace commit-row boundary check passed"
    assert output =~ "commit_store.ex:commit_rows/… — the private persistence choke"
    assert output =~ "mixed_plane_history_fixture.ex:seed!/… — the incident fixture"

    # This production reader is intentionally part of the scanned tree. Its
    # presence in the checker's read-only report proves a select/reduce match
    # is distinguished from a persistence expression and does not trip the
    # perimeter.
    assert output =~ "ignored read pattern"
    assert output =~ "mixed_plane_history.ex"
  end

  test "a stray commit-row write in a DIFFERENT UMBRELLA APP trips the perimeter" do
    # ⛔ The sibling test below injects into apps/commonplace/lib — the app the
    # checker already scans. That control cannot reveal the checker's BOUNDARY,
    # only its behaviour inside it. Measured 2026-08-09: with the glob scoped to
    # one app, this exact write in commonplace_web PASSED rc=0 while the
    # identical write in commonplace was caught rc=1.
    # ⇒ A control that can only fire where the guard already looks says nothing
    # about where the guard stops.
    temp_root =
      Path.join(
        System.tmp_dir!(),
        "commonplace-commit-row-crossapp-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(temp_root) end)

    for app <- ["commonplace", "commonplace_web"] do
      source = Path.join([@project_root, "apps", app, "lib"])
      destination = Path.join([temp_root, "apps", app, "lib"])
      File.mkdir_p!(Path.dirname(destination))
      File.cp_r!(source, destination)
    end

    tamper_path =
      Path.join([temp_root, "apps", "commonplace_web", "lib", "stray_commit_writer.ex"])

    File.write!(
      tamper_path,
      "defmodule CommonplaceWeb.StrayCommitWriter do\n" <>
        "  def write(db, id, commit) do\n" <>
        "    CubDB.put_multi(db, [{{:commit, id}, commit}])\n" <>
        "  end\n" <>
        "end\n"
    )

    {output, status} =
      System.cmd("elixir", [@commit_row_checker, temp_root], stderr_to_stdout: true)

    assert status == 1, output
    assert output =~ "commonplace_web/lib/stray_commit_writer.ex"
    assert output =~ "unexpected commit-row write"
  end

  test "a stray commit-row write in a third production module trips the perimeter" do
    temp_root =
      Path.join(
        System.tmp_dir!(),
        "commonplace-commit-row-boundary-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(temp_root) end)

    source = Path.join([@project_root, "apps", "commonplace", "lib"])
    destination = Path.join([temp_root, "apps", "commonplace", "lib"])
    File.mkdir_p!(Path.dirname(destination))
    File.cp_r!(source, destination)

    tamper_path = Path.join(destination, "commonplace/stray_commit_writer.ex")

    File.write!(
      tamper_path,
      "defmodule Commonplace.StrayCommitWriter do\n" <>
        "  def write(db, id, commit) do\n" <>
        "    CubDB.put_multi(db, [{{:commit, id}, commit}])\n" <>
        "  end\n" <>
        "end\n"
    )

    {output, status} =
      System.cmd("elixir", [@commit_row_checker, temp_root], stderr_to_stdout: true)

    if System.get_env("SHOW_COMMIT_ROW_TAMPER") == "1", do: IO.write(output)

    assert status == 1
    assert output =~ "commonplace commit-row boundary check failed"
    assert output =~ "stray_commit_writer.ex:3:write/…: unexpected commit-row write"
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
