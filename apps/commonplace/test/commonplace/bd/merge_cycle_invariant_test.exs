defmodule Commonplace.Bd.MergeCycleInvariantTest do
  @moduledoc """
  ANSWERS: is the bd dependency-CYCLE invariant (enforced by
  `Commonplace.Bd.WriteGuard.check/5`'s cycle walk) preserved when two
  divergent lines of history each add ONE individually-legal `needs`
  edge and are then MERGED?

  `WriteGuard.check/5` is called from exactly two local write paths
  (`Commonplace.ViewActionDispatch` and `Commonplace.Bd.Migrate`) — see
  `Commonplace.Bd.WriteGuardImportBypassTest`'s moduledoc, written the
  same day, for the exhaustive grep. No merge code path
  (`Commonplace.Tree.Merge`, `Commonplace.Store.Merger`,
  `Commonplace.Store.CrossEpochMerge`) consults it at all. This test
  asks: does that gap matter in practice, or does the shape of a merge
  happen to avoid ever producing a cycle anyway?

  ## Merge mechanism chosen: `Commonplace.Tree.Merge.merge/3`, via
  `Commonplace.Tree.Fork.fork_directory/2`

  `Commonplace.Tree.Merge`'s own moduledoc draws the exact distinction
  this test needs: it is "Three-way merge of one branch's document
  tree into another's... walks a tree of separate documents related
  only by shared commit ancestry" — as opposed to
  `Commonplace.Store.Merger`, which "reconciles divergent CRDT
  namespaces/epochs of a *single* document." A bd ticket's dependency
  graph spans MULTIPLE documents (each ticket's `__issue.json` is its
  own leaf doc, linked by an in-JSON `needs[].ticket` id, not by CRDT
  identity) — "two divergent lines of history for a bd ticket doc"
  concretely means "a forked copy of the whole bd tree diverges from
  the original, then merges back," which is exactly
  `Commonplace.Tree.Fork.fork_directory/2` + `Commonplace.Tree.Merge.merge/3`.
  `apps/commonplace/test/commonplace/tree/merge_test.exs` demonstrates
  this exact fork -> diverge -> merge pattern for a plain text doc; this
  test reuses it for two bd tickets under one root.

  Critically, A's `__issue.json` and B's `__issue.json` are TWO
  DIFFERENT leaf documents. `Merge`'s recursive tree walk merges each
  leaf independently via a CRDT state-vector diff (`Merge`'s
  moduledoc: "Leaf merge is a CRDT diff"). Since line 1 only ever
  touches A's doc and line 2 only ever touches B's doc, there is no
  concurrent-edit CRDT conflict on either individual leaf — each
  leaf's diff-and-apply is clean, the same way `merge_test.exs`'s
  "merges content edits from source to target" case is clean. The
  interleaved-garbage risk the task description warns about (two
  concurrent FULL-BLOB rewrites racing on the SAME Yjs Text CRDT
  instance) does not arise here, because the two edits land on two
  different documents. That structural fact is itself part of the
  answer: the merge is clean at the CRDT layer, so if a cycle appears
  in the merged result, it is a genuine SEMANTIC cycle across two
  cleanly-merged documents — not a CRDT-encoding artifact.

  ## Isolation

  Own tmp-dir `CommitStore` and bd root — never the real `.commonplace/`
  or `dogfood-mud/` workspace, mirroring `WriteGuardImportBypassTest`'s
  setup.
  """
  use ExUnit.Case

  alias Commonplace.Bd.{Issue, WriteGuard}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{Fork, Merge, Schema}
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bd_merge_cycle_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_merge_cycle_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    root = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root, update, nil)

    %{store: store, root: root}
  end

  test "fork-diverge-merge: line 1 adds A->B, line 2 (fork) adds B->A, merge produces both edges",
       ctx do
    {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
    {:ok, b, _} = Issue.create(ctx.root, %{title: "B"}, ctx.store)

    a_needs_b = [%{"ticket" => b.id}]
    b_needs_a = [%{"ticket" => a.id}]

    # ------------------------------------------------------------------
    # POSITIVE CONTROL, first. Both A and B start with empty `needs` —
    # the common base both lines below diverge from.
    #
    #   (1a) A-needs-B is individually legal, given B has no needs.
    #   (1b) B-needs-A is individually legal, given A has no needs.
    #   (2)  Once A ALREADY needs B (the state line 1 will produce),
    #        adding B-needs-A on top of THAT state closes the cycle
    #        and WriteGuard refuses it. This is the exact combination
    #        the merge below will attempt to reconcile without ever
    #        calling WriteGuard at all.
    # ------------------------------------------------------------------
    assert :ok == WriteGuard.check(a, %{needs: a_needs_b}, ctx.root, ctx.store, allow: [])
    assert :ok == WriteGuard.check(b, %{needs: b_needs_a}, ctx.root, ctx.store, allow: [])

    # ------------------------------------------------------------------
    # THE DIVERGENCE. Fork the WHOLE bd root HERE, at the common base
    # (both A and B still empty), before either line's edit lands —
    # so both lines genuinely diverge from the same starting point,
    # matching the task's "divergent from the same base" requirement.
    # ------------------------------------------------------------------
    fork_root = Fork.fork_directory(ctx.root, ctx.store)

    # Line 1 (original root): A gains needs=[B].
    {:ok, a_line1} = Issue.update(ctx.root, a.id, %{needs: a_needs_b}, ctx.store)
    assert a_line1.needs == a_needs_b

    # POSITIVE CONTROL (2), against the now-live state on the original
    # root: once A ALREADY needs B (line 1's real, landed state, not a
    # synthetic struct), WriteGuard refuses adding B-needs-A on top of
    # it — the exact combination the merge below will reconcile
    # WITHOUT ever calling WriteGuard.
    assert {:error, reason} =
             WriteGuard.check(b, %{needs: b_needs_a}, ctx.root, ctx.store, allow: [])

    assert reason =~ "cycle"

    # Line 2 (the fork): B gains needs=[A]. Confirm the fork's copy of
    # A is still untouched (empty needs) before this edit lands — this
    # is what makes the edit individually legal on line 2.
    {:ok, a_on_fork_before} = Issue.show(fork_root, a.id, ctx.store)
    assert a_on_fork_before.needs == []

    assert :ok == WriteGuard.check(b, %{needs: b_needs_a}, fork_root, ctx.store, allow: [])

    {:ok, b_line2} = Issue.update(fork_root, b.id, %{needs: b_needs_a}, ctx.store)
    assert b_line2.needs == b_needs_a

    # ------------------------------------------------------------------
    # THE MERGE — fold the fork (source, carrying B->A) into the
    # original root (target, already carrying A->B). This is the only
    # merge call in the test: Commonplace.Tree.Merge.merge/3.
    # ------------------------------------------------------------------
    {:ok, report} = Merge.merge(fork_root, ctx.root, ctx.store)

    # ------------------------------------------------------------------
    # THE QUESTION, ANSWERED: reconstruct both tickets through the
    # ORDINARY read path (Bd.Issue.show) on the ORIGINAL root,
    # post-merge, and see what the merged state actually contains.
    # ------------------------------------------------------------------
    {:ok, a_after} = Issue.show(ctx.root, a.id, ctx.store)
    {:ok, b_after} = Issue.show(ctx.root, b.id, ctx.store)

    # Both edges landed, byte-for-byte, unmangled — no interleaved
    # garbage. Each ticket's __issue.json is a distinct leaf document,
    # so the two divergent edits never raced on the same CRDT text
    # instance; the merge cleanly picked up B's diff (the only new ops
    # since the fork's baseline) and applied it onto the target, which
    # already independently carried A's edit.
    assert a_after.needs == a_needs_b
    assert b_after.needs == b_needs_a

    # VERDICT: the merged ticket graph now contains BOTH A->B and
    # B->A — a dependency cycle. The "POSITIVE CONTROL (2)" assertion
    # above already proved WriteGuard.check/5 refuses exactly this
    # combination when asked to ADD the second edge on top of the
    # first. Asking WriteGuard about the post-merge state again here
    # is instructive in a different way: WriteGuard only gates the
    # DELTA of a write (does this change GROW `needs` with a new
    # edge?), not the document's resting state. Since a_after.needs
    # already equals a_needs_b, re-asking "is it legal to set A's
    # needs to a_needs_b" is a same-value no-op from WriteGuard's
    # point of view — no edge is being ADDED — so it answers :ok even
    # though the ticket graph it is looking at is already cyclic. The
    # merge produced a state WriteGuard would have refused to reach by
    # any single incremental write, but does not flag as invalid once
    # it is simply sitting there.
    assert :ok == WriteGuard.check(a_after, %{needs: a_needs_b}, ctx.root, ctx.store, allow: [])
    assert :ok == WriteGuard.check(b_after, %{needs: b_needs_a}, ctx.root, ctx.store, allow: [])

    # The merge itself reports no conflicts — Merge has no concept of
    # bd's ticket semantics, so it has no way to detect that a cycle
    # just formed. It considers this an ordinary, successful,
    # conflict-free merge.
    assert report.conflicts == []
  end
end
