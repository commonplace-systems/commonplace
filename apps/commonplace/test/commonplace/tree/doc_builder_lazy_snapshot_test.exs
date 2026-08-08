defmodule Commonplace.Tree.DocBuilderLazySnapshotTest do
  @moduledoc """
  CX-fkvc: when DocBuilder.reconstruct_doc replays a chain longer
  than the lazy-snapshot threshold, opportunistically fire the
  SnapshotTrigger primitive in the background. The next reader
  benefits from a fresh snapshot; this reader still gets the doc
  back without blocking on the snapshot build.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.DocBuilder

  setup do
    if Process.whereis(Commonplace.SnapshotWorker) == nil do
      start_supervised!(Commonplace.SnapshotWorker)
    end

    dir = Path.join(System.tmp_dir!(), "cp_lazy_snap_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"lazy_snap_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    prior_threshold = Application.get_env(:commonplace, :reader_lazy_snapshot_threshold)
    prior_trigger = Application.get_env(:commonplace, :snapshot_chain_threshold)
    prior_enabled = Application.get_env(:commonplace, :reader_lazy_snapshot_enabled)

    Application.put_env(:commonplace, :reader_lazy_snapshot_enabled, true)

    on_exit(fn ->
      restore(:reader_lazy_snapshot_threshold, prior_threshold)
      restore(:snapshot_chain_threshold, prior_trigger)
      restore(:reader_lazy_snapshot_enabled, prior_enabled)
    end)

    %{store: store_name}
  end

  defp restore(:data_dir, nil), do: Application.put_env(:commonplace, :data_dir, "tmp/test_data")
  defp restore(key, nil), do: Application.delete_env(:commonplace, key)
  defp restore(key, val), do: Application.put_env(:commonplace, key, val)

  defp seed_chained_doc(store, n_commits) do
    uuid = UUID.uuid4()

    for i <- 1..n_commits do
      doc = Yelixer.Doc.new()
      doc = ContentType.create(doc, :text, "doc.txt")
      doc = ContentType.insert_text(doc, 0, "v#{i}")
      update = Yelixer.Encoding.encode_update(doc)

      if i == 1 do
        CommitStore.create_commit(store, uuid, update, nil)
      else
        CommitStore.create_chained_commit(store, uuid, update)
      end
    end

    uuid
  end

  defp wait_for_snapshot(store, uuid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      Process.sleep(20)
      log = CommitStore.commit_log(store, uuid)
      Enum.any?(log, fn c -> c.metadata[:kind] == :snapshot end)
    end)
    |> Enum.reduce_while(false, fn done?, _acc ->
      cond do
        done? -> {:halt, true}
        System.monotonic_time(:millisecond) > deadline -> {:halt, false}
        true -> {:cont, false}
      end
    end)
  end

  defp store_row_count(store) do
    store
    |> CommitStore.db_handle()
    |> CubDB.select()
    |> Enum.count()
  end

  defp wait_for_snapshot_worker(timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_snapshot_worker_idle(deadline)
  end

  defp wait_for_snapshot_worker_idle(deadline) do
    state = :sys.get_state(Commonplace.SnapshotWorker)

    cond do
      state.inflight == %{} and state.pending == %{} ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("SnapshotWorker did not settle within the timeout: #{inspect(state)}")

      true ->
        wait_for_snapshot_worker_idle(deadline)
    end
  end

  describe "reader-lazy snapshot trigger (CX-fkvc)" do
    test "deep reads expose and can suppress their destination write", %{store: store} do
      Application.put_env(:commonplace, :reader_lazy_snapshot_threshold, 5)
      Application.put_env(:commonplace, :snapshot_chain_threshold, 50)

      minting_uuid = seed_chained_doc(store, 6)
      refute snapshot?(store, minting_uuid)
      rows_before_minting_read = store_row_count(store)

      Application.put_env(:commonplace, :snapshot_chain_threshold, 5)
      assert {:ok, _doc} = DocBuilder.reconstruct_doc(store, minting_uuid)
      assert :ok = wait_for_snapshot_worker()
      assert store_row_count(store) == rows_before_minting_read + 1

      Application.put_env(:commonplace, :snapshot_chain_threshold, 50)
      read_only_uuid = seed_chained_doc(store, 6)
      refute snapshot?(store, read_only_uuid)
      rows_before_read_only = store_row_count(store)

      Application.put_env(:commonplace, :snapshot_chain_threshold, 5)
      assert {:ok, _doc} = DocBuilder.reconstruct_doc(store, read_only_uuid, read_only: true)
      assert :ok = wait_for_snapshot_worker()
      assert store_row_count(store) == rows_before_read_only
    end

    test "long-chain reads opportunistically trigger a snapshot",
         %{store: store} do
      Application.put_env(:commonplace, :reader_lazy_snapshot_threshold, 5)
      Application.put_env(:commonplace, :snapshot_chain_threshold, 5)

      uuid = seed_chained_doc(store, 6)

      log_before = CommitStore.commit_log(store, uuid)
      refute Enum.any?(log_before, fn c -> c.metadata[:kind] == :snapshot end)

      assert {:ok, _doc} = DocBuilder.reconstruct_doc(store, uuid)

      assert wait_for_snapshot(store, uuid, 2_000),
             "reader-lazy snapshot did not land within 2s"
    end

    test "short-chain reads do not trigger a snapshot", %{store: store} do
      Application.put_env(:commonplace, :reader_lazy_snapshot_threshold, 50)

      uuid = seed_chained_doc(store, 3)

      assert {:ok, _doc} = DocBuilder.reconstruct_doc(store, uuid)
      Process.sleep(150)

      log = CommitStore.commit_log(store, uuid)

      refute Enum.any?(log, fn c -> c.metadata[:kind] == :snapshot end),
             "below-threshold read should not have triggered a snapshot"
    end
  end

  defp snapshot?(store, uuid) do
    store
    |> CommitStore.commit_log(uuid)
    |> Enum.any?(fn commit -> commit.metadata[:kind] == :snapshot end)
  end
end
