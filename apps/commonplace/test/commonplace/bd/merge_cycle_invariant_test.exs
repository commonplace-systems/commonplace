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

  alias Commonplace.Bd.{Issue, Schemas, WriteGuard, Workspace}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{DocBuilder, Fork, Merge, Schema}
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

  describe "Q1 — post-close freeze under merge" do
    test "fork-diverge-merge: line 1 closes A, line 2 (fork) sets A in_progress while still open there — " <>
           "does the merge reopen A, or something else entirely?",
         ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      # ------------------------------------------------------------------
      # THE DIVERGENCE. Fork the whole bd root at the common base — A is
      # still "open" on both copies at this point. Mirrors the cycle
      # test's fork-before-either-edit structure exactly.
      # ------------------------------------------------------------------
      fork_root = Fork.fork_directory(ctx.root, ctx.store)

      # ------------------------------------------------------------------
      # POSITIVE CONTROL (a): line 1's edit (close A) is individually
      # legal on the original root, where A is still open. `allow:
      # [:status, :done_witness]` mirrors what `ticket_close`'s
      # dispatch-level gate call actually passes.
      # ------------------------------------------------------------------
      assert :ok ==
               WriteGuard.check(a, %{status: "closed", done_witness: []}, ctx.root, ctx.store,
                 allow: [:status, :done_witness]
               )

      # Land line 1 through the real close path: `Issue.close/4` is what
      # `ticket_close` calls after its own `WriteGuard.check` above —
      # same library call production uses, not a synthetic write.
      {:ok, a_closed} = Issue.close(ctx.root, a.id, [reason: "done"], ctx.store)
      assert a_closed.status == "closed"

      # Confirm the fork's copy of A is untouched (still open) before
      # line 2's edit lands on it — this is what makes line 2's edit
      # individually legal.
      {:ok, a_on_fork_before} = Issue.show(fork_root, a.id, ctx.store)
      assert a_on_fork_before.status == "open"

      # POSITIVE CONTROL (a), line 2: setting A's status to
      # "in_progress" is individually legal on the FORK, where A has
      # never closed.
      assert :ok ==
               WriteGuard.check(a_on_fork_before, %{status: "in_progress"}, fork_root, ctx.store,
                 allow: [:status]
               )

      # ------------------------------------------------------------------
      # POSITIVE CONTROL (b): the COMBINED state — line 2's edit
      # attempted AFTER line 1's close has landed, against the real
      # post-close `a_closed` struct — is exactly what `check_frozen`
      # refuses, REGARDLESS of the `allow` list (status IS in the allow
      # list here and it's still refused). This is the exact combination
      # the merge below will attempt to reconcile without ever calling
      # WriteGuard at all.
      # ------------------------------------------------------------------
      assert {:error, reason} =
               WriteGuard.check(a_closed, %{status: "in_progress"}, ctx.root, ctx.store,
                 allow: [:status]
               )

      assert reason == "field :status is frozen: ticket is closed (no reopen in v1)"

      # Land line 2 on the fork — A is still open there, so this is an
      # ordinary, individually-legal transition.
      {:ok, a_line2} = Issue.update(fork_root, a.id, %{status: "in_progress"}, ctx.store)
      assert a_line2.status == "in_progress"

      # ------------------------------------------------------------------
      # THE MERGE — fold the fork (source, carrying the in_progress
      # rewrite) into the original root (target, already closed).
      # ------------------------------------------------------------------
      {:ok, report} = Merge.merge(fork_root, ctx.root, ctx.store)

      # No conflict recorded — `Merge` has no concept of bd's freeze
      # semantics, so (same as the cycle test) it treats this as an
      # ordinary, clean, conflict-free leaf merge.
      assert report.conflicts == []

      # ------------------------------------------------------------------
      # THE QUESTION, ANSWERED. Read A back through the ORDINARY read
      # path (`Bd.Issue.show`) on the original root, post-merge.
      # ------------------------------------------------------------------
      read_result = Issue.show(ctx.root, a.id, ctx.store)

      # VERDICT: the merge does NOT reopen A in any readable sense —
      # there is no `%Issue{status: "in_progress"}` to observe. But the
      # reason is not that the freeze held semantically; it's that A's
      # `__issue.json` is ONE Yjs Text CRDT doc, and both lines'
      # `Schemas.write_text_doc/4` writes are FULL-BLOB rewrites (delete
      # the whole string, insert the whole new string — see
      # `schemas.ex`'s `write_text_doc/4`). Unlike the cycle test (A and
      # B are two DIFFERENT leaf docs, so their concurrent edits never
      # touch the same CRDT instance), here BOTH lines rewrite the SAME
      # leaf. The merge's leaf strategy (`Merge`'s moduledoc: "a state
      # vector diff... encoded as a Yjs update... applied to the
      # target") diffs the fork's ops since the pre-fork baseline and
      # applies them onto the target text, which has *already*
      # independently rewritten the same character range. Both full-text
      # inserts land at the same origin position (the now-fully-deleted
      # original text), and the Yjs CRDT resolves the concurrent
      # insertion order deterministically but WITHOUT interleaving
      # (Yelixer's `insert_text` inserts each string as a single
      # contiguous block, not char-by-char with cross-block origins) —
      # so the result is the FULL byte-for-byte concatenation of BOTH
      # complete JSON documents, back to back, not a character-level
      # interleave and not a semantic merge of either side's fields.
      assert {:error, %Jason.DecodeError{}} = read_result

      # Prove that concretely: fetch the raw underlying text and show it
      # is literally both complete JSON blobs concatenated — line 2's
      # "in_progress" rewrite in full, immediately followed by line 1's
      # "closed" rewrite in full. Neither side's JSON was truncated,
      # merged field-by-field, or interleaved character-by-character;
      # the whole-document CRDT merge is agnostic to JSON structure
      # entirely.
      {:ok, dir_uuid} = Workspace.issue_dir_uuid(ctx.root, a.id, ctx.store)
      {:ok, schema} = Schemas.load_dir_schema(dir_uuid, ctx.store)
      {:ok, entry} = Schema.get_entry(schema, Schemas.issue_filename())
      {:ok, doc} = DocBuilder.reconstruct_doc(ctx.store, entry.node_id)
      raw = ContentType.get_content(doc)

      assert raw =~ ~s("status":"in_progress")
      assert raw =~ ~s("status":"closed")
      assert {:error, %Jason.DecodeError{}} = Jason.decode(raw)

      # Which complete block lands first is NOT asserted here: across
      # repeated runs of this same test (distinct random UUIDs for the
      # store name / bd root / fork root each time, which feed
      # `WriterHand.for_doc/1`'s `phash2` and therefore each block's
      # effective client_id) the observed order flipped between runs —
      # once source-then-target, once target-then-source. The
      # concatenation is real and reproducible; ITS ORDER is a
      # CRDT-internal tie-break over per-run-random client_ids, not a
      # stable "source always wins position" rule, so asserting a fixed
      # order here would be asserting an implementation coincidence, not
      # a fact about the merge.

      # CONCLUSION: the post-close freeze is "merge-safe" only by
      # accident of corruption, not by design — no code path re-asserts
      # `check_frozen` during or after a merge (confirmed by the same
      # grep this file's moduledoc cites: WriteGuard is called ONLY from
      # `ViewActionDispatch` and `Bd.Migrate`, never from
      # `Commonplace.Tree.Merge`). If a status transition on the closed
      # side had happened to win the concatenation-order race with its
      # OWN valid trailing JSON object somehow taking precedence, or if
      # a future write path stopped doing full-blob rewrites in favor of
      # a structured YMap per field (this module's docs call that out as
      # a P3 target), the exact same "concurrent full-blob edit" pattern
      # would no longer merge into unparseable garbage — it would merge
      # into a well-formed, LWW or field-wise-merged Issue whose `status`
      # field could plausibly read "in_progress" even though the ticket
      # closed on another line. The freeze is not merge-aware; what
      # currently saves it from a semantic reopen is an implementation
      # detail (whole-document text storage) of a DIFFERENT layer, not
      # anything WriteGuard or Merge does on purpose.
    end
  end

  describe "Q2 — ref-typed shape checks under merge" do
    test "reasoned negative: two individually-legal `needs` lists cannot merge into an illegal " <>
           "combined shape, because there is no field-level merge to combine them",
         ctx do
      # This test demonstrates the MECHANISM that makes Q2 unbreakable
      # by construction, using the same fork/diverge/merge machinery as
      # Q1 — it does not contort a setup until something breaks; it
      # shows why nothing can.
      #
      # WriteGuard's ref-typed shape checks (`validate_needs_shape/2`,
      # `validate_done_witness/1`, `validate_claimed_by/1`) each judge
      # ONE COMPLETE FINAL VALUE of a field on a SINGLE write. For a
      # merge to produce a value WriteGuard would refuse, there would
      # need to be some merge-time operation that COMBINES two
      # individually-legal field values into a new, third value — e.g.
      # a semantic list-union of two `needs` arrays that individually
      # satisfy `@need_entry_keys`/shape rules but whose union somehow
      # doesn't (in fact no such illegal union exists for this
      # validator: it checks each entry independently, so a union of
      # two lists of valid entries is trivially still a list of valid
      # entries — Q2's shape checks are closed under set union by
      # construction, which is itself part of the answer).
      #
      # But Q1 already demonstrated, empirically, that no such
      # field-level union ever happens here at all: `__issue.json` is
      # ONE Yjs Text CRDT leaf holding the WHOLE serialized issue, and
      # `Schemas.write_text_doc/4` always does a full delete + full
      # re-insert of that entire string (never a per-field YMap write —
      # this module's own docs flag structured per-field YMap storage as
      # a P3, not-yet-built target). `Commonplace.Tree.Merge`'s leaf
      # strategy is a raw Yjs state-vector diff/apply over that text
      # blob — it has zero awareness of JSON, let alone of `needs` or
      # `done_witness` as semantic lists. Concurrent whole-document
      # rewrites merge into either (a) one side's content winning
      # outright (if the other's diff since baseline is empty) or (b)
      # both sides' COMPLETE byte blocks landing back-to-back, as Q1
      # showed — never a synthesized, field-wise-merged, spliced JSON
      # object with one field's value taken from one side and another
      # field's from the other. Case (b) fails `Jason.decode` outright
      # (Q1's assertion), so it never reaches WriteGuard's shape
      # validators at all — there is no parseable document for them to
      # examine, illegal or otherwise. Case (a) just reproduces
      # whichever side's value was already individually legal.
      #
      # So the only way to get a document that (i) parses as valid JSON
      # post-merge AND (ii) has an illegal `needs`/`done_witness`/
      # `claimed_by` shape is pure textual coincidence — two concurrent
      # inserts whose concatenated or interleaved bytes happen to spell
      # valid-but-wrong JSON. That is not "two legal values combining
      # into an illegal one" in the sense the task asks about (a
      # semantically meaningful merge outcome); it is indistinguishable
      # from bit-flip noise and isn't worth constructing — doing so
      # would be contorting a setup until it breaks, which the task
      # explicitly asks not to do.
      #
      # VERDICT: Q2 is unbreakable by merge in this codebase, for a
      # structural reason distinct from (and stronger than) "unlikely in
      # practice" — there is no field-level CRDT merge operation over
      # `needs`/`done_witness`/`claimed_by` AT ALL. The merge unit is
      # the whole document; WriteGuard's shape checks only ever run on
      # writes that go through `Issue.update`/`WriteGuard.check`
      # (`ViewActionDispatch`, `Bd.Migrate`), and Merge is not one of
      # those callers (same grep as Q1's moduledoc). The empirical
      # confirmation that whole-blob concurrent rewrites do NOT produce
      # a spliced/legal-looking document is Q1's raw-content assertions
      # above (full concatenation, `Jason.DecodeError`) — re-running
      # that same mechanism with two divergent `needs` edits instead of
      # two divergent `status` edits would demonstrate nothing new, so
      # this test states the reasoning instead of re-deriving the same
      # concatenation by construction.
      #
      # For completeness, confirm the individual-legality half directly
      # (positive control (a) from the task's own checklist), so this
      # verdict rests on a checked fact, not just prose: two divergent
      # single-entry `needs` lists are each individually legal (no
      # cycle, valid shape) against the shared empty-needs base.
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      {:ok, b, _} = Issue.create(ctx.root, %{title: "B"}, ctx.store)
      {:ok, c, _} = Issue.create(ctx.root, %{title: "C"}, ctx.store)

      needs_b = [%{"ticket" => b.id}]
      needs_c = [%{"ticket" => c.id}]

      assert :ok == WriteGuard.check(a, %{needs: needs_b}, ctx.root, ctx.store, allow: [])
      assert :ok == WriteGuard.check(a, %{needs: needs_c}, ctx.root, ctx.store, allow: [])

      # And their union is trivially still shape-legal — WriteGuard's
      # `validate_needs_shape/2` walks entries independently, so there
      # is no combination of two individually-valid `needs` lists that
      # produces an invalid one. (No cycle either: B and C have no
      # `needs` of their own.)
      assert :ok ==
               WriteGuard.check(a, %{needs: needs_b ++ needs_c}, ctx.root, ctx.store, allow: [])
    end
  end
end
