defmodule Commonplace.Store.MergerTest do
  @moduledoc """
  CX-fb74 (Build 7.5): top-level merge router.

  `Merger.merge(store, L, R, strategy: :translate | :merge_snapshot, opts)`
  is a thin dispatch over CX-fdjh (CrossEpochMerge) and CX-dx22
  (MergeSnapshotter) with no automatic heuristics — the caller chooses.
  Red events:
  - `[:commonplace, :merge, :completed]` with `%{strategy, l, r, result_id}`
  - `[:commonplace, :merge, :failed]` with `%{strategy, reason, l, r}`
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.{Commit, CommitStore, Merger, Namespace}
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "merger_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"merger_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)

    handler_id = "merger-test-#{:rand.uniform(1_000_000)}"

    parent = self()

    :telemetry.attach_many(
      handler_id,
      [
        [:commonplace, :merge, :completed],
        [:commonplace, :merge, :failed]
      ],
      fn event, measures, meta, _ ->
        send(parent, {:telemetry, event, measures, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    %{store: name}
  end

  defp seed_and_snapshot(store, uuid) do
    {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)

    doc_p = Doc.new(client_id: 1)
    {doc_p, _} = Doc.get_or_create_type(doc_p, "t", :text)
    doc_p = Text.insert(doc_p, "t", 0, "abc")
    e_p = Encoding.encode_update(doc_p)

    _reg = CommitStore.create_chained_commit(store, uuid, e_p, %{kind: :regular})
    {:ok, snapshot} = CommitStore.snapshot(store, uuid)
    {uuid, snapshot}
  end

  defp author_regular(store, uuid, base_update, client_id, op_fn) do
    doc_b = Doc.new(client_id: client_id)
    {doc_b, _} = Doc.get_or_create_type(doc_b, "t", :text)
    {:ok, doc_b} = Encoding.apply_update(doc_b, base_update)
    doc_b = op_fn.(doc_b)
    update = Encoding.encode_update(doc_b)
    CommitStore.create_chained_commit(store, uuid, update, %{kind: :regular})
  end

  defp build_l_r_off_c(store, uuid) do
    {^uuid, c_snapshot} = seed_and_snapshot(store, uuid)

    {:ok, c_doc} = Encoding.apply_update(Doc.new(), c_snapshot.update)
    c_update = Encoding.encode_update(c_doc)

    l_commit =
      author_regular(store, uuid, c_update, 2, fn d ->
        Text.insert(d, "t", 0, "X")
      end)

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

  # -------------------- strategy: :translate --------------------

  describe "merge/4 — strategy: :translate" do
    test "produces a :merge commit with parent_id=L.id and merge_parents=[R.id]",
         %{store: store} do
      uuid = "mrg-trans"
      {_c, l, r} = build_l_r_off_c(store, uuid)

      assert {:ok, commit} = Merger.merge(store, l.id, r.id, strategy: :translate)

      assert %Commit{} = commit
      assert commit.doc_uuid == uuid
      assert commit.metadata[:kind] == :merge
      assert commit.parent_id == l.id
      assert commit.merge_parents == [r.id]
      assert commit.metadata[:snapshot_parent] == Namespace.current_namespace(l)
    end

    test "emits [:commonplace, :merge, :completed] with strategy :translate",
         %{store: store} do
      uuid = "mrg-trans-red"
      {_c, l, r} = build_l_r_off_c(store, uuid)

      {:ok, commit} = Merger.merge(store, l.id, r.id, strategy: :translate)

      assert_received {:telemetry, [:commonplace, :merge, :completed], _measures, meta}
      assert meta.strategy == :translate
      assert meta.l == l.id
      assert meta.r == r.id
      assert meta.result_id == commit.id
    end
  end

  # -------------------- strategy: :merge_snapshot --------------------

  describe "canonical_pair/2 (CX-1mml)" do
    test "returns a sorted pair regardless of input order" do
      a = <<0x01>>
      b = <<0x02>>
      assert Merger.canonical_pair(a, b) == {a, b}
      assert Merger.canonical_pair(b, a) == {a, b}
    end

    test "canonical-pair arg order makes merge(L,R) byte-identical to merge(R,L) — :translate",
         %{store: store} do
      uuid = "mrg-canon-trans"
      {_c, l, r} = build_l_r_off_c(store, uuid)

      {c_l, c_r} = Merger.canonical_pair(l.id, r.id)
      {c_l_rev, c_r_rev} = Merger.canonical_pair(r.id, l.id)

      assert {:ok, forward} = Merger.merge(store, c_l, c_r, strategy: :translate)
      assert {:ok, reverse} = Merger.merge(store, c_l_rev, c_r_rev, strategy: :translate)

      assert forward.id == reverse.id
      assert forward.update == reverse.update
      assert forward.parent_id == reverse.parent_id
      assert forward.merge_parents == reverse.merge_parents
      assert forward.metadata == reverse.metadata
    end

    test "canonical-pair arg order makes merge(L,R) byte-identical to merge(R,L) — :merge_snapshot",
         %{store: store} do
      uuid = "mrg-canon-snap"
      {_c, l, r} = build_l_r_off_c(store, uuid)

      {c_l, c_r} = Merger.canonical_pair(l.id, r.id)
      {c_l_rev, c_r_rev} = Merger.canonical_pair(r.id, l.id)

      assert {:ok, forward} = Merger.merge(store, c_l, c_r, strategy: :merge_snapshot)
      assert {:ok, reverse} = Merger.merge(store, c_l_rev, c_r_rev, strategy: :merge_snapshot)

      assert forward.id == reverse.id
      assert forward.update == reverse.update
      assert forward.parent_id == reverse.parent_id
      assert forward.merge_parents == reverse.merge_parents
      assert forward.metadata == reverse.metadata
    end
  end

  describe "merge/4 — strategy: :merge_snapshot" do
    test "produces a :snapshot commit with snapshot_parents=[L_ns, R_ns]",
         %{store: store} do
      uuid = "mrg-snap"
      {_c, l, r} = build_l_r_off_c(store, uuid)

      assert {:ok, commit} = Merger.merge(store, l.id, r.id, strategy: :merge_snapshot)

      assert %Commit{} = commit
      assert commit.doc_uuid == uuid
      assert commit.metadata[:kind] == :snapshot

      l_ns = Namespace.current_namespace(l)
      r_ns = Namespace.current_namespace(r)
      assert commit.metadata[:snapshot_parents] == [l_ns, r_ns]
      assert is_map(commit.metadata[:derivation_map])
    end

    test "emits [:commonplace, :merge, :completed] with strategy :merge_snapshot",
         %{store: store} do
      uuid = "mrg-snap-red"
      {_c, l, r} = build_l_r_off_c(store, uuid)

      {:ok, commit} = Merger.merge(store, l.id, r.id, strategy: :merge_snapshot)

      assert_received {:telemetry, [:commonplace, :merge, :completed], _measures, meta}
      assert meta.strategy == :merge_snapshot
      assert meta.l == l.id
      assert meta.r == r.id
      assert meta.result_id == commit.id
    end
  end

  # -------------------- unknown strategy --------------------

  describe "merge/4 — unknown strategy" do
    test "returns {:error, {:unknown_strategy, strat}} and emits :failed",
         %{store: store} do
      uuid = "mrg-unk"
      {_c, l, r} = build_l_r_off_c(store, uuid)

      assert {:error, {:unknown_strategy, :bogus}} =
               Merger.merge(store, l.id, r.id, strategy: :bogus)

      assert_received {:telemetry, [:commonplace, :merge, :failed], _measures, meta}
      assert meta.strategy == :bogus
      assert meta.reason == {:unknown_strategy, :bogus}
      assert meta.l == l.id
      assert meta.r == r.id
    end

    test "missing :strategy returns {:error, :strategy_required} and emits :failed",
         %{store: store} do
      uuid = "mrg-miss"
      {_c, l, r} = build_l_r_off_c(store, uuid)

      assert {:error, :strategy_required} = Merger.merge(store, l.id, r.id, [])

      assert_received {:telemetry, [:commonplace, :merge, :failed], _measures, meta}
      assert meta.reason == :strategy_required
      assert meta.l == l.id
      assert meta.r == r.id
    end
  end

  # -------------------- failure passthrough --------------------

  describe "merge/4 — failure emits :failed" do
    test "unknown commit id → :failed event with reason",
         %{store: store} do
      uuid = "mrg-fail"
      {_c, l, _r} = build_l_r_off_c(store, uuid)

      bogus_id = String.duplicate("0", 64)

      assert {:error, _reason} =
               Merger.merge(store, l.id, bogus_id, strategy: :translate)

      assert_received {:telemetry, [:commonplace, :merge, :failed], _measures, meta}
      assert meta.strategy == :translate
      assert meta.l == l.id
      assert meta.r == bogus_id
    end
  end

  # -------------------- Build 7 (CX-cy7) acceptance --------------------
  #
  # Both strategies on the same scenario: two branches diverge after C,
  # each adding text edits, and both merge strategies produce a commit
  # whose content reflects both sides' effects (plus C's baseline).

  describe "Build 7 integration — both strategies preserve both sides" do
    test "same L/R: :translate and :merge_snapshot both yield abc + X + Y",
         %{store: store} do
      uuid = "mrg-integration"
      {_c, l, r} = build_l_r_off_c(store, uuid)

      {:ok, translate_commit} = Merger.merge(store, l.id, r.id, strategy: :translate)
      {:ok, snapshot_commit} = Merger.merge(store, l.id, r.id, strategy: :merge_snapshot)

      # :translate applies to L's state — reconstruct D_L and apply.
      {:ok, d_l} = Encoding.apply_update(Doc.new(), l.update)
      {:ok, d_translate} = Encoding.apply_update(d_l, translate_commit.update)
      translate_text = Text.to_string(d_translate, "t")
      assert String.contains?(translate_text, "abc")
      assert String.contains?(translate_text, "X")
      assert String.contains?(translate_text, "Y")

      # :merge_snapshot is a self-contained namespace bootstrap — applies
      # to Doc.new() directly.
      {:ok, d_snap} = Encoding.apply_update(Doc.new(), snapshot_commit.update)
      snap_text = Text.to_string(d_snap, "t")
      assert String.contains?(snap_text, "abc")
      assert String.contains?(snap_text, "X")
      assert String.contains?(snap_text, "Y")
    end
  end
end
