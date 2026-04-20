defmodule Commonplace.Document.ServerNamespaceTest do
  @moduledoc """
  CX-ch5: Document.Server tracks current_namespace (snapshot_parent hash) as
  part of GenServer state, exposed via `current_namespace/1`. Advances on
  snapshot arrival and when an incoming commit declares a different
  snapshot_parent (epoch-join).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.Server
  alias Commonplace.Store.{CommitStore, Commit}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_ns_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"ns_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})

    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store_name, dir: dir}
  end

  describe "current_namespace tracker (CX-ch5)" do
    test "fresh doc — current_namespace is the genesis hash after init", %{store: store} do
      uuid = UUID.uuid4()

      pid =
        start_supervised!({Server, uuid: uuid, commit_store: store, client_id: 1}, id: uuid)

      # CX-m3x auto-stamps genesis on first write. Before any write, the
      # server should report current_namespace derived from what's loadable
      # — either the genesis (if pre-stamped) or nil (if the store has
      # nothing yet). This test triggers a commit to stamp + load.
      :ok = Server.create(pid, :text, "t")
      {:ok, _c1} = Server.commit(pid)

      ns = Server.current_namespace(pid)
      assert is_binary(ns), "expected current_namespace to be a hash binary, got #{inspect(ns)}"

      # The namespace must equal the genesis id for this doc.
      genesis = Commit.genesis(uuid)
      assert ns == genesis.id
    end

    test "advances to snapshot.id when a snapshot commit arrives on remote_commit",
         %{store: store} do
      uuid = UUID.uuid4()

      pid =
        start_supervised!({Server, uuid: uuid, commit_store: store, client_id: 1}, id: uuid)

      :ok = Server.create(pid, :text, "t")
      {:ok, _c1} = Server.commit(pid)

      # Build a snapshot commit targeting this UUID.
      snap_update = <<0, 0>>

      snap_commit =
        Commit.new(
          uuid,
          snap_update,
          Server.current_namespace(pid),
          %{kind: :snapshot, snapshot_parents: [], derivation_map: %{}},
          []
        )

      # Deliver as a remote commit from another node.
      send(pid, {:remote_commit, snap_commit, :nonode@nohost_other})
      # GenServer.call to flush the mailbox past the handle_info.
      _ = Server.get_doc(pid)

      assert Server.current_namespace(pid) == snap_commit.id
    end

    test "advances on regular commit whose snapshot_parent differs (epoch join)",
         %{store: store} do
      uuid = UUID.uuid4()

      pid =
        start_supervised!({Server, uuid: uuid, commit_store: store, client_id: 1}, id: uuid)

      :ok = Server.create(pid, :text, "t")
      {:ok, _c1} = Server.commit(pid)

      initial_ns = Server.current_namespace(pid)
      assert is_binary(initial_ns)

      # Fabricate a regular commit declaring a DIFFERENT snapshot_parent.
      new_ns_hash = :crypto.hash(:sha256, "other-namespace")
      upd = <<0, 0>>

      foreign =
        Commit.new(uuid, upd, initial_ns, %{kind: :regular, snapshot_parent: new_ns_hash}, [])

      send(pid, {:remote_commit, foreign, :nonode@nohost_other})
      _ = Server.get_doc(pid)

      # CX-ch5: current_namespace advances when a commit declares a
      # snapshot_parent different from what we were tracking.
      assert Server.current_namespace(pid) == new_ns_hash
    end

    test "stays put when remote commit carries the same snapshot_parent",
         %{store: store} do
      uuid = UUID.uuid4()

      pid =
        start_supervised!({Server, uuid: uuid, commit_store: store, client_id: 1}, id: uuid)

      :ok = Server.create(pid, :text, "t")
      {:ok, _c1} = Server.commit(pid)

      ns_before = Server.current_namespace(pid)

      # Remote regular commit declaring the SAME namespace.
      upd = <<0, 0>>

      same =
        Commit.new(uuid, upd, ns_before, %{kind: :regular, snapshot_parent: ns_before}, [])

      send(pid, {:remote_commit, same, :nonode@nohost_other})
      _ = Server.get_doc(pid)

      assert Server.current_namespace(pid) == ns_before
    end
  end

  describe "two-node replication — current_namespace agrees across peers" do
    # The Document.Server Registry is process-local and keyed by uuid, so
    # two Servers for the same uuid can't coexist in one BEAM. We simulate
    # two nodes by (1) running A, producing commits, (2) stopping A and
    # replicating commits into a second CommitStore, (3) starting B in
    # that store — B should report the same current_namespace that A held.
    test "node B's Server loads the same current_namespace as A after replication",
         %{store: store_a} do
      dir_b = Path.join(System.tmp_dir!(), "cp_ns_b_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir_b)
      store_b = :"ns_store_b_#{:rand.uniform(1_000_000)}"
      start_supervised!({CommitStore, data_dir: dir_b, name: store_b}, id: :b_store)

      on_exit(fn -> File.rm_rf!(dir_b) end)

      uuid = UUID.uuid4()

      pid_a =
        start_supervised!({Server, uuid: uuid, commit_store: store_a, client_id: 10},
          id: {:srv, :a}
        )

      # A creates initial content + commit, then fabricates a snapshot
      # arriving via remote_commit to advance its current_namespace.
      :ok = Server.create(pid_a, :text, "t")
      {:ok, c1} = Server.commit(pid_a)

      ns_a_initial = Server.current_namespace(pid_a)
      assert is_binary(ns_a_initial)

      snap_update = <<0, 0>>

      snap =
        Commit.new(
          uuid,
          snap_update,
          c1.id,
          %{kind: :snapshot, snapshot_parents: [ns_a_initial], derivation_map: %{}},
          []
        )

      send(pid_a, {:remote_commit, snap, :nonode@nohost_other})
      _ = Server.get_doc(pid_a)

      assert Server.current_namespace(pid_a) == snap.id

      # Replicate A's commits into store_b, then stop A and start B.
      CommitStore.import_commit(store_b, c1)
      CommitStore.import_commit(store_b, snap)
      # Tell B's store the latest is the snapshot (simulates what a sync
      # agent would do on catch-up).
      :ok = CommitStore.set_latest(store_b, uuid, snap.id)
      :ok = stop_supervised({:srv, :a})

      pid_b =
        start_supervised!({Server, uuid: uuid, commit_store: store_b, client_id: 20},
          id: {:srv, :b}
        )

      assert Server.current_namespace(pid_b) == snap.id
    end
  end
end
