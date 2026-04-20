defmodule Commonplace.SnapshotSweeperTest do
  @moduledoc """
  Tests for the periodic snapshot-sweep service (CX-fab5).

  The sweeper walks all docs known to the local CommitStore on a
  configurable interval and invokes the SnapshotTrigger primitive on
  each — catching docs that have accumulated chain length but haven't
  been written recently (so the producer-side trigger CX-tvyb hasn't
  had a chance to fire).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.ContentType
  alias Commonplace.SnapshotSweeper
  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_sweeper_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"sweeper_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name, dir: dir}
  end

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

  describe "sweep/2" do
    test "snapshots every doc that has crossed the threshold", %{store: store} do
      bloated_uuid = seed_chained_doc(store, 5)
      tiny_uuid = seed_chained_doc(store, 1)

      assert :ok = SnapshotSweeper.sweep(store, chain_length_threshold: 3)

      bloated_log = CommitStore.commit_log(store, bloated_uuid)
      assert Enum.any?(bloated_log, fn c -> c.metadata[:kind] == :snapshot end),
             "bloated doc should have been snapshotted"

      tiny_log = CommitStore.commit_log(store, tiny_uuid)

      refute Enum.any?(tiny_log, fn c -> c.metadata[:kind] == :snapshot end),
             "below-threshold doc should NOT have been snapshotted"
    end

    test "is a no-op on a workspace with no docs", %{store: store} do
      assert :ok = SnapshotSweeper.sweep(store, chain_length_threshold: 3)
    end
  end

  describe "supervised loop" do
    test "fires sweep on the configured interval", %{store: store} do
      bloated_uuid = seed_chained_doc(store, 5)

      sup_name = :"sweeper_sup_#{:rand.uniform(1_000_000)}"

      {:ok, _sup} =
        Supervisor.start_link(
          [
            {SnapshotSweeper,
             [
               store: store,
               interval: 50,
               chain_length_threshold: 3
             ]}
          ],
          strategy: :one_for_one,
          name: sup_name
        )

      # Poll for the snapshot to land. The first tick fires after `interval`,
      # and the snapshot-trigger work is instantaneous.
      deadline = System.monotonic_time(:millisecond) + 5_000

      snapshotted? =
        Stream.repeatedly(fn ->
          Process.sleep(50)
          log = CommitStore.commit_log(store, bloated_uuid)
          Enum.any?(log, fn c -> c.metadata[:kind] == :snapshot end)
        end)
        |> Enum.reduce_while(false, fn done?, _acc ->
          cond do
            done? -> {:halt, true}
            System.monotonic_time(:millisecond) > deadline -> {:halt, false}
            true -> {:cont, false}
          end
        end)

      Supervisor.stop(sup_name)

      assert snapshotted?, "supervised sweeper did not snapshot the bloated doc within 5s"
    end
  end
end
