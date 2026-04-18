defmodule Commonplace.Store.SnapshotOpTest do
  @moduledoc """
  CX-6sc (Build 5, closes CX-bgy umbrella): snapshot creation entry
  point + derivation map + deterministic-anyone hash. MVP is explicit
  trigger only — no cadence.

  Covers:
  - Snapshot creation happy path.
  - Deterministic-anyone: two independent snapshot calls on identical
    parent state produce identical commit IDs.
  - Hash conformance: out-of-band sha256 formula matches.
  - Namespace bootstrap: post-snapshot :regular commits auto-stamp
    snapshot_parent = snapshot.id (integrates with CX-a04).
  - Derivation map coverage + shape.
  - Composability shape (hand-crafted maps).
  - snapshotter_version in hash (changing tag changes id).
  - Empty / genesis-only doc: idempotent-ish snapshot.
  """
  use ExUnit.Case

  alias Commonplace.Store.{CommitStore, Commit, Namespace}

  setup do
    dir = Path.join(System.tmp_dir!(), "snapshot_op_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"snap_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name, dir: dir}
  end

  defp update_from(client_id, content) do
    doc = Yelixer.Doc.new(client_id: client_id)
    {doc, _} = Yelixer.Doc.get_or_create_type(doc, "t", :text)
    doc = Yelixer.Types.Text.insert(doc, "t", 0, content)
    Yelixer.Encoding.encode_update(doc)
  end

  defp seed_doc_with_commits(store, uuid, client_id, contents) do
    {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)
    Enum.each(contents, fn c ->
      CommitStore.create_chained_commit(store, uuid, update_from(client_id, c), %{kind: :regular})
    end)
  end

  describe "CommitStore.snapshot/2 happy path" do
    test "creates a commit with kind: :snapshot", %{store: store} do
      uuid = "snap-happy"
      seed_doc_with_commits(store, uuid, 1, ["a", "b", "c"])

      {:ok, snapshot} = CommitStore.snapshot(store, uuid)

      assert snapshot.metadata[:kind] == :snapshot
    end

    test "snapshot becomes the new :latest", %{store: store} do
      uuid = "snap-latest"
      seed_doc_with_commits(store, uuid, 1, ["x", "y"])

      {:ok, snapshot} = CommitStore.snapshot(store, uuid)

      {:ok, latest} = CommitStore.latest_commit(store, uuid)
      assert latest.id == snapshot.id
    end

    test "snapshot carries snapshot_parents: [namespace(parent)]", %{store: store} do
      uuid = "snap-parents"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)
      # One regular commit so snapshot's parent is a :regular whose
      # namespace = genesis.id.
      CommitStore.create_chained_commit(store, uuid, update_from(1, "a"), %{kind: :regular})

      {:ok, snapshot} = CommitStore.snapshot(store, uuid)

      assert snapshot.metadata[:snapshot_parents] == [genesis.id]
    end

    test "snapshot carries snapshotter_version: 1", %{store: store} do
      uuid = "snap-version"
      seed_doc_with_commits(store, uuid, 1, ["a"])

      {:ok, snapshot} = CommitStore.snapshot(store, uuid)
      assert snapshot.metadata[:snapshotter_version] == 1
    end

    test "snapshot carries a derivation_map", %{store: store} do
      uuid = "snap-dm"
      seed_doc_with_commits(store, uuid, 1, ["hello"])

      {:ok, snapshot} = CommitStore.snapshot(store, uuid)
      assert is_map(snapshot.metadata[:derivation_map])
    end
  end

  describe "deterministic-anyone (load-bearing)" do
    test "two independent CommitStore instances snapshotting the same doc produce identical commit ids", %{store: store_a, dir: _dir_a} do
      uuid = "det-same"

      seed_doc_with_commits(store_a, uuid, 42, ["same content"])

      # Second CommitStore: independent BEAM process, independent on-disk
      # state, same doc_uuid + same commit sequence ⇒ MUST snapshot to
      # a byte-identical commit (including id).
      dir_b = Path.join(System.tmp_dir!(), "snap_det_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir_b)
      name_b = :"det_store_#{:erlang.unique_integer([:positive])}"
      {:ok, pid_b} = CommitStore.start_link(data_dir: dir_b, name: name_b)
      on_exit(fn ->
        if Process.alive?(pid_b), do: GenServer.stop(pid_b)
        File.rm_rf!(dir_b)
      end)

      seed_doc_with_commits(name_b, uuid, 42, ["same content"])

      {:ok, snap_a} = CommitStore.snapshot(store_a, uuid)
      {:ok, snap_b} = CommitStore.snapshot(name_b, uuid)

      # Load-bearing property: same parent chain ⇒ identical snapshot
      # commit ids. This is what lets the commit-hash dedup collapse
      # redundant snapshots cut by different peers.
      assert snap_a.id == snap_b.id
      assert snap_a.update == snap_b.update
      assert snap_a.metadata[:derivation_map] == snap_b.metadata[:derivation_map]
      assert snap_a.metadata[:snapshot_parents] == snap_b.metadata[:snapshot_parents]
    end
  end

  describe "hash conformance (out-of-band formula)" do
    test "snapshot.id = sha256((parent_id || <<>>) ∥ update ∥ canonical_metadata(metadata))", %{store: store} do
      uuid = "hash-conform"
      seed_doc_with_commits(store, uuid, 1, ["hi"])

      {:ok, snapshot} = CommitStore.snapshot(store, uuid)

      parent_bytes = snapshot.parent_id || <<>>
      meta_bytes = :erlang.term_to_binary(snapshot.metadata, [:deterministic])
      # merge_parents = [] so their canonical form is <<>>.
      expected = :crypto.hash(:sha256, parent_bytes <> snapshot.update <> meta_bytes)

      assert snapshot.id == expected
    end

    test "changing snapshotter_version changes the commit id", %{store: store} do
      uuid = "hash-version"
      seed_doc_with_commits(store, uuid, 1, ["ok"])

      {:ok, snapshot} = CommitStore.snapshot(store, uuid)

      # Build an identical commit but with a different snapshotter_version
      # and verify the id changes.
      alt_metadata = Map.put(snapshot.metadata, :snapshotter_version, 2)
      alt = Commit.new(snapshot.doc_uuid, snapshot.update, snapshot.parent_id, alt_metadata)

      refute alt.id == snapshot.id
    end
  end

  describe "namespace bootstrap post-snapshot (CX-a04 integration)" do
    test "first regular commit after a snapshot auto-stamps snapshot_parent = snapshot.id", %{store: store} do
      uuid = "bootstrap"
      seed_doc_with_commits(store, uuid, 1, ["seed"])

      {:ok, snapshot} = CommitStore.snapshot(store, uuid)

      # New regular commit on top of the snapshot should have
      # snapshot_parent = snapshot.id (per current_namespace).
      reg = CommitStore.create_chained_commit(store, uuid, update_from(1, "after"), %{kind: :regular})

      assert reg.metadata[:snapshot_parent] == snapshot.id
    end

    test "Namespace.current_namespace/1 on the snapshot returns the snapshot's own id", %{store: store} do
      uuid = "bootstrap-helper"
      seed_doc_with_commits(store, uuid, 1, ["seed"])

      {:ok, snapshot} = CommitStore.snapshot(store, uuid)
      assert Namespace.current_namespace(snapshot) == snapshot.id
    end
  end

  describe "derivation map coverage" do
    test "every new item in the snapshot has an entry in the derivation map", %{store: store} do
      uuid = "dm-cov"
      {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)
      CommitStore.create_chained_commit(store, uuid, update_from(3, "abc"), %{kind: :regular})

      {:ok, snapshot} = CommitStore.snapshot(store, uuid)
      dm = snapshot.metadata[:derivation_map]

      # Decode the snapshot update and check that every item id in it
      # appears as a key somewhere inside the derivation_map's values.
      {:ok, doc} = Yelixer.Encoding.apply_update(Yelixer.Doc.new(), snapshot.update)
      new_ids =
        doc.store.clients
        |> Enum.flat_map(fn {_client, items} ->
          Enum.map(items, fn it -> {it.id.client, it.id.clock} end)
        end)
        |> MapSet.new()

      covered =
        dm
        |> Map.values()
        |> Enum.flat_map(&Map.keys/1)
        |> MapSet.new()

      assert MapSet.subset?(new_ids, covered),
             "not every new item id was in the derivation_map; missing: " <>
               inspect(MapSet.to_list(MapSet.difference(new_ids, covered)))
    end

    test "derivation_map is keyed by source_snapshot_hash (single entry for single-parent snapshot)", %{store: store} do
      uuid = "dm-shape"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)
      CommitStore.create_chained_commit(store, uuid, update_from(1, "x"), %{kind: :regular})

      {:ok, snapshot} = CommitStore.snapshot(store, uuid)
      dm = snapshot.metadata[:derivation_map]

      # Only one source parent — namespace(parent) == genesis.id.
      assert Map.keys(dm) == [genesis.id]
    end
  end

  describe "composability property (shape-only, no impl)" do
    test "DM format supports composition: compose(DM1, DM2)[S0][new_id_in_S2] = DM1[S0][DM2[S1][new_id_in_S2]]" do
      # Hand-crafted maps — this test locks in the format shape, not
      # CommitStore behavior. The actual compose implementation is
      # deferred (build 6/7).
      s0 = "source-hash-0"
      s1 = "source-hash-1"

      # DM1: S0 → {i1_new → i0_source}
      dm1 = %{s0 => %{{42, 10} => {42, 0}, {42, 11} => {42, 1}}}
      # DM2: S1 → {i2_new → i1_source}
      dm2 = %{s1 => %{{42, 20} => {42, 10}, {42, 21} => {42, 11}}}

      compose = fn dm1, dm2, source_key, mid_key ->
        inner1 = dm1[source_key]
        inner2 = dm2[mid_key]
        composed = Map.new(inner2, fn {new_id, mid_id} -> {new_id, Map.get(inner1, mid_id)} end)
        %{source_key => composed}
      end

      composed = compose.(dm1, dm2, s0, s1)
      assert composed == %{s0 => %{{42, 20} => {42, 0}, {42, 21} => {42, 1}}}
    end
  end

  describe "edge cases" do
    test "snapshot of a genesis-only doc (never had a regular commit)", %{store: store} do
      uuid = "genesis-only"
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)
      CommitStore.set_latest(store, uuid, genesis.id)

      {:ok, snapshot} = CommitStore.snapshot(store, uuid)

      # Snapshot of an empty doc is valid — empty observable state, but
      # the metadata scaffolding is still present.
      assert snapshot.metadata[:kind] == :snapshot
      assert snapshot.metadata[:snapshot_parents] == [genesis.id]
      assert snapshot.metadata[:snapshotter_version] == 1
      # Derivation map may be empty for a genesis-only snapshot (no items
      # to derive), but it must be a map.
      assert is_map(snapshot.metadata[:derivation_map])
    end

    test "snapshotting twice back-to-back is deterministic (second sees first)", %{store: store} do
      uuid = "back-to-back"
      seed_doc_with_commits(store, uuid, 1, ["first"])

      {:ok, snap1} = CommitStore.snapshot(store, uuid)
      {:ok, snap2} = CommitStore.snapshot(store, uuid)

      # snap2's parent is snap1, and namespace(snap1) = snap1.id.
      assert snap2.parent_id == snap1.id
      assert snap2.metadata[:snapshot_parents] == [snap1.id]
    end
  end

  describe "snapshot integrates with rejection telemetry (validator guard still holds)" do
    test "importing a snapshot with mismatched snapshot_parent list structure still validates as :snapshot (accepts)", %{store: store} do
      # Snapshots bypass the regular-commit clientID check. This test
      # confirms the validator's :snapshot clause still accepts even a
      # locally-stamped snapshot imported elsewhere.
      uuid = "import-snap"
      seed_doc_with_commits(store, uuid, 1, ["a"])

      {:ok, snapshot} = CommitStore.snapshot(store, uuid)

      # Import it into a second store — should accept.
      dir2 = Path.join(System.tmp_dir!(), "snap_recv_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir2)
      name2 = :"recv_store_#{:erlang.unique_integer([:positive])}"
      {:ok, pid2} = CommitStore.start_link(data_dir: dir2, name: name2)
      on_exit(fn ->
        if Process.alive?(pid2), do: GenServer.stop(pid2)
        File.rm_rf!(dir2)
      end)

      assert :ok = CommitStore.import_commit(name2, snapshot)
    end
  end
end
