defmodule Commonplace.Store.DocCommitBackfillTest do
  @moduledoc """
  The (a) round's acceptance, red-first
  (`docs/plans/2026-08-21-doc-commit-backfill-brief.md`):

    1. the must-find fixture BOTH ARMS — a constructed fork-lineage doc
       (`:latest` at a foreign-struct commit, zero own `{:doc_commit}`
       rows) hard-fails the verified export and the [4] ancestry gate
       BEFORE the backfill, renders/passes AFTER;
    2. idempotency — the second run selects nothing and writes 0 rows;
    3. the defense survives — a genuinely-foreign pin is still refused
       after the fact-keyed switch, both arms adjacent;
    5. World-B convergence by SET-DIFFERENCE, in-suite —
       `dangling_pre \\ dangling_post == backfilled` and
       `dangling_post ∩ backfilled == ∅` (a count-delta can mask an
       exchange);
    6. readiness-gate hygiene — the run refuses a non-ready index and the
       state key is byte-identical across a successful run.

  Plus the named non-silent outcomes: a capped walk writes NOTHING and is
  reported by name; a head pointer at a missing commit is
  `head_commit_missing`, never a crash or a silent skip.

  The fork-lineage fixture is built the way the 2026-04-era fork built it:
  a real ancestor chain, then a bare `{:latest, fork}` pointer copied to
  the ancestor's head — no membership rows. Raw rows go through the same
  `db_handle/1` the exporter tamper tests use.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Document.ContentType
  alias Commonplace.GitBridge.Exporter
  alias Commonplace.Projection
  alias Commonplace.Store.{Chit, ChitAncestry, CommitPopulationAudit, CommitStore}
  alias Commonplace.Store.DocCommitBackfill
  alias Commonplace.Tree.{DocBuilder, Schema}

  setup do
    store_dir = Path.join(System.tmp_dir!(), "dc_bf_store_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(store_dir)
    name = :"dc_bf_store_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: store_dir, name: name})
    on_exit(fn -> File.rm_rf!(store_dir) end)
    %{store: name, store_dir: store_dir}
  end

  defp db(store), do: CommitStore.db_handle(store)

  defp text_update(name, content) do
    Yelixer.Doc.new()
    |> ContentType.create(:text, name)
    |> ContentType.insert_text(0, content)
    |> Yelixer.Encoding.encode_update()
  end

  # A real two-commit ancestor chain: genesis-with-content, then a chained edit.
  defp ancestor_chain(store, uuid) do
    c1 = CommitStore.create_commit(store, uuid, text_update("f.txt", "one"), nil)
    {:ok, doc1} = DocBuilder.reconstruct_doc(store, uuid, mint: false)
    doc2 = ContentType.insert_text(doc1, 3, " two")
    c2 = CommitStore.create_chained_commit(store, uuid, Yelixer.Encoding.encode_update(doc2))
    {c1, c2}
  end

  # The legacy fork shape: copy the head POINTER, leave every membership
  # row with the ancestor. Exactly the F2 / dangling_latest class.
  defp fork_by_pointer_copy(store, fork_uuid, ancestor_head_id) do
    CubDB.put(db(store), {:latest, fork_uuid}, ancestor_head_id)
    fork_uuid
  end

  # ── acceptance 1: the must-find fixture, both arms ──────────────────────

  test "projection: fork-lineage head refused BEFORE the backfill, renders AFTER",
       %{store: store} do
    {_c1, c2} = ancestor_chain(store, "u-anc")
    fork_by_pointer_copy(store, "u-fork", c2.id)

    # BEFORE: the fact-keyed check refuses — the head is not a member.
    assert {:error, {:commit_doc_mismatch, _, expected: "u-fork", got: "u-anc"}} =
             Projection.project_doc_at("u-fork", c2.id, store: store, head_path: :chain)

    assert {:ok, report} = DocCommitBackfill.run(store)
    assert report.backfilled == ["u-fork"]

    # AFTER: member proceeds, with an honest verdict — not a silent pass.
    assert {:ok, _bytes, verdict} =
             Projection.project_doc_at("u-fork", c2.id, store: store, head_path: :chain)

    assert match?({:corroborated, _}, verdict) or match?({:declared, _, _}, verdict)
  end

  test "verified export: fork-lineage doc under the mount HARD-FAILS before, renders after",
       %{store: store} do
    repo_dir = Path.join(System.tmp_dir!(), "dc_bf_repo_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(repo_dir)
    on_exit(fn -> File.rm_rf!(repo_dir) end)

    {_c1, c2} = ancestor_chain(store, "u-anc")
    fork_by_pointer_copy(store, "u-fork", c2.id)

    root = Schema.new_schema() |> Schema.add_file("fork.txt", "u-fork")
    CommitStore.create_commit(store, "u-root", Yelixer.Encoding.encode_update(root), nil)

    # BEFORE: the exporter's tamper class — hard-fail, never a clean tree.
    assert {:error, {:unverifiable_pin, offenders}} = Exporter.export("u-root", repo_dir, store)
    assert Enum.any?(offenders, fn {_path, uuid, _verdict} -> uuid == "u-fork" end)

    assert {:ok, _report} = DocCommitBackfill.run(store)

    # AFTER: renders the fork's (= ancestor-chain) content.
    assert {:ok, _result} = Exporter.export("u-root", repo_dir, store)
    assert File.read!(Path.join(repo_dir, "fork.txt")) == "one two"
  end

  test "[4] ancestry gate: pin on a fork-lineage doc refused before, passes after",
       %{store: store} do
    {_c1, c2} = ancestor_chain(store, "u-anc")
    fork_by_pointer_copy(store, "u-fork", c2.id)

    # check_against/3 is the gate's judgment (ChitMint calls it via
    # check/2 after a get_chit fetch this fixture doesn't need).
    child = %Chit{tree_pin: %{"u-fork" => c2.id}, parents: []}
    parent = %Chit{cid: "parent-cid", tree_pin: %{"u-fork" => c2.id}, parents: []}

    failures_before = ChitAncestry.check_against(store, child, parent)
    assert [%{doc: "u-fork", reason: :child_not_in_doc}] = failures_before

    assert {:ok, _} = DocCommitBackfill.run(store)

    assert ChitAncestry.check_against(store, child, parent) == []
  end

  # ── acceptance 2: idempotency ────────────────────────────────────────────

  test "second run selects nothing and writes 0 rows — and says so", %{store: store} do
    {c1, c2} = ancestor_chain(store, "u-anc")
    fork_by_pointer_copy(store, "u-fork", c2.id)

    assert {:ok, r1} = DocCommitBackfill.run(store)
    assert r1.selected == ["u-fork"]

    # The exact chain depth is timing-dependent (the ambient-signing hoist
    # may add a commit between the fixture's two), so assert the property:
    # every row written is now a membership row, both fixture commits
    # among them, and nothing was already present.
    assert r1.rows_written == MapSet.size(CommitStore.all_commit_ids_for_doc(store, "u-fork"))
    assert r1.rows_written >= 2
    assert r1.rows_already_present == 0
    assert CommitStore.doc_has_commit?(store, "u-fork", c1.id)
    assert CommitStore.doc_has_commit?(store, "u-fork", c2.id)

    assert {:ok, r2} = DocCommitBackfill.run(store)
    assert r2.selected == []
    assert r2.backfilled == []
    assert r2.rows_written == 0
  end

  # ── acceptance 3: the defense survives, both arms adjacent ──────────────

  test "after the switch: member proceeds, genuinely-foreign pin still refused",
       %{store: store} do
    {c1, c2} = ancestor_chain(store, "u-anc")
    fork_by_pointer_copy(store, "u-fork", c2.id)
    # An unrelated doc whose commit is on NOBODY's fork chain.
    foreign = CommitStore.create_commit(store, "u-other", text_update("o.txt", "x"), nil)

    assert {:ok, _} = DocCommitBackfill.run(store)

    # Arm 1: chain member (mid-chain, not just the head) proceeds.
    assert {:ok, _, _} =
             Projection.project_doc_at("u-fork", c1.id, store: store, head_path: :chain)

    # Arm 2: foreign commit — indexed, but under a doc that is not u-fork —
    # is refused by the same fact the member arm passed on.
    assert {:error, {:commit_doc_mismatch, _, expected: "u-fork", got: "u-other"}} =
             Projection.project_doc_at("u-fork", foreign.id, store: store, head_path: :chain)
  end

  # ── acceptance 5's comparison shape, in-suite ────────────────────────────

  test "World-B convergence by set-difference: dangling_pre \\ dangling_post == backfilled",
       %{store: store} do
    {_c1, c2} = ancestor_chain(store, "u-anc")
    fork_by_pointer_copy(store, "u-fork", c2.id)

    pre = CommitPopulationAudit.check(store)
    dangling_pre = MapSet.new(pre.dangling_latest)
    assert MapSet.member?(dangling_pre, "u-fork")

    assert {:ok, report} = DocCommitBackfill.run(store)
    processed = MapSet.new(report.backfilled)

    post = CommitPopulationAudit.check(store)
    dangling_post = MapSet.new(post.dangling_latest)

    # The membership-true comparison, not a count-delta.
    assert MapSet.difference(dangling_pre, dangling_post) == processed
    assert MapSet.intersection(dangling_post, processed) == MapSet.new()
  end

  # ── acceptance 6: readiness-gate hygiene ─────────────────────────────────

  test "run refuses a non-ready index — library and write verb both", %{store: store} do
    {_c1, c2} = ancestor_chain(store, "u-anc")
    fork_by_pointer_copy(store, "u-fork", c2.id)

    ready = CommitStore.doc_commit_index_ready()
    assert CommitStore.doc_commit_index_state(store) == ready

    CubDB.put(db(store), {:doc_commit_index, :state}, {:rebuilding, 1, nil})

    assert {:error, {:doc_commit_index_not_ready, {:rebuilding, 1, nil}}} =
             DocCommitBackfill.run(store)

    assert {:error, {:doc_commit_index_not_ready, _}} =
             CommitStore.put_backfilled_doc_commit_index_rows(store, "u-fork", [c2.id])

    # Restore and prove the successful run leaves the key byte-identical.
    CubDB.put(db(store), {:doc_commit_index, :state}, ready)
    assert {:ok, _} = DocCommitBackfill.run(store)
    assert CommitStore.doc_commit_index_state(store) == ready
  end

  # ── named non-silent outcomes ────────────────────────────────────────────

  test "a capped walk writes NOTHING and is reported by name", %{store: store} do
    # Chain of 3: genesis + two chained edits; budget 2 caps mid-chain.
    c1 = CommitStore.create_commit(store, "u-anc", text_update("f.txt", "one"), nil)
    {:ok, d1} = DocBuilder.reconstruct_doc(store, "u-anc", mint: false)
    d2 = ContentType.insert_text(d1, 3, " two")
    _c2 = CommitStore.create_chained_commit(store, "u-anc", Yelixer.Encoding.encode_update(d2))
    {:ok, d2r} = DocBuilder.reconstruct_doc(store, "u-anc", mint: false)
    d3 = ContentType.insert_text(d2r, 7, " three")
    c3 = CommitStore.create_chained_commit(store, "u-anc", Yelixer.Encoding.encode_update(d3))

    fork_by_pointer_copy(store, "u-fork", c3.id)

    assert {:ok, report} = DocCommitBackfill.run(store, walk_budget: 2)
    assert report.backfilled == []
    assert [%{doc: "u-fork", walked: 2, budget: 2}] = report.capped

    # All-or-nothing: zero rows landed, the doc is still fully dangling.
    refute CommitStore.doc_has_commit?(store, "u-fork", c3.id)
    refute CommitStore.doc_has_commit?(store, "u-fork", c1.id)

    # And the un-capped re-run repairs it — the cap is a budget fact, not a scar.
    assert {:ok, r2} = DocCommitBackfill.run(store)
    assert r2.backfilled == ["u-fork"]
    assert CommitStore.doc_has_commit?(store, "u-fork", c1.id)
  end

  test "a head pointer at a missing commit is a NAMED outcome, not a crash",
       %{store: store} do
    CubDB.put(db(store), {:latest, "u-ghost"}, "no-such-commit-id")

    assert {:ok, report} = DocCommitBackfill.run(store)
    assert report.head_commit_missing == ["u-ghost"]
    assert report.backfilled == []
  end

  # ── rebuild-completeness (plan #14426: the repair path was the vulnerability) ──

  test "an index REBUILD reproduces chain-derived membership instead of erasing it",
       %{store: store, store_dir: store_dir} do
    {c1, c2} = ancestor_chain(store, "u-anc")
    fork_by_pointer_copy(store, "u-fork", c2.id)

    assert {:ok, %{backfilled: ["u-fork"]}} = DocCommitBackfill.run(store)
    assert CommitStore.doc_has_commit?(store, "u-fork", c2.id)

    # Force a full rebuild: clear the readiness state, close the store,
    # reopen the same dir — ensure_doc_commit_index sees a non-ready state,
    # DELETES every {:doc_commit} row and re-derives. Without the
    # chain-membership pass, the fork's backfilled rows are erased here
    # and the doctrine violation is silently manufactured back.
    CubDB.delete(db(store), {:doc_commit_index, :state})
    stop_supervised!(CommitStore)

    name2 = :"dc_bf_reopen_#{:rand.uniform(1_000_000_000)}"

    start_supervised!(
      Supervisor.child_spec({CommitStore, data_dir: store_dir, name: name2}, id: :reopened_store)
    )

    assert CommitStore.doc_commit_index_state(name2) == CommitStore.doc_commit_index_ready()
    # Struct-derived rows rebuilt (the ancestor's own membership) …
    assert CommitStore.doc_has_commit?(name2, "u-anc", c1.id)
    assert CommitStore.doc_has_commit?(name2, "u-anc", c2.id)
    # … AND the chain-derived rows reproduced, not erased.
    assert CommitStore.doc_has_commit?(name2, "u-fork", c1.id)
    assert CommitStore.doc_has_commit?(name2, "u-fork", c2.id)
  end

  test "run_on_db: same cap honesty as run/2 — named outcome, zero rows",
       %{store: store} do
    {c1, c2} = ancestor_chain(store, "u-anc")
    fork_by_pointer_copy(store, "u-fork", c2.id)

    assert {:ok, report} = DocCommitBackfill.run_on_db(db(store), walk_budget: 1)
    assert [%{doc: "u-fork", walked: 1, budget: 1}] = report.capped
    assert report.backfilled == []
    refute CommitStore.doc_has_commit?(store, "u-fork", c2.id)
    refute CommitStore.doc_has_commit?(store, "u-fork", c1.id)
  end

  # ── chunked writes (pass-2 failure 2026-08-21: one giant put_multi blew ──
  # ── the call timeout; the fix must not break the per-doc resume story) ──

  test "write_chunks: genesis-first, head row in the LAST chunk, nothing lost" do
    ids_head_first = ["head", "c3", "c2", "c1", "genesis"]

    chunks = DocCommitBackfill.write_chunks(ids_head_first, 2)

    assert chunks == [["genesis", "c1"], ["c2", "c3"], ["head"]]
    assert List.last(List.last(chunks)) == "head"
    assert Enum.concat(chunks) == Enum.reverse(ids_head_first)
    assert Enum.all?(chunks, &(length(&1) <= 2))
    assert DocCommitBackfill.write_chunks([], 2) == []
  end

  test "a chain longer than put_chunk lands completely across calls", %{store: store} do
    # Chain of 3+ (hoist may add more); put_chunk: 1 forces one call per row.
    c1 = CommitStore.create_commit(store, "u-anc", text_update("f.txt", "one"), nil)
    {:ok, d1} = DocBuilder.reconstruct_doc(store, "u-anc", mint: false)
    d2 = ContentType.insert_text(d1, 3, " two")
    _c2 = CommitStore.create_chained_commit(store, "u-anc", Yelixer.Encoding.encode_update(d2))
    {:ok, d2r} = DocBuilder.reconstruct_doc(store, "u-anc", mint: false)
    d3 = ContentType.insert_text(d2r, 7, " three")
    c3 = CommitStore.create_chained_commit(store, "u-anc", Yelixer.Encoding.encode_update(d3))
    fork_by_pointer_copy(store, "u-fork", c3.id)

    assert {:ok, report} = DocCommitBackfill.run(store, put_chunk: 1)
    assert report.backfilled == ["u-fork"]
    assert report.rows_written == MapSet.size(CommitStore.all_commit_ids_for_doc(store, "u-fork"))
    assert report.rows_written >= 3
    assert CommitStore.doc_has_commit?(store, "u-fork", c1.id)
    assert CommitStore.doc_has_commit?(store, "u-fork", c3.id)
  end

  test "a headless partial write (crash between chunks) resumes cleanly", %{store: store} do
    {c1, c2} = ancestor_chain(store, "u-anc")
    fork_by_pointer_copy(store, "u-fork", c2.id)

    # Simulate a run that died after the genesis-side chunk landed but
    # BEFORE the head chunk: only non-head rows present.
    :ok = CommitStore.put_backfilled_doc_commit_index_rows(store, "u-fork", [c1.id])
    refute CommitStore.doc_has_commit?(store, "u-fork", c2.id)

    # Head row absent ⇒ still selected; the landed chunk is absorbed as
    # already-present, the rest written, and the doc completes.
    assert {:ok, report} = DocCommitBackfill.run(store)
    assert report.selected == ["u-fork"]
    assert report.backfilled == ["u-fork"]
    assert report.rows_already_present >= 1
    assert CommitStore.doc_has_commit?(store, "u-fork", c2.id)

    assert {:ok, r2} = DocCommitBackfill.run(store)
    assert r2.selected == []
  end

  # ── the cross-check and the rows themselves ──────────────────────────────

  test "selection coincides with the struct-F2 predicate on this corpus — and rows are exact",
       %{store: store} do
    {c1, c2} = ancestor_chain(store, "u-anc")
    fork_by_pointer_copy(store, "u-fork", c2.id)

    assert {:ok, report} = DocCommitBackfill.run(store)
    assert report.selected == ["u-fork"]
    assert report.struct_f2 == ["u-fork"]
    assert report.selection_vs_struct_f2_diff == %{selected_only: [], struct_f2_only: []}

    # Every chain id under the fork's key, value exactly true …
    assert CubDB.get(db(store), {:doc_commit, "u-fork", c1.id}) == true
    assert CubDB.get(db(store), {:doc_commit, "u-fork", c2.id}) == true
    # … and the ancestor's own membership untouched (many-to-many by design).
    assert CommitStore.doc_has_commit?(store, "u-anc", c1.id)
    assert CommitStore.doc_has_commit?(store, "u-anc", c2.id)
  end
end
