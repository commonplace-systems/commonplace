defmodule Commonplace.Store.CodeDocMergeGateTest do
  @moduledoc """
  CX-obfb: no-delta-merge-on-code-docs enforcement.

  Gate B (`Commonplace.Trust.authorized_to_execute?`) walks a code doc's
  commit chain via `parent_id` only — it never visits `merge_parents`.
  A delta-merge commit's absorbed bytes (from a merge_parents side-line,
  or a MergeSnapshotter two-parent snapshot) would therefore reach
  execution unchecked. The fix is to forbid delta-merges from landing on
  code docs at every seam, rather than teach Gate B to traverse merge
  edges:

    1. Import seam (`CommitStore.import_commit/3`) — rejects a
       delta-merge-shaped commit targeting a code doc.
    2. Auto-merge seam (`SiblingMerger.maybe_merge_siblings/3`) — skips
       merging siblings into a code doc, leaving heads divergent.
    3. Explicit-merge seam (`Commonplace.Store.Merger.merge/4`) — refuses
       both `:translate` and `:merge_snapshot` strategies on a code doc.

  Code docs converge only by re-authorship: an `:execute`-authorized
  signer mints a regular full-state commit.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.ContentType
  alias Commonplace.SiblingMerger
  alias Commonplace.Store.{Commit, CommitStore, Merger, Namespace}
  alias Yelixer.{Doc, Encoding}

  @code_body "defmodule Foo do\n  def x, do: 1\nend\n"
  @prose_body "the quick brown fox jumps over the lazy dog"

  setup do
    dir = Path.join(System.tmp_dir!(), "codedoc_gate_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"codedoc_gate_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  # ── fixtures ──────────────────────────────────────────────────────────

  # Writes a single-commit doc whose full-state update decodes to `body`
  # via the ContentType envelope (root/content types) — matches how
  # CodeDocHeuristic's own tests seed a classifiable doc, and how
  # `Commonplace.Document.ContentType.get_content/1` (what the classifier
  # reads) expects a doc to be shaped, unlike a bare unregistered "t" type.
  defp seed_doc(store, uuid, body) do
    {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)

    doc = Doc.new(client_id: 1) |> ContentType.create(:text, "doc")
    doc = ContentType.insert_text(doc, 0, body)
    update = Encoding.encode_update(doc)

    CommitStore.create_chained_commit(store, uuid, update, %{kind: :regular})
  end

  # L/R off a common ancestor snapshot C, for the explicit-merge (Merger)
  # and sibling-merge (SiblingMerger) seams. Mirrors merger_test.exs /
  # sibling_merger_test.exs's own fixture shape: a snapshot (not a bare
  # regular commit) is required as the shared root for
  # `SnapshotAncestry.common_ancestor/3` to find L and R's common
  # ancestor.
  defp build_l_r_off_c(store, uuid, body) do
    _seed = seed_doc(store, uuid, body)
    {:ok, c_snapshot} = CommitStore.snapshot(store, uuid)

    {:ok, c_doc} = Encoding.apply_update(Doc.new(), c_snapshot.update)
    c_update = Encoding.encode_update(c_doc)

    # Append (not prepend) so a code doc's `defmodule` line-start anchor
    # (CodeDocHeuristic's `elixir_source?/1` regex) survives the edit —
    # inserting at index 0 would corrupt the first line for the code-doc
    # fixture.
    tail = String.length(body)

    doc_l = Doc.new(client_id: 2)
    {:ok, doc_l} = Encoding.apply_update(doc_l, c_update)
    doc_l = ContentType.insert_text(doc_l, tail, "L")
    l_update = Encoding.encode_update(doc_l)
    l_commit = CommitStore.create_chained_commit(store, uuid, l_update, %{kind: :regular})

    doc_r = Doc.new(client_id: 3)
    {:ok, doc_r} = Encoding.apply_update(doc_r, c_update)
    doc_r = ContentType.insert_text(doc_r, tail, "R")
    r_update = Encoding.encode_update(doc_r)

    r_commit =
      Commit.new(uuid, r_update, c_snapshot.id, %{
        kind: :regular,
        snapshot_parent: c_snapshot.id
      })

    :ok = CommitStore.import_commit(store, r_commit, validator: fn _ -> :ok end)

    {c_snapshot, l_commit, r_commit}
  end

  # ── 1. import seam: merge_parents shape ──────────────────────────────

  describe "import seam — merge_parents delta-merge shape" do
    test "rejects a commit with non-empty merge_parents targeting a code doc",
         %{store: store} do
      uuid = "code-import-mp"
      l = seed_doc(store, uuid, @code_body)

      merge_shaped =
        Commit.new(uuid, "irrelevant bytes", l.id, %{kind: :merge}, [
          String.duplicate("a", 64)
        ])

      assert {:error, {:code_doc_delta_merge, ^uuid}} =
               CommitStore.import_commit(store, merge_shaped, validator: fn _ -> :ok end)
    end

    test "identical shape on a prose doc imports :ok", %{store: store} do
      uuid = "prose-import-mp"
      l = seed_doc(store, uuid, @prose_body)

      merge_shaped =
        Commit.new(uuid, "irrelevant bytes", l.id, %{kind: :merge}, [
          String.duplicate("a", 64)
        ])

      assert :ok =
               CommitStore.import_commit(store, merge_shaped, validator: fn _ -> :ok end)
    end
  end

  # ── 2. import seam: snapshot_parents two-parent shape ────────────────

  describe "import seam — snapshot_parents two-parent shape" do
    test "rejects a snapshot commit with 2-element snapshot_parents on a code doc",
         %{store: store} do
      uuid = "code-import-sp2"
      l = seed_doc(store, uuid, @code_body)

      merge_snapshot_shaped =
        Commit.new(uuid, "irrelevant bytes", l.id, %{
          kind: :snapshot,
          snapshot_parents: [String.duplicate("a", 64), String.duplicate("b", 64)]
        })

      assert {:error, {:code_doc_delta_merge, ^uuid}} =
               CommitStore.import_commit(store, merge_snapshot_shaped,
                 validator: fn _ -> :ok end
               )
    end

    test "a normal single-lineage snapshot commit on a code doc imports :ok",
         %{store: store} do
      uuid = "code-import-sp1"
      l = seed_doc(store, uuid, @code_body)

      single_lineage_snapshot =
        Commit.new(uuid, "irrelevant bytes", l.id, %{
          kind: :snapshot,
          snapshot_parents: [String.duplicate("a", 64)]
        })

      assert :ok =
               CommitStore.import_commit(store, single_lineage_snapshot,
                 validator: fn _ -> :ok end
               )
    end
  end

  # ── 3. auto-merge seam: SiblingMerger ─────────────────────────────────

  describe "auto-merge seam — SiblingMerger.maybe_merge_siblings/3" do
    test "skips merging a genuine sibling into a code doc", %{store: store} do
      uuid = "code-sibling"
      {_c, l, _r} = build_l_r_off_c(store, uuid, @code_body)

      {:ok, before_latest} = CommitStore.latest_commit(store, uuid)
      before_count = MapSet.size(CommitStore.all_commit_ids_for_doc(store, uuid))

      assert {:ok, :code_doc_skip} = SiblingMerger.maybe_merge_siblings(store, uuid)

      {:ok, after_latest} = CommitStore.latest_commit(store, uuid)
      assert after_latest.id == before_latest.id
      assert after_latest.id == l.id
      assert MapSet.size(CommitStore.all_commit_ids_for_doc(store, uuid)) == before_count
    end

    test "control: still merges a genuine sibling on a prose doc", %{store: store} do
      uuid = "prose-sibling"
      {_c, l, r} = build_l_r_off_c(store, uuid, @prose_body)

      assert {:ok, :merged, merge_commit} = SiblingMerger.maybe_merge_siblings(store, uuid)
      assert merge_commit.parent_id == l.id
      assert merge_commit.merge_parents == [r.id]

      {:ok, new_latest} = CommitStore.latest_commit(store, uuid)
      assert new_latest.id == merge_commit.id
    end
  end

  # ── 4. explicit-merge seam: Merger.merge/4 ────────────────────────────

  describe "explicit-merge seam — Merger.merge/4" do
    test ":translate is refused on a code doc", %{store: store} do
      uuid = "code-merger-translate"
      {_c, l, r} = build_l_r_off_c(store, uuid, @code_body)

      assert {:error, {:code_doc_merge_refused, :translate, ^uuid}} =
               Merger.merge(store, l.id, r.id, strategy: :translate)
    end

    test ":merge_snapshot is refused on a code doc", %{store: store} do
      uuid = "code-merger-snapshot"
      {_c, l, r} = build_l_r_off_c(store, uuid, @code_body)

      assert {:error, {:code_doc_merge_refused, :merge_snapshot, ^uuid}} =
               Merger.merge(store, l.id, r.id, strategy: :merge_snapshot)
    end

    test "control: :translate still succeeds on a prose doc", %{store: store} do
      uuid = "prose-merger-translate"
      {_c, l, r} = build_l_r_off_c(store, uuid, @prose_body)

      assert {:ok, commit} = Merger.merge(store, l.id, r.id, strategy: :translate)
      assert commit.metadata[:kind] == :merge
      assert commit.parent_id == l.id
      assert commit.merge_parents == [r.id]
    end

    test "control: :merge_snapshot still succeeds on a prose doc", %{store: store} do
      uuid = "prose-merger-snapshot"
      {_c, l, r} = build_l_r_off_c(store, uuid, @prose_body)

      assert {:ok, commit} = Merger.merge(store, l.id, r.id, strategy: :merge_snapshot)
      assert commit.metadata[:kind] == :snapshot

      l_ns = Namespace.current_namespace(l)
      r_ns = Namespace.current_namespace(r)
      assert commit.metadata[:snapshot_parents] == [l_ns, r_ns]
    end
  end
end
