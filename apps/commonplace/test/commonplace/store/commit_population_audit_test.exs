defmodule Commonplace.Store.CommitPopulationAuditTest do
  @moduledoc """
  World-B `:commit` full-population audit (plan #13407). Red-first: a healthy
  store is green; each of the four diffs is caught; a not-ready index and an
  empty corpus refuse to read as coverage. Two conditions plan raised are pinned
  here explicitly:

    * the fetch reads doc ownership from the `{:doc_commit}` KEY, never the
      `{:commit}` struct's `.doc_uuid` field (the fork/convergent-id trap,
      `commit.ex:52`) — proven with a commit whose struct field names a doc the
      index does NOT (plan #14154);
    * the scan is UNBOUNDED, so no CX-mg8s range-bound truncates the high end
      (plan #14155) — proven with an enumerator-level positive control: a key
      ABOVE the historical suspect bound must appear in the scan.

  Raw rows are manipulated through the same `:persistent_term` db handle
  `resolve_db/1` uses (as the coverage/backfill tests do), so no test-only
  production surface is added.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.{CommitPopulationAudit, CommitStore}

  setup do
    dir = Path.join(System.tmp_dir!(), "cpa_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"cpa_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  defp db(store), do: :persistent_term.get({CommitStore, :db, store})

  # A key strictly above the historical CX-mg8s suspect bound (`<<255>>`): a
  # 33-byte all-0xFF binary. A bounded scan sharing that bound would drop it.
  @above_suspect_bound :binary.copy(<<255>>, 33)

  # ── verdict/1 — the PURE go/no-go (no store) ──────────────────────────────
  describe "verdict/1" do
    defp pops(overrides) do
      base = %{
        p_doccommit: MapSet.new(["d1", "d2"]),
        p_latest: MapSet.new(["d1", "d2"]),
        ids_from_structs: MapSet.new(["c1", "c2"]),
        ids_from_doc_index: MapSet.new(["c1", "c2"]),
        index_ready: true
      }

      Map.merge(base, Map.new(overrides))
    end

    test "a consistent, non-empty, ready store is GREEN with every diff empty" do
      r = CommitPopulationAudit.verdict(pops([]))
      assert r.green
      refute r.vacuous
      assert r.orphaned_from_latest == []
      assert r.dangling_latest == []
      assert r.commits_missing_from_doc_index == []
      assert r.dangling_doc_index == []
      assert r.p_doccommit == 2 and r.p_latest == 2
    end

    test "orphaned_from_latest — a doc that OWNS commits but has no head pointer" do
      r = CommitPopulationAudit.verdict(pops(p_doccommit: MapSet.new(["d1", "d2", "orphan"])))
      assert r.orphaned_from_latest == ["orphan"]
      refute r.green
    end

    test "dangling_latest — a head pointer for a doc with no commit-index rows" do
      r = CommitPopulationAudit.verdict(pops(p_latest: MapSet.new(["d1", "d2", "ghost"])))
      assert r.dangling_latest == ["ghost"]
      refute r.green
    end

    test "commits_missing_from_doc_index — a commit object with no index row" do
      r = CommitPopulationAudit.verdict(pops(ids_from_structs: MapSet.new(["c1", "c2", "cX"])))
      assert r.commits_missing_from_doc_index == ["cX"]
      refute r.green
    end

    test "dangling_doc_index — an index row for a commit that does not exist" do
      r = CommitPopulationAudit.verdict(pops(ids_from_doc_index: MapSet.new(["c1", "c2", "cY"])))
      assert r.dangling_doc_index == ["cY"]
      refute r.green
    end

    test "an empty doc population is VACUOUS and NOT green, even with all diffs empty" do
      r = CommitPopulationAudit.verdict(pops(p_doccommit: MapSet.new(), p_latest: MapSet.new()))
      assert r.vacuous
      refute r.green
    end

    test "an empty commit-object set is VACUOUS and NOT green" do
      r =
        CommitPopulationAudit.verdict(
          pops(ids_from_structs: MapSet.new(), ids_from_doc_index: MapSet.new())
        )

      assert r.vacuous
      refute r.green
    end

    test "a NOT-READY doc_commit index forces green=false even when clean and non-empty" do
      r = CommitPopulationAudit.verdict(pops(index_ready: false))
      refute r.index_ready
      refute r.green
      # the diffs are computed but not authoritative over a half-built index
      assert r.orphaned_from_latest == []
    end
  end

  # ── fetch_populations/check — the store-touching integration ───────────────
  describe "against a real store" do
    # A "healthy" doc: genesis committed AND a head pointer set to it. NOTE:
    # `ensure_genesis` writes {:commit}+{:doc_commit} but NOT {:latest} (it calls
    # put_bare_commit_with_index, like import_commit) — a genesis-only doc has no
    # head. Real docs get {:latest} when a commit is chained; here we set it to
    # the genesis directly (a doc whose head IS its genesis) to build a
    # consistent doc without threading a Yelixer update through the test.
    defp genesis_doc(store, uuid) do
      {:ok, genesis} = CommitStore.ensure_genesis(store, uuid)
      CubDB.put(db(store), {:latest, uuid}, genesis.id)
      uuid
    end

    test "a healthy store built through the API is GREEN", %{store: store} do
      genesis_doc(store, "doc-alpha")
      genesis_doc(store, "doc-beta")

      r = CommitPopulationAudit.check(store)
      assert r.green, inspect(r)
      refute r.vacuous
      assert r.index_ready
      assert r.p_doccommit >= 2
      assert r.p_latest >= 2
    end

    test "deleting a doc's :latest makes it orphaned_from_latest (must-find)", %{store: store} do
      genesis_doc(store, "doc-alpha")
      genesis_doc(store, "doc-orphan")

      # The doc keeps its {:doc_commit} rows but loses its head pointer — exactly
      # the all_doc_uuids under-enumeration World-B exists to catch.
      CubDB.delete(db(store), {:latest, "doc-orphan"})

      r = CommitPopulationAudit.check(store)
      assert "doc-orphan" in r.orphaned_from_latest
      refute r.green
    end

    test "ENUMERATOR positive control: a key above the suspect bound appears in the scan",
         %{store: store} do
      genesis_doc(store, "doc-alpha")

      # A raw {:commit, id} whose id is a 33-byte all-0xFF binary — above the
      # CX-mg8s <<255>> bound. An unbounded scan must find it; a bounded scan
      # sharing that idiom would drop it silently (plan #14155). The value is
      # irrelevant to the scan (it reads the KEY), so a placeholder is fine.
      CubDB.put(db(store), {:commit, @above_suspect_bound}, :placeholder)

      pops = CommitStore.population_scan(store)

      assert MapSet.member?(pops.ids_from_structs, @above_suspect_bound),
             "the unbounded scan dropped a commit id above the historical range bound — a bounded scan would defeat both audit axes silently"

      # And it surfaces as a real finding (no matching {:doc_commit} row).
      r = CommitPopulationAudit.check(store)
      assert @above_suspect_bound in r.commits_missing_from_doc_index
      refute r.green
    end

    test "doc ownership comes from the {:doc_commit} KEY, not the struct .doc_uuid",
         %{store: store} do
      genesis_doc(store, "doc-alpha")

      # A commit whose STRUCT field names a SOURCE doc, indexed under a FORK doc.
      # This is the fork/convergent-id shape (commit.ex:52): the struct .doc_uuid
      # is a debug trace of the first writer, NOT ownership. The scan must credit
      # the KEY's doc (FORK), never the struct field (SOURCE).
      fork_id = :binary.copy(<<7>>, 32)
      CubDB.put(db(store), {:commit, fork_id}, %{doc_uuid: "SOURCE-must-not-appear"})
      CubDB.put(db(store), {:doc_commit, "FORK-owner", fork_id}, true)

      pops = CommitStore.population_scan(store)

      assert MapSet.member?(pops.p_doccommit, "FORK-owner"),
             "ownership was not taken from the {:doc_commit} key"

      refute MapSet.member?(pops.p_doccommit, "SOURCE-must-not-appear"),
             "ownership was wrongly taken from the struct's .doc_uuid field (the fork trap)"
    end

    test "a NOT-READY doc_commit index is reported, not silently scanned as empty",
         %{store: store} do
      genesis_doc(store, "doc-alpha")
      # Simulate an interrupted/absent index state.
      CubDB.put(db(store), {:doc_commit_index, :state}, {:rebuilding, "somecursor"})

      r = CommitPopulationAudit.check(store)
      refute r.index_ready
      refute r.green
    end
  end
end
