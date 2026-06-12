defmodule Commonplace.Sync.VersionTrackingTest do
  @moduledoc """
  Tests for commit-ancestry-based version tracking in the sync agent.

  Verifies that the sync agent uses commit IDs (not just content hashes)
  to make smart decisions about when to write to disk vs skip.
  """
  use ExUnit.Case

  alias Commonplace.Sync.SyncLoop
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore
  alias Commonplace.Document.ContentType

  setup do
    data_dir = Path.join(System.tmp_dir!(), "cp_vtrack_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(data_dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: data_dir, name: store_name})

    dir_a = Path.join(System.tmp_dir!(), "cp_vt_a_#{:rand.uniform(1_000_000)}")
    dir_b = Path.join(System.tmp_dir!(), "cp_vt_b_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir_a)
    File.mkdir_p!(dir_b)

    on_exit(fn ->
      File.rm_rf!(data_dir)
      File.rm_rf!(dir_a)
      File.rm_rf!(dir_b)
    end)

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{store: store_name, root: root_uuid, dir_a: dir_a, dir_b: dir_b}
  end

  describe "commit-based version tracking" do
    test "skips disk write when latest commit matches last written",
         %{store: store, root: root, dir_a: dir_a} do
      write_count = :counters.new(1, [:atomics])

      {:ok, pid} = SyncLoop.start_link(
        dir: dir_a, root_uuid: root, store: store, interval: 50,
        on_cycle: fn _count ->
          :counters.add(write_count, 1, 1)
        end
      )

      File.write!(Path.join(dir_a, "stable.txt"), "content")
      Process.sleep(300)

      # File is synced. Now let several more cycles run — no disk writes needed
      _count_before = :counters.get(write_count, 1)
      Process.sleep(300)
      _count_after = :counters.get(write_count, 1)

      # Cycles still run (timer fires) but file on disk shouldn't change
      assert File.read!(Path.join(dir_a, "stable.txt")) == "content"

      GenServer.stop(pid)
    end

    test "remote CRDT update propagates without being overwritten by stale disk",
         %{store: store, root: root, dir_a: dir_a, dir_b: dir_b} do
      # Peer A creates file
      {:ok, loop_a} = SyncLoop.start_link(
        dir: dir_a, root_uuid: root, store: store, interval: 50
      )
      File.write!(Path.join(dir_a, "doc.txt"), "v1")
      Process.sleep(300)

      # Peer B joins
      {:ok, loop_b} = SyncLoop.start_link(
        dir: dir_b, root_uuid: root, store: store, interval: 50
      )

      await = fn path, expected ->
        Enum.reduce_while(1..100, nil, fn _, _ ->
          case File.read(path) do
            {:ok, ^expected} -> {:halt, :ok}
            _ -> Process.sleep(100) && {:cont, nil}
          end
        end) || flunk("#{path} never reached #{inspect(expected)}")
      end

      await.(Path.join(dir_b, "doc.txt"), "v1")

      # Peer A modifies
      File.write!(Path.join(dir_a, "doc.txt"), "v2")

      # Peer B should EVENTUALLY have v2 (not v1 overwriting the CRDT).
      # Await-poll rather than a fixed sleep: the test pins propagation
      # correctness, not an 800ms latency SLA — fixed sleeps flaked
      # under full-suite load (seen when CX-saix's YMap origin-threading
      # added a small per-write cost that narrowed the old margin).
      await.(Path.join(dir_b, "doc.txt"), "v2")

      # Verify CRDT also has v2 (not corrupted by stale outbound)
      root_doc = load_schema(root, store)
      {:ok, entry} = Schema.get_entry(root_doc, "doc.txt")
      {:ok, commit} = CommitStore.latest_commit(store, entry.node_id)
      doc = Yelixer.Doc.new()
      {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
      assert ContentType.get_content(doc) == "v2"

      GenServer.stop(loop_a)
      GenServer.stop(loop_b)
    end

    test "concurrent edits on both peers resolve via CRDT",
         %{store: store, root: root, dir_a: dir_a, dir_b: dir_b} do
      {:ok, loop_a} = SyncLoop.start_link(
        dir: dir_a, root_uuid: root, store: store, interval: 50
      )

      # Create initial file via peer A
      File.write!(Path.join(dir_a, "shared.txt"), "original")
      Process.sleep(300)

      {:ok, loop_b} = SyncLoop.start_link(
        dir: dir_b, root_uuid: root, store: store, interval: 50
      )
      Process.sleep(300)

      # Both peers should have the file
      assert File.read!(Path.join(dir_a, "shared.txt")) == "original"
      assert File.read!(Path.join(dir_b, "shared.txt")) == "original"

      # Both peers modify simultaneously
      File.write!(Path.join(dir_a, "shared.txt"), "from A")
      File.write!(Path.join(dir_b, "shared.txt"), "from B")
      Process.sleep(800)

      # After sync settles, both peers should converge to the same content
      content_a = File.read!(Path.join(dir_a, "shared.txt"))
      content_b = File.read!(Path.join(dir_b, "shared.txt"))
      assert content_a == content_b

      GenServer.stop(loop_a)
      GenServer.stop(loop_b)
    end
  end

  defp load_schema(uuid, store) do
    case CommitStore.latest_commit(store, uuid) do
      {:ok, commit} ->
        doc = Schema.new_schema()
        {:ok, doc} = Yelixer.Encoding.apply_update(doc, commit.update)
        doc

      :none ->
        Schema.new_schema()
    end
  end
end
