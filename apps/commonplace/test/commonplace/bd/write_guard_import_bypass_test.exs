defmodule Commonplace.Bd.WriteGuardImportBypassTest do
  @moduledoc """
  PINS TODAY'S GAP (CX-hk1z): `Commonplace.Bd.WriteGuard.check/5` is
  called from exactly two places —
  `Commonplace.ViewActionDispatch` and `Commonplace.Bd.Migrate` — and
  both are LOCAL write paths. `Commonplace.Store.CommitStore.import_commit/3`
  (the front door for every commit that arrives from a peer — catch-up
  sync via `Commonplace.Sync.NodeSync`, and a live doc's
  `{:remote_commit, ...}` handler in `Commonplace.Document.Server`)
  never calls `WriteGuard.check/5` at all. Import only runs Gate A
  (`Commit.verify_id/1`) and Gate B (`Commonplace.Trust.authorized?/5`
  + the namespace/code-doc checks) — none of which know anything about
  bd's ticket semantics.

  Each test below is a matched pair:

    1. The LOCAL-path positive control: call `WriteGuard.check/5`
       directly with the violating `changes` and assert it returns
       `{:error, _}`. This proves the invariant is real and that the
       violating payload actually trips it.
    2. The import-path bypass: build the byte-identical violating
       ticket state as a `Commonplace.Store.Commit` (the same
       delete-then-insert-JSON shape `Commonplace.Bd.Schemas.write_text_doc/4`
       produces) and land it via `CommitStore.import_commit/3` — the
       same front door `Commonplace.Document.Server`'s
       `{:remote_commit, ...}` handler uses, followed by the same
       `CommitStore.set_latest/3` call that handler makes on a
       successful non-snapshot apply (see
       `Commonplace.Document.Server.apply_remote_commit/2`). Then
       reconstruct the ticket through the ordinary `Commonplace.Bd.Issue`
       read path and assert the violating state is PRESENT.

  When an import-side gate lands (the fix for CX-hk1z), step 2's
  assertion is the one that must be INVERTED — the import should
  instead be refused, and the reconstructed ticket should still show
  the pre-violation state.

  Isolation: every test builds its own tmp-dir `CommitStore` (never
  the real `.commonplace/` or `dogfood-mud/` workspace) and its own
  bd root/workspace, mirroring `Commonplace.Bd.WriteGuardTest`'s setup.
  """
  use ExUnit.Case

  alias Commonplace.Bd.{Issue, Schemas, Workspace, WriteGuard}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{Commit, CommitStore}
  alias Commonplace.Sync.MergeAdopter
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Yelixer.Encoding

  setup do
    dir =
      Path.join(System.tmp_dir!(), "cp_bd_write_guard_import_bypass_#{:rand.uniform(1_000_000)}")

    File.mkdir_p!(dir)
    store = :"commit_store_import_bypass_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    root = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root, update, nil)

    %{store: store, root: root}
  end

  # Lands `updated_issue` as the new full content of `id`'s
  # `__issue.json` doc via `CommitStore.import_commit/3` — bypassing
  # `Bd.Issue.update/5` (and therefore any `WriteGuard.check/5` call a
  # caller of `Bd.Issue.update/5` might have made) entirely. Mirrors
  # `Schemas.write_text_doc/4`'s delete-then-insert shape so the
  # resulting update is exactly what a legitimate local edit would
  # have produced — the only difference is which front door lands it.
  #
  # After `import_commit/3` succeeds, calls `CommitStore.set_latest/3`
  # to advance the doc's local head to the imported commit. This is
  # not a test-only shortcut: `Commonplace.Document.Server`'s
  # `{:remote_commit, ...}` handler (`apply_remote_commit/2`) does the
  # exact same two-step (import, then explicit `set_latest`) for every
  # non-snapshot remote commit that lands on a live doc — because
  # `import_commit/3` alone deliberately does NOT advance `:latest`
  # when a local head already exists (CX-m3x's clobber-safety), a
  # single first-time import would otherwise leave the change
  # persisted-but-invisible to normal reconstruction.
  defp land_via_import(store, root, id, updated_issue) do
    {:ok, dir_uuid} = Workspace.issue_dir_uuid(root, id, store)
    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.issue_filename())
    meta_uuid = entry.node_id

    {:ok, parent} = CommitStore.latest_commit(store, meta_uuid)
    {:ok, doc} = DocBuilder.reconstruct_doc(store, meta_uuid)

    current = ContentType.get_content(doc) || ""
    doc = if current != "", do: ContentType.delete_text(doc, 0, String.length(current)), else: doc
    new_json = Schemas.encode_issue(updated_issue)
    doc = ContentType.insert_text(doc, 0, new_json)
    update = Encoding.encode_update(doc)

    commit = Commit.new(meta_uuid, update, parent.id, %{})
    import_result = CommitStore.import_commit(store, commit)
    :ok = CommitStore.set_latest(store, meta_uuid, commit.id)

    {import_result, commit}
  end

  # Like `land_via_import/4`, but builds the violating commit as a
  # `kind: :merge` commit chained directly onto the doc's CURRENT
  # `:latest` (so it trivially dominates it — the walk in
  # `MergeAdopter.dominates?/3` finds `commit.parent_id == local_latest_id`
  # on its first step) and does NOT call `import_commit/3` or
  # `set_latest/3` itself. Returns the commit unlanded so the caller can
  # drive `import_commit/3` and `MergeAdopter.maybe_adopt/2` explicitly
  # and observe each step.
  defp build_violating_merge_commit(store, root, id, updated_issue) do
    {:ok, dir_uuid} = Workspace.issue_dir_uuid(root, id, store)
    {:ok, schema} = Schemas.load_dir_schema(dir_uuid, store)
    {:ok, entry} = Schema.get_entry(schema, Schemas.issue_filename())
    meta_uuid = entry.node_id

    {:ok, parent} = CommitStore.latest_commit(store, meta_uuid)
    {:ok, doc} = DocBuilder.reconstruct_doc(store, meta_uuid)

    current = ContentType.get_content(doc) || ""
    doc = if current != "", do: ContentType.delete_text(doc, 0, String.length(current)), else: doc
    new_json = Schemas.encode_issue(updated_issue)
    doc = ContentType.insert_text(doc, 0, new_json)
    update = Encoding.encode_update(doc)

    commit = Commit.new(meta_uuid, update, parent.id, %{kind: :merge})
    {commit, meta_uuid}
  end

  describe "cycle gate: local path refuses, import_commit admits (BYPASS — CX-hk1z)" do
    test "A needs B, B needs A: WriteGuard refuses locally, but the same B-needs-A state lands via import_commit",
         ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      {:ok, b, _} = Issue.create(ctx.root, %{title: "B"}, ctx.store)

      # Legitimate starting state: A needs B (local write, unenforced
      # library layer — same as WriteGuardTest's setup).
      {:ok, _a} = Issue.update(ctx.root, a.id, %{needs: [%{"ticket" => b.id}]}, ctx.store)

      cyclic_needs = [%{"ticket" => a.id}]

      # 1. Positive control: the local path refuses this edge — it
      # would close the A -> B -> A cycle.
      assert {:error, reason} =
               WriteGuard.check(b, %{needs: cyclic_needs}, ctx.root, ctx.store, allow: [])

      assert reason =~ "cycle"

      # 2. The bypass: land the byte-identical violating state (B's
      # needs = [A]) via import_commit, never touching WriteGuard.
      violating_b = %{b | needs: cyclic_needs}
      {import_result, _commit} = land_via_import(ctx.store, ctx.root, b.id, violating_b)
      assert import_result in [:ok, :already_exists]

      {:ok, b_after} = Issue.show(ctx.root, b.id, ctx.store)
      assert b_after.needs == cyclic_needs
    end
  end

  describe "post-close freeze: local path refuses, import_commit admits (BYPASS — CX-hk1z)" do
    test "reopening a closed ticket's status: WriteGuard refuses locally, but status=open lands via import_commit",
         ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      # Legitimate starting state: A is closed (direct library write —
      # Commonplace.Bd.* does no enforcement of its own per its
      # moduledoc; enforcement is WriteGuard's job).
      {:ok, closed} = Issue.update(ctx.root, a.id, %{status: "closed"}, ctx.store)
      assert closed.status == "closed"

      # 1. Positive control: the local path refuses reopening a closed
      # ticket, even with status explicitly allowed.
      assert {:error, reason} =
               WriteGuard.check(closed, %{status: "open"}, ctx.root, ctx.store, allow: [:status])

      assert reason =~ "frozen"

      # 2. The bypass: land status = "open" on the closed ticket via
      # import_commit, never touching WriteGuard.
      violating = %{closed | status: "open"}
      {import_result, _commit} = land_via_import(ctx.store, ctx.root, a.id, violating)
      assert import_result in [:ok, :already_exists]

      {:ok, a_after} = Issue.show(ctx.root, a.id, ctx.store)
      assert a_after.status == "open"
    end
  end

  describe "ref-typed field shape: local path refuses, import_commit admits (BYPASS — CX-hk1z)" do
    test "malformed done_witness (non-hex entry): WriteGuard refuses locally, but it lands via import_commit",
         ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      malformed_witness = ["not-hex!"]

      # 1. Positive control: the local path refuses a done_witness
      # entry that isn't a lowercase-hex (@-ref-shaped) string.
      assert {:error, reason} =
               WriteGuard.check(
                 a,
                 %{done_witness: malformed_witness},
                 ctx.root,
                 ctx.store,
                 allow: [:done_witness]
               )

      assert reason =~ "hex"

      # 2. The bypass: land the malformed done_witness via
      # import_commit, never touching WriteGuard's ref-type check.
      violating = %{a | done_witness: malformed_witness}
      {import_result, _commit} = land_via_import(ctx.store, ctx.root, a.id, violating)
      assert import_result in [:ok, :already_exists]

      {:ok, a_after} = Issue.show(ctx.root, a.id, ctx.store)
      assert a_after.done_witness == malformed_witness
    end
  end

  describe "MergeAdopter and the dormancy barrier (CX-hk1z)" do
    test "MergeAdopter promotes an unchecked violating commit past the dormancy barrier (CX-hk1z)",
         ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      {:ok, b, _} = Issue.create(ctx.root, %{title: "B"}, ctx.store)

      # Legitimate starting state: A needs B (same setup as the cycle
      # bypass test above).
      {:ok, _a} = Issue.update(ctx.root, a.id, %{needs: [%{"ticket" => b.id}]}, ctx.store)

      cyclic_needs = [%{"ticket" => a.id}]

      # 1. Positive control: the local path refuses this edge for the
      # same reason as the cycle bypass test.
      assert {:error, reason} =
               WriteGuard.check(b, %{needs: cyclic_needs}, ctx.root, ctx.store, allow: [])

      assert reason =~ "cycle"

      # 2. Build the byte-identical violating state (B's needs = [A])
      # as a commit LABELLED `metadata: %{kind: :merge}` and chained
      # directly onto B's meta doc's current `:latest` — so it
      # trivially dominates the local head. Land it via
      # `import_commit/3` only. Do NOT call `set_latest/3` — the whole
      # point is to see whether `MergeAdopter.maybe_adopt/2` will do
      # that instead, unchecked.
      violating_b = %{b | needs: cyclic_needs}

      {merge_commit, _meta_uuid} =
        build_violating_merge_commit(ctx.store, ctx.root, b.id, violating_b)

      import_result = CommitStore.import_commit(ctx.store, merge_commit)
      assert import_result in [:ok, :already_exists]

      # 3. Control: dormancy holds after a bare import_commit — the
      # merge-labelled commit is persisted but `:latest` still points
      # at the pre-violation commit, so ordinary reconstruction shows
      # the clean state.
      {:ok, b_dormant} = Issue.show(ctx.root, b.id, ctx.store)
      assert b_dormant.needs == []

      # 4. The question: does MergeAdopter.maybe_adopt/2 promote this
      # unchecked commit to :latest purely because it is labelled
      # kind: :merge and dominates the local head?
      outcome = MergeAdopter.maybe_adopt(ctx.store, merge_commit)
      assert outcome == :adopted

      # 5. What actually happens to the reconstructed state once
      # adoption fires: the cyclic, WriteGuard-refused state is now
      # the live ticket state.
      {:ok, b_after} = Issue.show(ctx.root, b.id, ctx.store)
      assert b_after.needs == cyclic_needs
    end
  end
end
