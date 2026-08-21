defmodule Commonplace.Store.ChitAncestryTest do
  @moduledoc """
  The chit ancestry invariant (`Commonplace.Store.ChitAncestry`) and its
  mint gate (`ChitMint.commit/5`): descent-or-equal over the pin
  intersection, membership by the `{:doc_commit}` fact (never the
  struct's `.doc_uuid` trace), cap honesty as a named non-answer, and
  refusal-before-store at the mint point. Red-first throughout — every
  pass arm carries its refuting arm.

  async: false for the same reason as ChitTest: the mint-gate tests
  drive the reflog checkpoint's idempotency cursor, which lives in
  GLOBAL named ETS tables shared across the VM.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.ContentType

  alias Commonplace.Store.{
    Chit,
    ChitAncestry,
    ChitBranchRef,
    ChitMint,
    CommitStore,
    CommitStoreClient
  }

  alias Commonplace.Tree.{DocBuilder, Schema}

  setup do
    store_dir = Path.join(System.tmp_dir!(), "cp_chit_anc_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(store_dir)
    store_name = :"chit_anc_store_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: store_dir, name: store_name})

    on_exit(fn -> File.rm_rf!(store_dir) end)

    %{store: store_name}
  end

  # --- helpers (chit_test.exs's fixture idiom) ---

  defp sha(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term))

  defp text_update(name, content) do
    Yelixer.Doc.new()
    |> ContentType.create(:text, name)
    |> ContentType.insert_text(0, content)
    |> Yelixer.Encoding.encode_update()
  end

  defp create_text(store, uuid, name, content) do
    CommitStore.create_commit(store, uuid, text_update(name, content), nil)
  end

  defp edit_text(store, uuid, at, insert) do
    {:ok, doc} = DocBuilder.reconstruct_doc(store, uuid, mint: false)
    doc = ContentType.insert_text(doc, at, insert)
    CommitStoreClient.create_chained_commit(store, uuid, Yelixer.Encoding.encode_update(doc))
  end

  # A doc with the chain c1 -> c2 -> c3; returns {uuid, [c1, c2, c3]}.
  defp chain3(store) do
    uuid = UUID.uuid4()
    c1 = create_text(store, uuid, "d.txt", "one")
    c2 = edit_text(store, uuid, 3, " two")
    c3 = edit_text(store, uuid, 7, " three")
    {uuid, [c1, c2, c3]}
  end

  defp chit(pin, parents, message), do: Chit.new(pin, parents, nil, message, 1_000)

  defp stored_chit(store, pin, parents, message) do
    c = chit(pin, parents, message)
    {:ok, _} = CommitStoreClient.store_chit(store, c)
    c
  end

  # A verdict row with every fact healthy; tests override the fact under
  # test so each failure reason is provoked in isolation.
  defp ok_row(overrides \\ %{}) do
    Map.merge(
      %{
        doc: "doc-1",
        child_commit: sha("child"),
        parent_commit: sha("parent"),
        child_member: true,
        parent_member: true,
        descent: :descends
      },
      overrides
    )
  end

  # The same small real tree ChitTest mints against.
  defp build_tree(store) do
    a_uuid = UUID.uuid4()
    b_uuid = UUID.uuid4()
    root_uuid = UUID.uuid4()

    create_text(store, a_uuid, "a.txt", "alpha")
    create_text(store, b_uuid, "b.txt", "beta")

    root =
      Schema.new_schema()
      |> Schema.add_file("a.txt", a_uuid)
      |> Schema.add_file("b.txt", b_uuid)

    CommitStore.create_commit(store, root_uuid, Yelixer.Encoding.encode_update(root), nil)

    %{root: root_uuid, a: a_uuid, b: b_uuid}
  end

  # --- [1] descent, both arms ---

  test "descent passes; the reversed claim is caught naming the doc; equal passes", %{
    store: store
  } do
    {uuid, [c1, c2, c3]} = chain3(store)

    parent = stored_chit(store, %{uuid => c1.id}, [], "parent moment")
    child = chit(%{uuid => c3.id}, [parent.cid], "child moment")

    # pass arm: c3 descends from c1
    assert [%{descent: :descends, child_member: true, parent_member: true}] =
             ChitAncestry.fetch(store, child, parent)

    assert ChitAncestry.check(store, child) == :ok

    # refuting arm: the REVERSED claim (child pins the ancestor) is caught
    parent_rev = stored_chit(store, %{uuid => c3.id}, [], "reversed parent")
    child_rev = chit(%{uuid => c1.id}, [parent_rev.cid], "reversed child")

    assert {:error, {:ancestry_violation, [failure]}} = ChitAncestry.check(store, child_rev)
    assert failure.doc == uuid
    assert failure.reason == :not_ancestor
    assert failure.child_commit == c1.id
    assert failure.parent_commit == c3.id
    assert failure.parent == parent_rev.cid

    # equal arm: both pin c2 — :equal, no walk needed
    parent_eq = stored_chit(store, %{uuid => c2.id}, [], "eq parent")
    child_eq = chit(%{uuid => c2.id}, [parent_eq.cid], "eq child")

    assert [%{descent: :equal}] = ChitAncestry.fetch(store, child_eq, parent_eq)
    assert ChitAncestry.check(store, child_eq) == :ok
  end

  # --- [2] intersection only ---

  test "only the pin INTERSECTION is judged: additions and deletions are out", %{store: store} do
    {uuid, [c1, _c2, c3]} = chain3(store)

    # Both non-intersection docs are pinned to commits that WOULD fail
    # if checked (no such commit rows exist anywhere) — so a pass here
    # proves they were never fetched, not that they happened to pass.
    added_doc = UUID.uuid4()
    removed_doc = UUID.uuid4()

    parent =
      stored_chit(
        store,
        %{uuid => c1.id, removed_doc => sha("would fail if checked")},
        [],
        "parent with a doc the child dropped"
      )

    child =
      chit(
        %{uuid => c3.id, added_doc => sha("would also fail if checked")},
        [parent.cid],
        "child with a doc the parent lacked"
      )

    rows = ChitAncestry.fetch(store, child, parent)
    assert [%{doc: ^uuid}] = rows
    assert ChitAncestry.verdict(rows) == :ok
    assert ChitAncestry.check(store, child) == :ok
  end

  # --- [3] fork-lineage must-find: membership by fact, not struct field ---

  test "membership is the {:doc_commit} fact — a foreign struct .doc_uuid does not misclassify",
       %{store: store} do
    # The World-B trap fixture (commit_reader_test.exs): a chain whose
    # struct `.doc_uuid` names doc-A throughout, while the authoritative
    # `{:doc_commit}` index also assigns both commits to doc-B (what an
    # imported / fork-lineage commit looks like — F2, 1.9% live).
    cA1 = create_text(store, "doc-A", "a.txt", "shared")
    cA2 = edit_text(store, "doc-A", 6, " more")
    assert cA1.doc_uuid == "doc-A"
    assert cA2.doc_uuid == "doc-A"

    db = CommitStore.db_handle(store)
    CubDB.put(db, {:doc_commit, "doc-B", cA1.id}, true)
    CubDB.put(db, {:doc_commit, "doc-B", cA2.id}, true)

    parent = stored_chit(store, %{"doc-B" => cA1.id}, [], "parent pins doc-B")
    child = chit(%{"doc-B" => cA2.id}, [parent.cid], "child pins doc-B")

    # A naive implementation reading struct.doc_uuid would see "doc-A"
    # for both pins and misclassify them as out of doc-B. The checker
    # judges by the index fact: both members, and the walk descends.
    assert [%{child_member: true, parent_member: true, descent: :descends}] =
             ChitAncestry.fetch(store, child, parent)

    assert ChitAncestry.check(store, child) == :ok

    # refuting arm: a doc that does NOT index these commits fails on the
    # membership fact — same commits, different fact, opposite verdict.
    parent_c = stored_chit(store, %{"doc-C" => cA1.id}, [], "doc-C parent")
    child_c = chit(%{"doc-C" => cA2.id}, [parent_c.cid], "doc-C child")

    assert {:error, {:ancestry_violation, [%{reason: :child_not_in_doc}]}} =
             ChitAncestry.check(store, child_c)
  end

  # --- [4] merge chit: each parent judged independently ---

  test "a merge chit passes when both parents hold, and a failure names WHICH parent", %{
    store: store
  } do
    {d, [d1, d2, _d3]} = chain3(store)
    {e, [e1, e2, _e3]} = chain3(store)

    pa = stored_chit(store, %{d => d1.id}, [], "parent A")
    pb = stored_chit(store, %{e => e2.id}, [], "parent B")

    # pass arm: descends from A on d, descends-or-equals B on e
    good = chit(%{d => d2.id, e => e2.id}, [pa.cid, pb.cid], "good merge")
    assert ChitAncestry.check(store, good) == :ok

    # refuting arm: only B's claim is violated (child pins e1, an
    # ANCESTOR of B's e2) — the failure names parent B, and only B
    bad = chit(%{d => d2.id, e => e1.id}, [pa.cid, pb.cid], "bad merge")

    assert {:error, {:ancestry_violation, failures}} = ChitAncestry.check(store, bad)
    assert [%{parent: parent_cid, doc: ^e, reason: :not_ancestor}] = failures
    assert parent_cid == pb.cid
  end

  # --- [5] missing parent chit ---

  test "a parent cid with no stored chit is a named failure, not a pass", %{store: store} do
    {uuid, [c1 | _]} = chain3(store)
    ghost = sha("never stored")

    child = chit(%{uuid => c1.id}, [ghost], "orphan claim")

    assert {:error, {:ancestry_violation, [failure]}} = ChitAncestry.check(store, child)
    assert failure.reason == {:parent_chit_missing, ghost}
    assert failure.parent == ghost
  end

  # --- [6] pure verdict unit tests ---

  test "verdict/1 is pure: every reason exercised on hand-built rows" do
    # empty domain = no claim over any shared doc = vacuously :ok
    assert ChitAncestry.verdict([]) == :ok

    # pass rows: both membership facts true, descent in [:equal, :descends]
    assert ChitAncestry.verdict([ok_row(), ok_row(%{descent: :equal})]) == :ok

    # each failure reason, in isolation
    assert {:error, [%{reason: :child_not_in_doc}]} =
             ChitAncestry.verdict([ok_row(%{child_member: false})])

    assert {:error, [%{reason: :parent_not_in_doc}]} =
             ChitAncestry.verdict([ok_row(%{parent_member: false})])

    assert {:error, [%{reason: :not_ancestor}]} =
             ChitAncestry.verdict([ok_row(%{descent: :not_ancestor})])

    # cap honesty: an exhausted walk is a NAMED failure, never a pass
    assert {:error, [%{reason: {:indeterminate, :walk_capped}}]} =
             ChitAncestry.verdict([ok_row(%{descent: {:indeterminate, :walk_capped}})])

    # membership is judged before descent: a non-member pin's descent
    # fact is moot, so the reason names the membership failure
    assert {:error, [%{reason: :child_not_in_doc}]} =
             ChitAncestry.verdict([ok_row(%{child_member: false, descent: :not_ancestor})])

    # a mixed list fails on exactly the failing rows
    assert {:error, failures} =
             ChitAncestry.verdict([ok_row(), ok_row(%{doc: "bad", descent: :not_ancestor})])

    assert [%{doc: "bad", reason: :not_ancestor}] = failures
  end

  # --- cap honesty against a real walk ---

  test "a walk that exhausts the budget is {:indeterminate, :walk_capped}, surfaced as a failure",
       %{store: store} do
    uuid = UUID.uuid4()
    c1 = create_text(store, uuid, "deep.txt", "0")
    _commits = for n <- 1..5, do: edit_text(store, uuid, 0, "#{n}")
    {:ok, head} = CommitStoreClient.latest_commit(store, uuid)

    # Shrink the shared walk ceiling below the chain length so the cap
    # branch is reachable with a test-sized fixture (the same overridable
    # knob CX-ggdv added for exactly this kind of test). Set AFTER the
    # fixture is built — edit_text's doc reconstruction walks the same
    # capped APIs and must not be truncated while building.
    Application.put_env(:commonplace, :max_commit_log_limit, 3)
    on_exit(fn -> Application.delete_env(:commonplace, :max_commit_log_limit) end)

    parent = stored_chit(store, %{uuid => c1.id}, [], "deep parent")
    child = chit(%{uuid => head.id}, [parent.cid], "deep child")

    assert [%{descent: {:indeterminate, :walk_capped}}] =
             ChitAncestry.fetch(store, child, parent)

    # fail-closed: the non-answer is a named refusal, never silent-true
    # and never mislabeled as :not_ancestor
    assert {:error, {:ancestry_violation, [failure]}} = ChitAncestry.check(store, child)
    assert failure.reason == {:indeterminate, :walk_capped}
  end

  # --- [7] mint gate e2e, both arms ---

  test "the mint gate: an honest second mint proceeds; a false parent claim is refused unstored",
       %{store: store} do
    tree = build_tree(store)

    # green arm: the existing mint flow still works behind the gate
    branch = UUID.uuid4()
    assert {:ok, chit1} = ChitMint.commit(store, tree.root, branch, "first")
    edit_text(store, tree.a, 5, " edited")
    assert {:ok, chit2} = ChitMint.commit(store, tree.root, branch, "second")
    assert chit2.parents == [chit1.cid]

    # red arm: plant a fabricated head whose pin makes a false claim.
    # The evil chit pins doc a to a FOREIGN commit (doc b's genesis) —
    # a real row of the store, but not a row of doc a — so the next
    # mint's intersection check fails on the parent-membership fact.
    branch2 = UUID.uuid4()
    assert {:ok, _chit1b} = ChitMint.commit(store, tree.root, branch2, "honest start")

    {:ok, b_head} = CommitStoreClient.latest_commit(store, tree.b)
    evil = stored_chit(store, %{tree.a => b_head.id}, [], "fabricated moment")
    assert {:ok, _} = ChitBranchRef.advance(store, branch2, evil.cid)
    history_before = ChitBranchRef.history(store, branch2, limit: 100)

    assert {:error, {:ancestry_refused, {:ancestry_violation, failures}}} =
             ChitMint.commit(store, tree.root, branch2, "minted over a false claim")

    assert Enum.any?(failures, fn f ->
             f.parent == evil.cid and f.doc == tree.a and f.reason == :parent_not_in_doc
           end)

    # the refusal left the store untouched: head and history unchanged,
    # so the false narrative gained no descendant
    assert {:ok, head_after} = ChitBranchRef.head(store, branch2)
    assert head_after == evil.cid
    assert ChitBranchRef.history(store, branch2, limit: 100) == history_before
  end

  # --- [8] genesis vacuous ---

  test "a parents-[] chit is the no-claim case: :ok with no walk and no fetch", %{store: store} do
    # The pin deliberately names a commit that exists NOWHERE — if the
    # genesis path fetched or walked anything, this would fail; passing
    # proves check/2 short-circuits before touching the store.
    genesis = chit(%{UUID.uuid4() => sha("no such commit")}, [], "first light")
    assert ChitAncestry.check(store, genesis) == :ok
  end
end
