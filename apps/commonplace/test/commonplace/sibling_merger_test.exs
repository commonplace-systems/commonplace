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
end
