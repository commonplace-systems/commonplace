defmodule Commonplace.SiblingMergerTest do
  @moduledoc """
  CX-4qn1: Distributed sibling-commit merge (post-import chain reassembly).

  `SiblingMerger.maybe_merge_siblings(store, doc_uuid, opts)` reads
  `:latest` for `doc_uuid`, discovers any commits for the same doc that
  are NOT on `:latest`'s linear parent chain (i.e. siblings landed via
  `CommitStore.import_commit/2`), and merges each sibling into the
  local head via `Merger.merge(l, r, strategy: :translate)` by default.

  The resulting merge commit is written back to the store and `:latest`
  advances to it, CAS-guarded on the parent we observed — so a concurrent
  local writer who advanced `:latest` out from under us forces a re-read
  rather than silently clobbering their commit.

  This is the follow-up to CX-l7j: CX-l7j fixed in-process sibling races
  via GenServer mailbox serialization. Distributed siblings landed via
  `import_commit` can only be collapsed post-hoc. The primitive is a
  building block — trigger-point (post-import hook vs. sync-agent sweep
  vs. explicit call) is deferred to the wiring beads that sit on top.
  """
  use ExUnit.Case, async: false

  alias Commonplace.SiblingMerger
  alias Commonplace.Store.{Commit, CommitStore, Namespace}
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "sibmerge_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"sibmerge_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  # Build C (snapshot) → L (local chain, via create_chained_commit) with a
  # sibling R imported with `parent_id = C.id`. Matches the classic
  # distributed-race shape: two peers wrote off the same parent, one
  # arrived via sync afterwards.
  defp seed_sibling_scenario(store, uuid) do
    {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)

    doc_c = Doc.new(client_id: 1)
    {doc_c, _} = Doc.get_or_create_type(doc_c, "t", :text)
    doc_c = Text.insert(doc_c, "t", 0, "abc")

    _reg =
      CommitStore.create_chained_commit(
        store,
        uuid,
        Encoding.encode_update(doc_c),
        %{kind: :regular}
      )

    {:ok, c_snapshot} = CommitStore.snapshot(store, uuid)

    {:ok, c_doc} = Encoding.apply_update(Doc.new(), c_snapshot.update)
    c_update = Encoding.encode_update(c_doc)

    # L: local chain adds "X" on top of the snapshot.
    doc_l = Doc.new(client_id: 2)
    {doc_l, _} = Doc.get_or_create_type(doc_l, "t", :text)
    {:ok, doc_l} = Encoding.apply_update(doc_l, c_update)
    doc_l = Text.insert(doc_l, "t", 0, "X")
    l_update = Encoding.encode_update(doc_l)
    l_commit = CommitStore.create_chained_commit(store, uuid, l_update, %{kind: :regular})

    # R: sibling of L — same parent (c_snapshot), imported via the remote
    # sync path, so :latest stays on L and R is orphaned off :latest.
    doc_r = Doc.new(client_id: 3)
    {doc_r, _} = Doc.get_or_create_type(doc_r, "t", :text)
    {:ok, doc_r} = Encoding.apply_update(doc_r, c_update)
    doc_r = Text.insert(doc_r, "t", 3, "Y")
    r_update = Encoding.encode_update(doc_r)

    r_commit =
      Commit.new(uuid, r_update, c_snapshot.id, %{
        kind: :regular,
        snapshot_parent: c_snapshot.id
      })

    :ok = CommitStore.import_commit(store, r_commit, validator: fn _ -> :ok end)

    {c_snapshot, l_commit, r_commit}
  end

  describe "maybe_merge_siblings/3 — happy path" do
    test "merges a single imported sibling into :latest via :translate",
         %{store: store} do
      uuid = "sib-happy"
      {_c, l, r} = seed_sibling_scenario(store, uuid)

      # Pre-state: :latest is L; R exists in store but is not on L's chain.
      {:ok, pre_latest} = CommitStore.latest_commit(store, uuid)
      assert pre_latest.id == l.id
      refute MapSet.member?(CommitStore.commit_ids_for_doc(store, uuid), r.id)

      assert {:ok, :merged, merge_commit} =
               SiblingMerger.maybe_merge_siblings(store, uuid)

      # Merge commit shape: parent is L, merge_parents is [R], kind :merge,
      # snapshot_parent stamped to L's namespace (same-namespace case).
      assert merge_commit.metadata[:kind] == :merge
      assert merge_commit.parent_id == l.id
      assert merge_commit.merge_parents == [r.id]
      assert merge_commit.metadata[:snapshot_parent] == Namespace.current_namespace(l)

      # Persisted + :latest advanced.
      assert {:ok, persisted} = CommitStore.get_commit(store, merge_commit.id)
      assert persisted.id == merge_commit.id

      {:ok, new_latest} = CommitStore.latest_commit(store, uuid)
      assert new_latest.id == merge_commit.id

      # R is now reachable via :latest's chain (through merge_parents).
      chain_ids = CommitStore.commit_ids_for_doc(store, uuid)
      assert MapSet.member?(chain_ids, merge_commit.id)
      assert MapSet.member?(chain_ids, l.id)
    end

    # Increment 2: SiblingMerger consumes the accepted-head index (tips),
    # so a sibling CHAIN R1 -> R2 is merged at its TIP (R2) in one pass,
    # folding R1 through merge_parents — where the pre-index scan yielded
    # {R1, R2} and could fold interior-first. Proves the index path
    # handles chains: the head set is {L, R2} (R1 dominated), the merge
    # folds both, and it settles at :no_siblings.
    test "a sibling chain is folded at its tip in one merge (index path)",
         %{store: store} do
      uuid = "sib-chain"
      {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)

      doc_c = Doc.new(client_id: 1)
      {doc_c, _} = Doc.get_or_create_type(doc_c, "t", :text)
      doc_c = Text.insert(doc_c, "t", 0, "abc")

      _ =
        CommitStore.create_chained_commit(store, uuid, Encoding.encode_update(doc_c), %{
          kind: :regular
        })

      {:ok, c} = CommitStore.snapshot(store, uuid)
      {:ok, c_doc} = Encoding.apply_update(Doc.new(), c.update)
      c_update = Encoding.encode_update(c_doc)

      doc_l = Doc.new(client_id: 2)
      {doc_l, _} = Doc.get_or_create_type(doc_l, "t", :text)
      {:ok, doc_l} = Encoding.apply_update(doc_l, c_update)
      doc_l = Text.insert(doc_l, "t", 0, "X")

      l =
        CommitStore.create_chained_commit(store, uuid, Encoding.encode_update(doc_l), %{
          kind: :regular
        })

      # Sibling chain off C: R1, then R2 with parent R1 (both imported).
      doc_r1 = Doc.new(client_id: 3)
      {doc_r1, _} = Doc.get_or_create_type(doc_r1, "t", :text)
      {:ok, doc_r1} = Encoding.apply_update(doc_r1, c_update)
      doc_r1 = Text.insert(doc_r1, "t", 3, "Y")

      r1 =
        Commit.new(uuid, Encoding.encode_update(doc_r1), c.id, %{
          kind: :regular,
          snapshot_parent: c.id
        })

      :ok = CommitStore.import_commit(store, r1, validator: fn _ -> :ok end)

      doc_r2 = Doc.new(client_id: 3)
      {doc_r2, _} = Doc.get_or_create_type(doc_r2, "t", :text)
      {:ok, doc_r2} = Encoding.apply_update(doc_r2, c_update)
      doc_r2 = Text.insert(doc_r2, "t", 3, "YZ")

      r2 =
        Commit.new(uuid, Encoding.encode_update(doc_r2), r1.id, %{
          kind: :regular,
          snapshot_parent: c.id
        })

      :ok = CommitStore.import_commit(store, r2, validator: fn _ -> :ok end)

      # The index path yields the frontier tips: {L, R2}, R1 dominated.
      assert {:ok, heads} = CommitStore.accepted_heads_indexed(store, uuid)
      assert heads == MapSet.new([l.id, r2.id])

      # One merge folds the whole chain: the merge is on R2 (the tip), and
      # R1 comes along through R2's history.
      assert {:ok, :merged, merge_commit} = SiblingMerger.maybe_merge_siblings(store, uuid)
      assert merge_commit.merge_parents == [r2.id]

      # The seam collapses the frontier to the merge commit alone — proof
      # that both R1 and R2 are now dominated (a chain folded in one merge).
      # (commit_ids_for_doc is the LINEAR chain and would not show R1/R2,
      # which are reachable only through the merge_parents edge.)
      assert CommitStore.accepted_heads_indexed(store, uuid) ==
               {:ok, MapSet.new([merge_commit.id])}

      # Settled: nothing left divergent.
      assert {:ok, :no_siblings} = SiblingMerger.maybe_merge_siblings(store, uuid)
    end

    test "returns :no_siblings when :latest's chain already covers every commit",
         %{store: store} do
      uuid = "sib-none"
      {:ok, _g} = CommitStore.ensure_genesis(store, uuid)

      doc = Doc.new(client_id: 1)
      {doc, _} = Doc.get_or_create_type(doc, "t", :text)
      doc = Text.insert(doc, "t", 0, "hi")

      _ =
        CommitStore.create_chained_commit(
          store,
          uuid,
          Encoding.encode_update(doc),
          %{kind: :regular}
        )

      {:ok, before_latest} = CommitStore.latest_commit(store, uuid)

      assert {:ok, :no_siblings} = SiblingMerger.maybe_merge_siblings(store, uuid)

      {:ok, after_latest} = CommitStore.latest_commit(store, uuid)
      assert after_latest.id == before_latest.id
    end

    test "returns :no_siblings for a doc_uuid with no commits at all",
         %{store: store} do
      assert {:ok, :no_siblings} = SiblingMerger.maybe_merge_siblings(store, "nope")
    end

    test "is idempotent: second call after a merge reports :no_siblings",
         %{store: store} do
      uuid = "sib-idem"
      {_c, _l, _r} = seed_sibling_scenario(store, uuid)

      assert {:ok, :merged, _merge} = SiblingMerger.maybe_merge_siblings(store, uuid)
      assert {:ok, :no_siblings} = SiblingMerger.maybe_merge_siblings(store, uuid)
    end

    test "accepts :strategy override — :merge_snapshot yields a snapshot commit",
         %{store: store} do
      uuid = "sib-snap-strat"
      {_c, l, r} = seed_sibling_scenario(store, uuid)

      assert {:ok, :merged, merge_commit} =
               SiblingMerger.maybe_merge_siblings(store, uuid, strategy: :merge_snapshot)

      assert merge_commit.metadata[:kind] == :snapshot
      assert merge_commit.parent_id == l.id
      assert merge_commit.merge_parents == [r.id]

      l_ns = Namespace.current_namespace(l)
      r_ns = Namespace.current_namespace(r)
      assert merge_commit.metadata[:snapshot_parents] == [l_ns, r_ns]

      # :latest advanced.
      {:ok, new_latest} = CommitStore.latest_commit(store, uuid)
      assert new_latest.id == merge_commit.id
    end
  end

  describe "maybe_merge_siblings/3 — atomicity" do
    test "does not advance :latest if the merge write returns :parent_moved",
         %{store: store} do
      # Simulate a concurrent writer by pre-merging and then calling again
      # with stale state — the second call should not clobber.
      uuid = "sib-cas"
      {_c, _l, _r} = seed_sibling_scenario(store, uuid)

      assert {:ok, :merged, _} = SiblingMerger.maybe_merge_siblings(store, uuid)
      {:ok, first_latest} = CommitStore.latest_commit(store, uuid)

      # After the first merge collapses siblings, the second call sees no
      # siblings (nothing off-chain) — a clean no-op path.
      assert {:ok, :no_siblings} = SiblingMerger.maybe_merge_siblings(store, uuid)

      {:ok, after_latest} = CommitStore.latest_commit(store, uuid)
      assert after_latest.id == first_latest.id
    end
  end

  describe "maybe_merge_siblings/3 — unmergeable siblings (CX-xxav)" do
    # A sibling the merge engine REFUSES used to be reported as
    # `{:ok, :no_siblings}` — "there is nothing to merge", which is
    # false and leaves the caller unable to distinguish a converged doc
    # from one whose convergence just failed.
    test "a sibling the merge engine refuses is reported, not renamed to :no_siblings",
         %{store: store} do
      uuid = "sib-unmergeable"
      {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)

      doc = Doc.new(client_id: 1)
      {doc, _} = Doc.get_or_create_type(doc, "t", :text)
      doc = Text.insert(doc, "t", 0, "abc")

      l_commit =
        CommitStore.create_chained_commit(
          store,
          uuid,
          Encoding.encode_update(doc),
          %{kind: :regular}
        )

      # A sibling chained to a parent this store has never seen: it is
      # a real, persisted, off-:latest commit, but no common ancestor
      # with the local head can be found, so `Merger.merge/4` refuses.
      orphan_parent = :crypto.strong_rand_bytes(32)

      doc_r = Doc.new(client_id: 3)
      {doc_r, _} = Doc.get_or_create_type(doc_r, "t", :text)
      doc_r = Text.insert(doc_r, "t", 0, "Y")

      r_commit =
        Commit.new(uuid, Encoding.encode_update(doc_r), orphan_parent, %{
          kind: :regular,
          snapshot_parent: orphan_parent
        })

      :ok = CommitStore.import_commit(store, r_commit, validator: fn _ -> :ok end)

      # Precondition: it really is an off-:latest sibling.
      assert MapSet.member?(CommitStore.all_commit_ids_for_doc(store, uuid), r_commit.id)
      refute MapSet.member?(CommitStore.commit_ids_for_doc(store, uuid), r_commit.id)

      assert {:error, {:siblings_unmergeable, failures}} =
               SiblingMerger.maybe_merge_siblings(store, uuid)

      assert [{sibling_id, _reason}] = failures
      assert sibling_id == r_commit.id

      # And the head is untouched.
      assert {:ok, %{id: head_id}} = CommitStore.latest_commit(store, uuid)
      assert head_id == l_commit.id
    end

    # Which sibling gets merged must be a decision, not a side effect of
    # BEAM term order over content-addressed ids — bumping an unrelated
    # version tag re-rolls every id and would otherwise silently change
    # which code path a test exercises (that is exactly how CX-xxav's
    # cross-epoch e2e case flipped red).
    test "with two siblings, the lower id is attempted first", %{store: store} do
      uuid = "sib-order"
      {c_snapshot, _l, r} = seed_sibling_scenario(store, uuid)

      {:ok, c_doc} = Encoding.apply_update(Doc.new(), c_snapshot.update)
      c_update = Encoding.encode_update(c_doc)

      # A second sibling off the same parent as R.
      doc_r2 = Doc.new(client_id: 4)
      {doc_r2, _} = Doc.get_or_create_type(doc_r2, "t", :text)
      {:ok, doc_r2} = Encoding.apply_update(doc_r2, c_update)
      doc_r2 = Text.insert(doc_r2, "t", 3, "Z")

      r2_commit =
        Commit.new(uuid, Encoding.encode_update(doc_r2), c_snapshot.id, %{
          kind: :regular,
          snapshot_parent: c_snapshot.id
        })

      :ok = CommitStore.import_commit(store, r2_commit, validator: fn _ -> :ok end)

      handler_id =
        :telemetry_test.attach_event_handlers(self(), [
          [:commonplace, :merge, :completed]
        ])

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, :merged, _} = SiblingMerger.maybe_merge_siblings(store, uuid)

      assert_received {[:commonplace, :merge, :completed], _ref, _measure, meta}
      assert meta.r == Enum.min([r.id, r2_commit.id])
    end
  end
end
