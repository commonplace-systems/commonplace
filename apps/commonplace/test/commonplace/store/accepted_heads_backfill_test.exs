defmodule Commonplace.Store.AcceptedHeadsBackfillTest do
  @moduledoc """
  BUILD-1 §3: the accepted-head index backfill. Verifies it fills missing
  rows (legacy docs), is idempotent on seam-maintained docs, resumes past a
  recorded cursor (③), marks `:ready` only on a complete pass, reports the
  observed-max working set (⑦), and records no antichain violation on valid
  data.

  Legacy/un-indexed docs are simulated by deleting the `{:accepted_heads,_}`
  row after building — reaching the db through the same `:persistent_term`
  handle `resolve_db/1` uses, so no test-only production surface is added.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.{AcceptedHeads, AcceptedHeadsBackfill, Commit, CommitStore}
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "ah_backfill_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"ah_backfill_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  defp db(store), do: :persistent_term.get({CommitStore, :db, store})
  defp clear_index(store, doc), do: CubDB.delete(db(store), {:accepted_heads, doc})
  defp index_row(store, doc), do: CubDB.get(db(store), {:accepted_heads, doc})

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

  test "fills a legacy doc's missing index row, matching the scan oracle", %{store: store} do
    uuid = "legacy-sibling"
    {l, r} = sibling_doc(store, uuid)

    # Simulate a legacy doc: the seam maintained the row; wipe it.
    clear_index(store, uuid)
    assert index_row(store, uuid) == nil

    report = AcceptedHeadsBackfill.run(store)

    assert index_row(store, uuid) == MapSet.new([l.id, r.id])
    assert CommitStore.accepted_heads_indexed(store, uuid) == AcceptedHeads.of(store, uuid)
    assert report.docs_written >= 1
  end

  test "is idempotent on seam-maintained docs (writes match the oracle)", %{store: store} do
    a = "lin"
    b = "sib"
    _ = linear_doc(store, a)
    {_l, _r} = sibling_doc(store, b)

    before_a = index_row(store, a)
    before_b = index_row(store, b)
    _ = AcceptedHeadsBackfill.run(store)

    assert index_row(store, a) == before_a
    assert index_row(store, b) == before_b
    assert CommitStore.accepted_heads_indexed(store, a) == AcceptedHeads.of(store, a)
    assert CommitStore.accepted_heads_indexed(store, b) == AcceptedHeads.of(store, b)
  end

  test "marks :ready only on a complete pass", %{store: store} do
    _ = linear_doc(store, "d")
    assert CommitStore.accepted_head_backfill_state(store) == :absent
    _ = AcceptedHeadsBackfill.run(store)

    assert CommitStore.accepted_head_backfill_state(store) ==
             CommitStore.accepted_head_index_ready()
  end

  test "resumes past a recorded cursor, not redoing docs before it (③)", %{store: store} do
    # Three docs; sorted order is deterministic on the uuids.
    _ = linear_doc(store, "d1")
    _ = linear_doc(store, "d2")
    _ = linear_doc(store, "d3")
    [first, second, third] = Enum.sort(["d1", "d2", "d3"])

    # Simulate a kill after `first` was written: its row stands; the later
    # two were not reached, so wipe them; cursor sits at `first`.
    clear_index(store, second)
    clear_index(store, third)
    kept_first = index_row(store, first)
    :ok = CommitStore.put_backfilled_accepted_heads(store, [], {:rebuilding, first})

    _ = AcceptedHeadsBackfill.run(store)

    # `first` (<= cursor) was skipped — its row is untouched, not re-derived.
    assert index_row(store, first) == kept_first
    # the later two (> cursor) were filled, and the pass completed.
    assert index_row(store, second) != nil
    assert index_row(store, third) != nil

    assert CommitStore.accepted_head_backfill_state(store) ==
             CommitStore.accepted_head_index_ready()
  end

  test "reports the observed-max working set (⑦) out of the run", %{store: store} do
    _ = sibling_doc(store, "with-commits")
    report = AcceptedHeadsBackfill.run(store)
    assert report.working_set_max > 0
    assert report.violations == []
    assert report.terminal_state == CommitStore.accepted_head_index_ready()
  end

  # commonplace-coder #13593 #2 (the merge-hold): a doc whose frontier fails
  # the antichain verify is RECORDED and NOT written — and the run must NOT
  # reach :ready, or §4 would drop the fallback and that doc's siblings go
  # silently invisible. The real verify only fires on of/2 regression /
  # corruption, so the violation is injected to exercise the handling.
  test "a doc failing the verify is recorded, not written, and blocks :ready", %{store: store} do
    {_l, _r} = sibling_doc(store, "viol")
    clear_index(store, "viol")

    injected = fn _set, _store, doc ->
      if doc == "viol", do: {:violation, %{doc_uuid: doc, reason: :injected}}, else: :ok
    end

    report = AcceptedHeadsBackfill.run(store, verify_fn: injected)

    assert length(report.violations) == 1
    assert index_row(store, "viol") == nil, "a violating doc must NOT be written"
    assert report.terminal_state == {:completed_with_violations, 1}
    refute report.terminal_state == CommitStore.accepted_head_index_ready()

    # §4's precondition (state == :ready) is therefore NOT met — the
    # scan-fallback must stay, so the doc's siblings remain reachable.
    refute CommitStore.accepted_head_backfill_state(store) ==
             CommitStore.accepted_head_index_ready()
  end

  # commonplace-coder #13593 #1 + the brief's named F5 fixture: 2.2% of docs
  # carry :latest at a FOREIGN doc_uuid (fork-lineage class). The backfill
  # must HANDLE them, not discover them mid-run. of/2 derives a single-head
  # frontier for such a doc (its own doc-commit index is empty, so no
  # siblings), which is a valid antichain — written, no violation, :ready.
  test "F5: a doc with a FOREIGN-doc_uuid :latest is handled (fork-lineage class)", %{
    store: store
  } do
    e = linear_doc(store, "E")
    # Point a different doc's :latest at E's commit — the F5 shape.
    CubDB.put(db(store), {:latest, "f5-doc"}, e.id)

    report = AcceptedHeadsBackfill.run(store)

    # Handled, not crashed: the F5 doc's frontier is derived and written as a
    # valid antichain, so no violation and the pass reaches :ready.
    assert index_row(store, "f5-doc") == MapSet.new([e.id])
    assert report.violations == []
    assert report.terminal_state == CommitStore.accepted_head_index_ready()

    assert CommitStore.accepted_heads_indexed(store, "f5-doc") ==
             AcceptedHeads.of(store, "f5-doc")
  end
end
