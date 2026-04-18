defmodule Commonplace.Store.MergeSnapshotterTest do
  @moduledoc """
  CX-dx22 (Build 7.4): `MergeSnapshotter.build_merge_snapshot/3`
  produces a multi-parent snapshot commit.

  A merge-snapshot establishes a fresh namespace both L and R derive
  from, with `snapshot_parents = [L_ns, R_ns]` and a derivation map
  that has two inner entries — one per source namespace.

  Scope per Build 6+7 plan 7.4:
  - Multi-parent snapshot with DM covering both epochs.
  - Byte-determinism across two peers producing the same merge-snapshot
    from the same inputs.
  - Late-edit translation works against merge-snapshots (the DM-with-
    multiple-entries case is structurally supported by 6.2 / 6.3).

  Deferred (matches CX-fdjh scoping): CID-dedup-via-import tests need
  CX-fbs6 (namespace validator cross-epoch escape hatch). This bead
  ships in-memory determinism tests on the commit struct.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.{Commit, CommitStore, MergeSnapshotter, Namespace}
  alias Yelixer.{BlockStore, Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir = Path.join(System.tmp_dir!(), "ms_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"ms_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  # -------------------- Scenario builders (mirror CrossEpochMergeTest) --

  defp seed_and_snapshot(store, uuid) do
    {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)

    doc_p = Doc.new(client_id: 1)
    {doc_p, _} = Doc.get_or_create_type(doc_p, "t", :text)
    doc_p = Text.insert(doc_p, "t", 0, "abc")
    e_p = Encoding.encode_update(doc_p)

    _reg = CommitStore.create_chained_commit(store, uuid, e_p, %{kind: :regular})
    {:ok, snapshot} = CommitStore.snapshot(store, uuid)
    base_sv = BlockStore.state_vector(doc_p.store)

    {uuid, snapshot, base_sv}
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
    {^uuid, c_snapshot, _} = seed_and_snapshot(store, uuid)

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

  # -------------------- Shape: multi-parent snapshot w/ 2-entry DM --------

  describe "build_merge_snapshot/3 — commit shape" do
    test "produces a :snapshot commit with snapshot_parents = [L_ns, R_ns] and a 2-entry DM",
         %{store: store} do
      uuid = "ms-shape"
      {c_snapshot, l_commit, r_commit} = build_l_r_off_c(store, uuid)

      assert {:ok, snap} =
               MergeSnapshotter.build_merge_snapshot(store, l_commit.id, r_commit.id)

      assert %Commit{} = snap
      assert snap.doc_uuid == uuid
      assert snap.metadata[:kind] == :snapshot

      l_ns = Namespace.current_namespace(l_commit)
      r_ns = Namespace.current_namespace(r_commit)

      # Both chains hang directly off C, so both namespaces are C's id.
      assert l_ns == c_snapshot.id
      assert r_ns == c_snapshot.id

      # snapshot_parents is [L_ns, R_ns] (may be duplicated when L_ns == R_ns,
      # which is the case in this degenerate-chain scenario).
      assert snap.metadata[:snapshot_parents] == [l_ns, r_ns]

      dm = snap.metadata[:derivation_map]
      assert is_map(dm)
      # DM has an entry per source namespace — deduplicated when both
      # chains hang off the same C, but the key is present at least once.
      assert Map.has_key?(dm, l_ns)
      assert Map.has_key?(dm, r_ns)
      # Inner maps non-empty — C's content gets minted under the merge-
      # snapshot's deterministic client_id, so at least the "abc" items
      # produce new_id → source_id entries.
      assert map_size(Map.fetch!(dm, l_ns)) > 0

      assert snap.metadata[:snapshotter_version] ==
               Commonplace.Store.Snapshotter.snapshotter_version()

      assert is_binary(snap.update)
    end
  end

  # -------------------- Content: applying snap produces combined state --

  describe "build_merge_snapshot/3 — snapshot content preserves both branches" do
    test "applying the snapshot's update to Doc.new() yields 'abc' + X + Y",
         %{store: store} do
      uuid = "ms-content"
      {_c_snapshot, l_commit, r_commit} = build_l_r_off_c(store, uuid)

      {:ok, snap} =
        MergeSnapshotter.build_merge_snapshot(store, l_commit.id, r_commit.id)

      {:ok, doc} = Encoding.apply_update(Doc.new(), snap.update)
      text = Text.to_string(doc, "t")

      assert String.contains?(text, "abc")
      assert String.contains?(text, "X")
      assert String.contains?(text, "Y")
    end
  end

  # -------------------- Byte-determinism --------------------

  describe "build_merge_snapshot/3 — byte-determinism" do
    test "two merge-snapshot calls on the same inputs produce identical commit structs",
         %{store: store} do
      uuid = "ms-bd"
      {_c_snapshot, l_commit, r_commit} = build_l_r_off_c(store, uuid)

      {:ok, snap_a} =
        MergeSnapshotter.build_merge_snapshot(store, l_commit.id, r_commit.id)

      {:ok, snap_b} =
        MergeSnapshotter.build_merge_snapshot(store, l_commit.id, r_commit.id)

      assert snap_a.id == snap_b.id
      assert snap_a.update == snap_b.update
      assert snap_a.parent_id == snap_b.parent_id
      assert snap_a.merge_parents == snap_b.merge_parents
      assert snap_a.metadata == snap_b.metadata
    end
  end

  # -------------------- Late-edit translation against merge-snapshot ----
  #
  # Acceptance: a late edit whose refs point at items present in the
  # merge-snapshot's DM translates cleanly. We scope this to an L-ns
  # reference (L's own post-C edit) to avoid the character-level
  # DM fidelity issue in multi-source coalescence (see docstring in
  # `MergeSnapshotter` — deferred follow-up). A late edit referencing
  # C-content through its C-ns id hits that gap and is NOT covered here.
  describe "build_merge_snapshot/3 — late-edit translation (L-only ref)" do
    test "a late edit whose origin is an L-only item translates via the merge-snapshot's DM",
         %{store: store} do
      uuid = "ms-late-l"
      {uuid, c_snapshot, _base_sv} = seed_and_snapshot(store, uuid)

      {:ok, c_doc} = Encoding.apply_update(Doc.new(), c_snapshot.update)
      c_update = Encoding.encode_update(c_doc)

      # L appends "X" AT THE END of "abc" → text "abcX", item {2, 0}.
      l_commit =
        author_regular(store, uuid, c_update, 2, fn d ->
          Text.insert(d, "t", 3, "X")
        end)

      # R appends "Y" — the content test already covers content blending.
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

      {:ok, snap} =
        MergeSnapshotter.build_merge_snapshot(store, l_commit.id, r_commit.id)

      # Late edit: append "Q" after "X" (L-only item). The Q item's
      # origin is {2, 0} — L's own-edit id, which `split_dm` places into
      # `DM_L_inner[L_ns]` as an explicit entry (not subject to the
      # sub-clock over-expansion in the translator).
      {:ok, d_l_pre} = Encoding.apply_update(Doc.new(), l_commit.update)
      d_l_pre = %{d_l_pre | client_id: 42}
      d_l_edit = Text.insert(d_l_pre, "t", byte_size(Text.to_string(d_l_pre, "t")), "Q")

      base_sv = BlockStore.state_vector(d_l_pre.store)
      late_edit_bytes = Encoding.encode_diff(d_l_edit, base_sv)

      late_edit =
        Commit.new(uuid, late_edit_bytes, nil, %{
          kind: :regular,
          snapshot_parent: snap.id
        })

      assert {:ok, translated} =
               Commonplace.Store.Translator.translate_edit_with_snapshot(
                 late_edit,
                 snap
               )

      assert %Commit{} = translated
      assert is_binary(translated.update)
    end

    # Character-level pair_ids in MergeSnapshotter means explicit per-
    # clock DM entries cover every position in the rebuilt item. A
    # late edit whose origin lands on a C-content character (e.g.
    # {1, 2}, the 'c' from the common ancestor) now has a precise
    # DM entry and translates cleanly.
    test "a late edit whose origin is C-content translates via the merge-snapshot's DM",
         %{store: store} do
      uuid = "ms-late-c"
      {_c_snapshot, l_commit, r_commit} = build_l_r_off_c(store, uuid)

      {:ok, snap} =
        MergeSnapshotter.build_merge_snapshot(store, l_commit.id, r_commit.id)

      # Late edit: append "Q" at the END of d_l. d_l text is "Xabc"
      # (L inserted "X" at pos 0). Appending at byte_size "Xabc" = 4
      # has origin = last char = 'c' = {1, 2} — a C-content ref.
      {:ok, d_l_pre} = Encoding.apply_update(Doc.new(), l_commit.update)
      d_l_pre = %{d_l_pre | client_id: 42}
      d_l_edit = Text.insert(d_l_pre, "t", byte_size(Text.to_string(d_l_pre, "t")), "Q")

      base_sv = BlockStore.state_vector(d_l_pre.store)
      late_edit_bytes = Encoding.encode_diff(d_l_edit, base_sv)

      late_edit =
        Commit.new(uuid, late_edit_bytes, nil, %{
          kind: :regular,
          snapshot_parent: snap.id
        })

      assert {:ok, translated} =
               Commonplace.Store.Translator.translate_edit_with_snapshot(
                 late_edit,
                 snap
               )

      assert %Commit{} = translated
      assert is_binary(translated.update)
    end
  end
end
