defmodule Commonplace.Sync.LiveSyncIntegrationTest do
  @moduledoc """
  Integration tests proving edits flow between two directories
  through the shared CRDT store via live sync loops.
  """
  use ExUnit.Case

  alias Commonplace.Sync.SyncLoop
  alias Commonplace.Tree.Schema
  alias Commonplace.Store.CommitStore
  setup do
    data_dir = Path.join(System.tmp_dir!(), "cp_livesync_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(data_dir)
    store_name = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: data_dir, name: store_name})

    dir_a = Path.join(System.tmp_dir!(), "cp_peer_a_#{:rand.uniform(1_000_000)}")
    dir_b = Path.join(System.tmp_dir!(), "cp_peer_b_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir_a)
    File.mkdir_p!(dir_b)

    on_exit(fn ->
      File.rm_rf!(data_dir)
      File.rm_rf!(dir_a)
      File.rm_rf!(dir_b)
    end)

    # Shared root schema
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{store: store_name, root: root_uuid, dir_a: dir_a, dir_b: dir_b}
  end

  describe "peer-to-peer sync via shared CRDT" do
    test "file created on peer A appears on peer B",
         %{store: store, root: root, dir_a: dir_a, dir_b: dir_b} do
      {:ok, loop_a} = SyncLoop.start_link(
        dir: dir_a, root_uuid: root, store: store, interval: 50
      )
      {:ok, loop_b} = SyncLoop.start_link(
        dir: dir_b, root_uuid: root, store: store, interval: 50
      )

      # Peer A creates a file
      File.write!(Path.join(dir_a, "from_a.txt"), "hello from A")

      # Wait for A to sync outbound, then B to sync inbound
      Process.sleep(400)

      # Peer B should have the file
      assert File.read!(Path.join(dir_b, "from_a.txt")) == "hello from A"

      GenServer.stop(loop_a)
      GenServer.stop(loop_b)
    end

    test "file created on peer B appears on peer A",
         %{store: store, root: root, dir_a: dir_a, dir_b: dir_b} do
      {:ok, loop_a} = SyncLoop.start_link(
        dir: dir_a, root_uuid: root, store: store, interval: 50
      )
      {:ok, loop_b} = SyncLoop.start_link(
        dir: dir_b, root_uuid: root, store: store, interval: 50
      )

      File.write!(Path.join(dir_b, "from_b.txt"), "hello from B")
      Process.sleep(400)

      assert File.read!(Path.join(dir_a, "from_b.txt")) == "hello from B"

      GenServer.stop(loop_a)
      GenServer.stop(loop_b)
    end

    test "both peers create files and both receive each other's",
         %{store: store, root: root, dir_a: dir_a, dir_b: dir_b} do
      {:ok, loop_a} = SyncLoop.start_link(
        dir: dir_a, root_uuid: root, store: store, interval: 50
      )
      {:ok, loop_b} = SyncLoop.start_link(
        dir: dir_b, root_uuid: root, store: store, interval: 50
      )

      File.write!(Path.join(dir_a, "a_file.txt"), "from A")
      File.write!(Path.join(dir_b, "b_file.txt"), "from B")

      Process.sleep(500)

      # Both files should exist on both peers
      assert File.read!(Path.join(dir_a, "a_file.txt")) == "from A"
      assert File.read!(Path.join(dir_a, "b_file.txt")) == "from B"
      assert File.read!(Path.join(dir_b, "a_file.txt")) == "from A"
      assert File.read!(Path.join(dir_b, "b_file.txt")) == "from B"

      GenServer.stop(loop_a)
      GenServer.stop(loop_b)
    end

    test "file modification on one peer propagates to the other",
         %{store: store, root: root, dir_a: dir_a, dir_b: dir_b} do
      {:ok, loop_a} = SyncLoop.start_link(
        dir: dir_a, root_uuid: root, store: store, interval: 50
      )

      # Create file via peer A
      File.write!(Path.join(dir_a, "shared.txt"), "version 1")
      Process.sleep(300)

      # Start peer B — it should get the file
      {:ok, loop_b} = SyncLoop.start_link(
        dir: dir_b, root_uuid: root, store: store, interval: 50
      )
      Process.sleep(300)
      assert File.read!(Path.join(dir_b, "shared.txt")) == "version 1"

      # Modify on peer A
      File.write!(Path.join(dir_a, "shared.txt"), "version 2")
      Process.sleep(800)

      # Peer B should see the update
      assert File.read!(Path.join(dir_b, "shared.txt")) == "version 2"

      GenServer.stop(loop_a)
      GenServer.stop(loop_b)
    end
  end
end
