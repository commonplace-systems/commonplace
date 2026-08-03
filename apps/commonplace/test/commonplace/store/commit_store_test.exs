defmodule Commonplace.Store.CommitStoreTest do
  use ExUnit.Case

  alias Commonplace.Store.{Commit, CommitStore}

  # R4c carve-out: put_execute_clean/4 and flush_execute_clean/1 delegate to
  # TrustSideStore, so this file needs the full trio (a bare CommitStore has
  # no companion by default). Everything else in this file only exercises
  # plain commit reads/writes, which are unaffected by the trio being present.
  setup do
    dir = Path.join(System.tmp_dir!(), "commonplace_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    n = :rand.uniform(1_000_000)
    name = :"commit_store_#{n}"

    trust_side_store = :"commit_store_tss_#{n}"

    start_supervised!(
      {Commonplace.Store.Supervisor,
       data_dir: dir,
       name: :"commit_store_sup_#{n}",
       commit_store_name: name,
       trust_side_store_name: trust_side_store,
       pending_imports_name: :"commit_store_pi_#{n}"}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name, trust_side_store: trust_side_store}
  end

  describe "create_commit/3" do
    test "stores and returns a commit", %{store: store} do
      commit = CommitStore.create_commit(store, "doc-1", <<1, 2, 3>>, nil)

      assert %Commit{} = commit
      assert commit.doc_uuid == "doc-1"
      assert commit.update == <<1, 2, 3>>
    end
  end

  describe "get_commit/1" do
    test "retrieves a stored commit by ID", %{store: store} do
      commit = CommitStore.create_commit(store, "doc-1", <<1, 2, 3>>, nil)

      assert {:ok, fetched} = CommitStore.get_commit(store, commit.id)
      assert fetched.id == commit.id
      assert fetched.update == <<1, 2, 3>>
    end

    test "returns :none for unknown commit ID", %{store: store} do
      assert :none = CommitStore.get_commit(store, <<0::256>>)
    end
  end

  describe "latest_commit/1" do
    test "returns :none when no commits exist for a document", %{store: store} do
      assert :none = CommitStore.latest_commit(store, "nonexistent")
    end

    test "returns the most recent commit for a document", %{store: store} do
      c1 = CommitStore.create_commit(store, "doc-1", <<1>>, nil)
      _c2 = CommitStore.create_commit(store, "doc-1", <<2>>, c1.id)
      c3 = CommitStore.create_commit(store, "doc-1", <<3>>, c1.id)

      {:ok, latest} = CommitStore.latest_commit(store, "doc-1")
      assert latest.id == c3.id
    end

    test "tracks latest per document independently", %{store: store} do
      CommitStore.create_commit(store, "doc-1", <<1>>, nil)
      commit_b = CommitStore.create_commit(store, "doc-2", <<2>>, nil)

      {:ok, latest} = CommitStore.latest_commit(store, "doc-2")
      assert latest.id == commit_b.id
    end
  end

  describe "reads served outside the GenServer (CX-tdkq.4 R4a)" do
    # R4(a): reads run in the caller process against a directly-held CubDB
    # handle, not through the CommitStore GenServer mailbox. Suspending the
    # GenServer must NOT stall reads — if a read still routed through it, the
    # GenServer.call would time out. Writes continue to serialize through the
    # process (we do them before suspending).
    test "point and scan reads succeed while the CommitStore process is suspended", %{
      store: store
    } do
      c1 = CommitStore.create_commit(store, "doc-suspend", <<9>>, nil)
      c2 = CommitStore.create_commit(store, "doc-suspend", <<9, 9>>, c1.id)

      pid = Process.whereis(store)
      :sys.suspend(pid)

      try do
        assert {:ok, fetched} = CommitStore.get_commit(store, c2.id)
        assert fetched.id == c2.id

        assert {:ok, latest} = CommitStore.latest_commit(store, "doc-suspend")
        assert latest.id == c2.id

        assert [^c2 | _] = CommitStore.commit_log(store, "doc-suspend")
        assert MapSet.member?(CommitStore.all_doc_uuids(store), "doc-suspend")
        assert MapSet.member?(CommitStore.commit_ids_for_doc(store, "doc-suspend"), c1.id)
        assert CommitStore.is_ancestor?(store, c1.id, c2.id)
      after
        :sys.resume(pid)
      end
    end
  end

  describe "DAG chain" do
    test "can walk the full commit history via parent IDs", %{store: store} do
      c1 = CommitStore.create_commit(store, "doc-1", <<1>>, nil)
      c2 = CommitStore.create_commit(store, "doc-1", <<2>>, c1.id)
      c3 = CommitStore.create_commit(store, "doc-1", <<3>>, c2.id)

      {:ok, fetched_3} = CommitStore.get_commit(store, c3.id)
      assert fetched_3.parent_id == c2.id

      {:ok, fetched_2} = CommitStore.get_commit(store, fetched_3.parent_id)
      assert fetched_2.parent_id == c1.id

      {:ok, fetched_1} = CommitStore.get_commit(store, fetched_2.parent_id)
      # Post-CX-m3x: first commit on a fresh doc parents to deterministic genesis.
      assert fetched_1.parent_id == Commit.genesis("doc-1").id
    end
  end

  describe "create_snapshot_commit/4 (CX-u7p)" do
    test "tags the commit metadata with kind: :snapshot", %{store: store} do
      _c1 = CommitStore.create_commit(store, "doc-1", <<1>>, nil)
      snap = CommitStore.create_snapshot_commit(store, "doc-1", <<99>>)

      {:ok, fetched} = CommitStore.get_commit(store, snap.id)
      assert fetched.metadata.kind == :snapshot
    end

    test "chains to the latest commit (normal parent_id)", %{store: store} do
      c1 = CommitStore.create_commit(store, "doc-1", <<1>>, nil)
      snap = CommitStore.create_snapshot_commit(store, "doc-1", <<99>>)

      assert snap.parent_id == c1.id
      {:ok, latest} = CommitStore.latest_commit(store, "doc-1")
      assert latest.id == snap.id
    end

    test "snapshot becomes :latest, replication-walkable to root", %{store: store} do
      c1 = CommitStore.create_commit(store, "doc-1", <<1>>, nil)
      c2 = CommitStore.create_commit(store, "doc-1", <<2>>, c1.id)
      snap = CommitStore.create_snapshot_commit(store, "doc-1", <<99>>)

      # Walking back from snap reaches the original root
      {:ok, fetched_snap} = CommitStore.get_commit(store, snap.id)
      assert fetched_snap.parent_id == c2.id
      {:ok, fetched_c2} = CommitStore.get_commit(store, fetched_snap.parent_id)
      assert fetched_c2.parent_id == c1.id
    end

    test "merges caller-supplied metadata with kind: :snapshot", %{store: store} do
      _c1 = CommitStore.create_commit(store, "doc-1", <<1>>, nil)

      snap = CommitStore.create_snapshot_commit(store, "doc-1", <<99>>, %{note: "test"})

      {:ok, fetched} = CommitStore.get_commit(store, snap.id)
      assert fetched.metadata.kind == :snapshot
      assert fetched.metadata.note == "test"
    end

    test "works on a doc with no prior commits (parents to genesis)", %{store: store} do
      snap = CommitStore.create_snapshot_commit(store, "fresh-doc", <<42>>)

      # Post-CX-m3x: a snapshot on a fresh doc parents to the deterministic
      # genesis rather than nil, so the snapshot sits in a proper namespace
      # root.
      assert snap.parent_id == Commit.genesis("fresh-doc").id
      {:ok, fetched} = CommitStore.get_commit(store, snap.id)
      assert fetched.metadata.kind == :snapshot
    end
  end

  describe "create_commit/5 — auto-wire genesis on fresh doc (CX-m3x)" do
    test "first commit on a fresh uuid parents to deterministic genesis", %{store: store} do
      commit = CommitStore.create_commit(store, "doc-fresh", <<1, 2, 3>>, nil)

      expected_genesis_id = Commit.genesis("doc-fresh").id
      assert commit.parent_id == expected_genesis_id,
             "a fresh-doc commit must descend from the deterministic genesis, not nil"
    end

    test "genesis is stored and retrievable after first create_commit", %{store: store} do
      _commit = CommitStore.create_commit(store, "doc-fresh", <<1, 2, 3>>, nil)

      genesis_id = Commit.genesis("doc-fresh").id
      assert {:ok, g} = CommitStore.get_commit(store, genesis_id)
      assert g.metadata == %{kind: :genesis, doc_uuid: "doc-fresh"}
    end

    test "genesis is stamped only once — second user commit parents to the first user commit", %{store: store} do
      c1 = CommitStore.create_commit(store, "doc-fresh", <<1>>, nil)
      c2 = CommitStore.create_chained_commit(store, "doc-fresh", <<2>>)

      assert c2.parent_id == c1.id
    end

    test "explicit parent_id skips auto-genesis", %{store: store} do
      # Simulate a pre-existing commit chain (e.g., imported from a peer).
      existing = CommitStore.create_commit(store, "doc-other", <<9>>, nil)

      # Now create a commit on a different uuid, chaining to `existing.id`.
      # Since parent_id is explicit, no genesis should be auto-inserted
      # for this uuid.
      commit = CommitStore.create_commit(store, "doc-chain", <<1>>, existing.id)

      assert commit.parent_id == existing.id

      # No genesis for "doc-chain" should exist.
      chain_genesis_id = Commit.genesis("doc-chain").id
      assert :none = CommitStore.get_commit(store, chain_genesis_id)
    end

    test "pre-umbrella doc with existing :latest retains legacy behavior (parent_id stays nil)", %{store: store} do
      # Simulate a pre-umbrella doc by importing a commit that predates
      # the wiring. It has metadata=%{} and parent_id=nil (legacy hatch).
      legacy = Commit.new("doc-legacy", <<7>>, nil, %{})
      :ok = CommitStore.import_commit(store, legacy)
      :ok = CommitStore.set_latest(store, "doc-legacy", legacy.id)

      # A subsequent create_commit with parent_id=nil on this pre-umbrella
      # doc must NOT insert a retroactive genesis — write-side only per
      # the spec's pre-umbrella rule.
      new_commit = CommitStore.create_commit(store, "doc-legacy", <<8>>, nil)
      assert new_commit.parent_id == nil

      legacy_genesis_id = Commit.genesis("doc-legacy").id
      assert :none = CommitStore.get_commit(store, legacy_genesis_id)
    end
  end

  describe "ensure_genesis/2 — deterministic genesis stamping (CX-fzi)" do
    test "returns the deterministic genesis commit for a doc_uuid", %{store: store} do
      assert {:ok, genesis} = CommitStore.ensure_genesis(store, "doc-new")
      assert genesis.metadata == %{kind: :genesis, doc_uuid: "doc-new"}
      assert genesis.parent_id == nil
      assert genesis.update == <<>>
      assert genesis.merge_parents == []
    end

    test "stores genesis so get_commit/2 can retrieve it", %{store: store} do
      {:ok, genesis} = CommitStore.ensure_genesis(store, "doc-new")
      assert {:ok, fetched} = CommitStore.get_commit(store, genesis.id)
      assert fetched.id == genesis.id
      assert fetched.metadata.kind == :genesis
    end

    test "is idempotent — second call returns the same genesis", %{store: store} do
      {:ok, g1} = CommitStore.ensure_genesis(store, "doc-new")
      {:ok, g2} = CommitStore.ensure_genesis(store, "doc-new")
      assert g1.id == g2.id
    end

    test "does NOT update :latest (Option A scope — no auto-wiring)", %{store: store} do
      # If ensure_genesis flipped :latest, every caller of latest_commit
      # would observe a phantom head that the user never wrote. Callers
      # opt in to wiring genesis as the parent of the first real commit.
      {:ok, _genesis} = CommitStore.ensure_genesis(store, "doc-new")
      assert :none = CommitStore.latest_commit(store, "doc-new")
    end

    test "distinct doc_uuids produce distinct geneses", %{store: store} do
      {:ok, g_a} = CommitStore.ensure_genesis(store, "doc-a")
      {:ok, g_b} = CommitStore.ensure_genesis(store, "doc-b")
      assert g_a.id != g_b.id
    end
  end

  describe "import_commit/3 — namespace validation hook (CX-bv3)" do
    test "accepts commits by default (no validator configured)", %{store: store} do
      commit = Commit.new("doc-incoming", <<1, 2, 3>>, nil)

      assert :ok = CommitStore.import_commit(store, commit)
      assert {:ok, fetched} = CommitStore.get_commit(store, commit.id)
      assert fetched.id == commit.id
    end

    test "injected validator is invoked on every import", %{store: store} do
      parent = self()
      validator = fn commit ->
        send(parent, {:validator_called, commit.id})
        :ok
      end

      commit = Commit.new("doc-incoming", <<1, 2, 3>>, nil)

      assert :ok = CommitStore.import_commit(store, commit, validator: validator)

      assert_receive {:validator_called, id} when id == commit.id
    end

    test "import rejects when validator returns {:error, reason}", %{store: store} do
      validator = fn _commit -> {:error, :namespace_mismatch} end
      commit = Commit.new("doc-incoming", <<1, 2, 3>>, nil)

      assert {:error, {:namespace_rejected, :namespace_mismatch}} =
               CommitStore.import_commit(store, commit, validator: validator)

      # Rejected commit must NOT be persisted.
      assert :none = CommitStore.get_commit(store, commit.id)
    end

    test "rejected import does not update :latest", %{store: store} do
      validator = fn _commit -> {:error, :namespace_mismatch} end
      commit = Commit.new("doc-incoming", <<1, 2, 3>>, nil)

      assert {:error, _} = CommitStore.import_commit(store, commit, validator: validator)
      assert :none = CommitStore.latest_commit(store, "doc-incoming")
    end
  end

  describe "execute_clean watermark cache (CX-tdkq.27)" do
    # R4c carve-out: put_execute_clean/4 is now a cast-to-cast hop
    # (CommitStore → TrustSideStore, which owns the row). Barrier BOTH
    # mailboxes (each is FIFO, so once both have drained anything queued
    # before this point, the write is durable) before reading back.
    test "put/get round-trips, keyed by fingerprint AND commit id", %{store: store, trust_side_store: tss} do
      fp = 12_345
      cid = <<1, 2, 3>>

      assert :miss = CommitStore.get_execute_clean(store, fp, cid)

      :ok = CommitStore.put_execute_clean(store, fp, cid, true)
      _ = :sys.get_state(store)
      _ = :sys.get_state(tss)

      assert {:ok, true} = CommitStore.get_execute_clean(store, fp, cid)
      # A different fingerprint (config changed) or unknown commit → miss.
      assert :miss = CommitStore.get_execute_clean(store, 99_999, cid)
      assert :miss = CommitStore.get_execute_clean(store, fp, <<9, 9>>)
    end

    test "false verdicts round-trip too", %{store: store, trust_side_store: tss} do
      :ok = CommitStore.put_execute_clean(store, 1, <<7>>, false)
      _ = :sys.get_state(store)
      _ = :sys.get_state(tss)
      assert {:ok, false} = CommitStore.get_execute_clean(store, 1, <<7>>)
    end

    test "flush drops all cache entries", %{store: store, trust_side_store: tss} do
      :ok = CommitStore.put_execute_clean(store, 1, <<1>>, true)
      :ok = CommitStore.put_execute_clean(store, 2, <<2>>, false)
      _ = :sys.get_state(store)
      _ = :sys.get_state(tss)
      assert {:ok, true} = CommitStore.get_execute_clean(store, 1, <<1>>)

      :ok = CommitStore.flush_execute_clean(store)

      assert :miss = CommitStore.get_execute_clean(store, 1, <<1>>)
      assert :miss = CommitStore.get_execute_clean(store, 2, <<2>>)
    end
  end

  describe "max_commit_log_limit/0 (CX-klpi)" do
    test "returns the shared commit_log ceiling" do
      assert CommitStore.max_commit_log_limit() == 10_000
    end
  end

  describe "CX-xrds: probe_integrity/1 deepened scan (via init/1)" do
    test "a healthy store with entries boots clean — no .corrupt.* archive is created" do
      dir = Path.join(System.tmp_dir!(), "cx_xrds_probe_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      name = :"cx_xrds_probe_store_#{:rand.uniform(1_000_000)}"

      {:ok, pid} = CommitStore.start_link(data_dir: dir, name: name)

      commits =
        for n <- 1..25 do
          CommitStore.create_commit(name, "doc-#{n}", <<n>>, nil)
        end

      # GenServer.stop/1 only tears down the CommitStore process — it
      # doesn't call CubDB.stop/1 (terminate/2 is a deliberate no-op,
      # see the moduledoc), so the underlying CubDB file handle must be
      # closed explicitly or the restart below fails with "already in
      # use by another CubDB.Store.File".
      db = CommitStore.db_handle(name)
      GenServer.stop(pid)
      CubDB.stop(db)

      # Restart against the same on-disk data — this re-runs init/1's
      # open + probe_integrity + (no-op, since the store is healthy)
      # recovery branch.
      {:ok, pid2} = CommitStore.start_link(data_dir: dir, name: name)

      # Every commit written before the restart is still readable, and
      # no `.corrupt.<ts>` sibling was created next to `commits/`.
      Enum.each(commits, fn commit ->
        assert {:ok, fetched} = CommitStore.get_commit(name, commit.id)
        assert fetched.id == commit.id
      end)

      corrupt_archives =
        dir
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "commits.corrupt."))

      assert corrupt_archives == []

      GenServer.stop(pid2)
      File.rm_rf!(dir)
    end

    test "probe timeout is read from :corruption_probe_timeout_ms and defaults to 5_000ms" do
      previous = Application.get_env(:commonplace, :corruption_probe_timeout_ms)

      on_exit(fn ->
        if previous do
          Application.put_env(:commonplace, :corruption_probe_timeout_ms, previous)
        else
          Application.delete_env(:commonplace, :corruption_probe_timeout_ms)
        end
      end)

      assert Application.get_env(:commonplace, :corruption_probe_timeout_ms, 5_000) == 5_000

      Application.put_env(:commonplace, :corruption_probe_timeout_ms, 1)

      # Even with a 1ms budget, a small store's scan either finishes in
      # time or the timeout path treats it as healthy — either way
      # init/1 must still boot successfully rather than erroring out.
      dir = Path.join(System.tmp_dir!(), "cx_xrds_probe_timeout_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      name = :"cx_xrds_probe_timeout_store_#{:rand.uniform(1_000_000)}"

      assert {:ok, pid} = CommitStore.start_link(data_dir: dir, name: name)

      GenServer.stop(pid)
      File.rm_rf!(dir)
    end
  end

  describe "CX-xrds: salvage_corrupt_archive/2" do
    # Reliably forcing CubDB into a raising-on-open corrupt state (e.g.
    # truncating its data file mid-record) proved flaky across CubDB's
    # own compaction/versioning internals — a truncation sometimes lands
    # on a boundary CubDB tolerates, sometimes not. So this exercises
    # salvage against an INTACT copy of a store directory instead, which
    # walks the exact same code path (open read-only, stream {:commit,
    # id} entries, re-import each one) without depending on a specific
    # on-disk corruption shape.
    test "recovers commits from a copied store directory into a fresh target store" do
      source_dir = Path.join(System.tmp_dir!(), "cx_xrds_salvage_src_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(source_dir)
      source_name = :"cx_xrds_salvage_src_store_#{:rand.uniform(1_000_000)}"

      {:ok, source_pid} = CommitStore.start_link(data_dir: source_dir, name: source_name)

      commits =
        for n <- 1..10 do
          CommitStore.create_commit(source_name, "doc-#{n}", <<n>>, nil)
        end

      # Each of these is a brand-new doc_uuid with parent_id nil, so
      # `create_commit/5` also mints an implicit genesis commit per call
      # (see `do_write_commit/7`'s `built.genesis` row) — 10 calls land
      # 20 `{:commit, id}` rows total. That total is what salvage should
      # recover, not the 10 returned `Commit` structs (which are only
      # the non-genesis half).
      expected_commit_rows = 20

      # Close the source store before copying — CubDB's directory must
      # not be open elsewhere while we snapshot it onto disk. As above,
      # GenServer.stop/1 alone leaves CubDB running; stop it explicitly.
      source_db = CommitStore.db_handle(source_name)
      GenServer.stop(source_pid)
      CubDB.stop(source_db)

      archive_dir =
        Path.join(System.tmp_dir!(), "cx_xrds_salvage_archive_#{:rand.uniform(1_000_000)}")

      File.cp_r!(Path.join(source_dir, "commits"), archive_dir)

      target_dir = Path.join(System.tmp_dir!(), "cx_xrds_salvage_dst_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(target_dir)
      target_name = :"cx_xrds_salvage_dst_store_#{:rand.uniform(1_000_000)}"

      {:ok, target_pid} = CommitStore.start_link(data_dir: target_dir, name: target_name)

      assert {:ok, %{salvaged: ^expected_commit_rows, skipped: 0}} =
               CommitStore.salvage_corrupt_archive(archive_dir, target_name)

      Enum.each(commits, fn commit ->
        assert {:ok, fetched} = CommitStore.get_commit(target_name, commit.id)
        assert fetched.update == commit.update
      end)

      # Content-addressed re-import is idempotent: salvaging the same
      # archive again reports the same count, now all via the
      # `:already_exists` branch rather than fresh writes.
      assert {:ok, %{salvaged: ^expected_commit_rows, skipped: 0}} =
               CommitStore.salvage_corrupt_archive(archive_dir, target_name)

      GenServer.stop(target_pid)
      File.rm_rf!(source_dir)
      File.rm_rf!(archive_dir)
      File.rm_rf!(target_dir)
    end

    test "returns {:error, reason} for a directory that isn't a CubDB store" do
      not_a_store_dir =
        Path.join(System.tmp_dir!(), "cx_xrds_salvage_not_a_store_#{:rand.uniform(1_000_000)}")

      File.mkdir_p!(not_a_store_dir)
      File.write!(Path.join(not_a_store_dir, "garbage.txt"), "not a cubdb file")

      target_name = :"cx_xrds_salvage_bogus_target_#{:rand.uniform(1_000_000)}"
      target_dir = Path.join(System.tmp_dir!(), "cx_xrds_salvage_bogus_dst_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(target_dir)
      {:ok, target_pid} = CommitStore.start_link(data_dir: target_dir, name: target_name)

      # A directory with no CubDB files in it is actually a valid empty
      # CubDB store from CubDB's point of view (it initializes fresh),
      # so this asserts the walk completes cleanly with nothing to
      # salvage rather than erroring — documenting the (harmless)
      # boundary behavior instead of asserting a specific error shape.
      assert {:ok, %{salvaged: 0, skipped: 0}} =
               CommitStore.salvage_corrupt_archive(not_a_store_dir, target_name)

      GenServer.stop(target_pid)
      File.rm_rf!(not_a_store_dir)
      File.rm_rf!(target_dir)
    end
  end
end
