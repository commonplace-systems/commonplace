defmodule Commonplace.Store.AcceptedHeadsCoverageTest do
  @moduledoc """
  BUILD-1 §4 coverage check (plan #13772). The gate that must run GREEN
  before SiblingMerger's scan-fallback is removed. Red-first: a fully
  seam-maintained store is green; a doc whose row is CLEARED or whose row is
  PRESENT-BUT-STALE (lacks latest.id) is caught as missing — the two failure
  modes plan #13772 #3 named, with field discrimination (presence ≠
  validity) built into the second.

  Rows are manipulated through the same `:persistent_term` db handle
  `resolve_db/1` uses (as the backfill test does), so no test-only
  production surface is added.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.{AcceptedHeadsCoverage, Commit, CommitStore}
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "ah_coverage_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"ah_coverage_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  defp db(store), do: :persistent_term.get({CommitStore, :db, store})
  defp clear_index(store, doc), do: CubDB.delete(db(store), {:accepted_heads, doc})
  defp index_row(store, doc), do: CubDB.get(db(store), {:accepted_heads, doc})
  defp put_index(store, doc, set), do: CubDB.put(db(store), {:accepted_heads, doc}, set)

  defp linear_doc(store, uuid) do
    {:ok, _g} = CommitStore.ensure_genesis(store, uuid)
    d = Doc.new(client_id: 1)
    {d, _} = Doc.get_or_create_type(d, "t", :text)
    d = Text.insert(d, "t", 0, "hi")
    CommitStore.create_chained_commit(store, uuid, Encoding.encode_update(d), %{kind: :regular})
  end

  # genesis → C → L(:latest) with sibling R imported off C ⇒ heads {L, R}.
  defp sibling_doc(store, uuid) do
    {:ok, _g} = CommitStore.ensure_genesis(store, uuid)
    dc = Doc.new(client_id: 1)
    {dc, _} = Doc.get_or_create_type(dc, "t", :text)
    dc = Text.insert(dc, "t", 0, "abc")

    _ =
      CommitStore.create_chained_commit(store, uuid, Encoding.encode_update(dc), %{kind: :regular})

    {:ok, c} = CommitStore.snapshot(store, uuid)
    {:ok, cdoc} = Encoding.apply_update(Doc.new(), c.update)
    cu = Encoding.encode_update(cdoc)

    dl = Doc.new(client_id: 2)
    {dl, _} = Doc.get_or_create_type(dl, "t", :text)
    {:ok, dl} = Encoding.apply_update(dl, cu)
    dl = Text.insert(dl, "t", 0, "X")

    l =
      CommitStore.create_chained_commit(store, uuid, Encoding.encode_update(dl), %{kind: :regular})

    dr = Doc.new(client_id: 3)
    {dr, _} = Doc.get_or_create_type(dr, "t", :text)
    {:ok, dr} = Encoding.apply_update(dr, cu)
    dr = Text.insert(dr, "t", 3, "Y")

    r =
      Commit.new(uuid, Encoding.encode_update(dr), c.id, %{kind: :regular, snapshot_parent: c.id})

    :ok = CommitStore.import_commit(store, r, validator: fn _ -> :ok end)
    {l, r}
  end

  test "a fully seam-maintained store is GREEN (0 missing, denominator consistent)", %{
    store: store
  } do
    _ = linear_doc(store, "d1")
    _ = linear_doc(store, "d2")
    {_l, _r} = sibling_doc(store, "d3")

    report = AcceptedHeadsCoverage.check(store)

    assert report.missing == []
    assert report.examined == 3
    assert report.latest_key_count == 3
    assert report.denominator_consistent
    assert report.covered == 3
    assert report.green
  end

  # plan #13772 #3a: a doc whose accepted-head row was CLEARED (a legacy /
  # un-backfilled doc) is caught. Post-§4 this doc would silently stop
  # merging siblings; the check reports it BEFORE removal.
  test "a cleared row is caught as missing, and blocks green", %{store: store} do
    _ = linear_doc(store, "kept")
    {_l, _r} = sibling_doc(store, "wiped")
    clear_index(store, "wiped")
    assert index_row(store, "wiped") == nil

    report = AcceptedHeadsCoverage.check(store)

    assert "wiped" in report.missing
    refute "kept" in report.missing
    refute report.green
    # denominator is still consistent — the doc has :latest, it's the ROW
    # that's gone; the check catches it on the predicate, not the count.
    assert report.denominator_consistent
  end

  # plan #13772 #3b + field discrimination: a row that is PRESENT but does
  # NOT contain latest.id. A naive "has a row?" check passes it; the
  # membership predicate (SiblingMerger's :171 guard) catches it.
  test "a present-but-stale row (lacks latest.id) is caught — presence ≠ validity", %{
    store: store
  } do
    l = linear_doc(store, "stale")
    # Overwrite the maintained row with one that omits latest.id entirely.
    put_index(store, "stale", MapSet.new(["some-other-commit-id"]))

    # The row IS present (a presence-only check would pass this) ...
    assert index_row(store, "stale") != nil
    refute MapSet.member?(index_row(store, "stale"), l.id)

    report = AcceptedHeadsCoverage.check(store)

    # ... but the membership predicate catches it.
    assert "stale" in report.missing
    refute report.green
  end

  # The red-first discrimination stated as an assertion about the two
  # predicates: a presence-only check would MISS #3b; covered? does not.
  test "membership predicate strictly dominates a presence-only check on #3b", %{store: store} do
    l = linear_doc(store, "s")
    put_index(store, "s", MapSet.new(["not-latest"]))

    row = index_row(store, "s")
    presence_only_would_pass = row != nil
    membership_predicate = MapSet.member?(row, l.id)

    assert presence_only_would_pass, "a presence-only check WOULD accept the stale row"

    refute membership_predicate,
           "the membership predicate rejects it — this is the gap #3b probes"

    assert "s" in AcceptedHeadsCoverage.check(store).missing
  end

  test "an empty store is trivially green (nothing to cover)", %{store: store} do
    report = AcceptedHeadsCoverage.check(store)
    assert report.examined == 0
    assert report.latest_key_count == 0
    assert report.missing == []
    assert report.green
  end

  # plan #13772 #4: latest_key_count is an INDEPENDENT count of the
  # {:latest,_} keyspace. On a healthy store it equals `examined`; the field
  # exists so that an all_doc_uuids under-enumeration (a store-layer scan
  # bug — not synthetically injectable here without introducing that bug)
  # would surface as denominator_consistent == false rather than a clean
  # false zero.
  test "latest_key_count matches the examined denominator on a healthy store", %{store: store} do
    _ = linear_doc(store, "a")
    _ = linear_doc(store, "b")
    assert CommitStore.latest_key_count(store) == 2
    report = AcceptedHeadsCoverage.check(store)
    assert report.examined == report.latest_key_count
    assert report.denominator_consistent
  end
end
