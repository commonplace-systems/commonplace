defmodule Commonplace.Sync.TwoPeerMergeE2ETest do
  @moduledoc """
  CX-69d7: end-to-end merge cohort across two independent peers.

  Per jes (2026-04-19): the contract is observable convergence —
  Text.to_string / XML structure / map lookups on both peers reflect
  both sides' edits after the merge cycle completes. Byte-identical
  persisted commit DAGs are NOT a requirement (parked as CX-8k1v
  optimization). Each peer may end up with a different merge-commit
  id; what matters is that each peer's reconstructed doc state is
  observably equivalent.

  Combines:
    * CX-bv3 / CX-fzi  — commit struct + deterministic genesis
    * CX-4qn1          — distributed sibling-commit primitive
    * CX-csmr          — strategy policy layer (default + override)
    * CX-atk3 / CX-7cm1 — late-edit auto-translation + sync hook
    * CX-zraz / CX-8qzi — user-initiated merge (CLI / magenta)

  Drives the merge via `MergePolicy.merge/4` directly. The bead allows
  either the CLI surface (CX-zraz, parked) or magenta (CX-8qzi); the
  magenta path through Phoenix.PubSub broadcasts every command to
  every subscribed handler, which is the right production semantics
  but obscures per-peer convergence in a same-VM test. Direct
  invocation models the "each peer's user fires their own merge"
  case cleanly.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Document.ContentType
  alias Commonplace.SiblingMerger
  alias Commonplace.Store.{Commit, CommitStore, MergePolicy}
  alias Commonplace.Sync.NodeSync
  alias Commonplace.Tree.DocBuilder
  alias Yelixer.{Doc, Encoding}
  alias Yelixer.Types.Text

  setup do
    dir_a = Path.join(System.tmp_dir!(), "cp_e2e_a_#{:rand.uniform(1_000_000)}")
    dir_b = Path.join(System.tmp_dir!(), "cp_e2e_b_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir_a)
    File.mkdir_p!(dir_b)

    name_a = :"e2e_store_a_#{:rand.uniform(1_000_000)}"
    name_b = :"e2e_store_b_#{:rand.uniform(1_000_000)}"
    {:ok, pid_a} = CommitStore.start_link(data_dir: dir_a, name: name_a)
    {:ok, pid_b} = CommitStore.start_link(data_dir: dir_b, name: name_b)

    on_exit(fn ->
      if Process.alive?(pid_a), do: GenServer.stop(pid_a)
      if Process.alive?(pid_b), do: GenServer.stop(pid_b)
      File.rm_rf!(dir_a)
      File.rm_rf!(dir_b)
    end)

    %{store_a: name_a, store_b: name_b}
  end

  # Establish the same C snapshot on both peers (content-addressed, so
  # the resulting commit ids are identical) and produce divergent
  # local edits L (peer A) and R (peer B). Each peer holds its own
  # local commit on :latest.
  defp seed_diverged_text(store_a, store_b, uuid) do
    {:ok, _} = CommitStore.ensure_genesis(store_a, uuid)
    {:ok, _} = CommitStore.ensure_genesis(store_b, uuid)

    base_doc = Doc.new(client_id: 1)
    {base_doc, _} = Doc.get_or_create_type(base_doc, "t", :text)
    base_doc = Text.insert(base_doc, "t", 0, "abc")
    base_update = Encoding.encode_update(base_doc)

    CommitStore.create_chained_commit(store_a, uuid, base_update, %{kind: :regular})
    CommitStore.create_chained_commit(store_b, uuid, base_update, %{kind: :regular})

    # Both peers cut the same content-addressed snapshot. The snapshot
    # commits have identical ids by construction.
    {:ok, snap_a} = CommitStore.snapshot(store_a, uuid)
    {:ok, snap_b} = CommitStore.snapshot(store_b, uuid)

    assert snap_a.id == snap_b.id,
           "test fixture invariant: snapshots must be byte-identical across peers"

    {:ok, base} = Encoding.apply_update(Doc.new(), snap_a.update)
    base_post_snap = Encoding.encode_update(base)

    # Peer A appends "X" via its own client_id, chained on top of the
    # snapshot.
    doc_l = Doc.new(client_id: 100)
    {doc_l, _} = Doc.get_or_create_type(doc_l, "t", :text)
    {:ok, doc_l} = Encoding.apply_update(doc_l, base_post_snap)
    doc_l = Text.insert(doc_l, "t", 3, "X")

    l_commit =
      CommitStore.create_chained_commit(
        store_a,
        uuid,
        Encoding.encode_update(doc_l),
        %{kind: :regular}
      )

    # Peer B appends "Y" via its own client_id, chained on top of the
    # snapshot. Different namespace from L.
    doc_r = Doc.new(client_id: 200)
    {doc_r, _} = Doc.get_or_create_type(doc_r, "t", :text)
    {:ok, doc_r} = Encoding.apply_update(doc_r, base_post_snap)
    doc_r = Text.insert(doc_r, "t", 3, "Y")

    r_commit =
      CommitStore.create_chained_commit(
        store_b,
        uuid,
        Encoding.encode_update(doc_r),
        %{kind: :regular}
      )

    {snap_a, l_commit, r_commit}
  end

  # Bidirectional sibling exchange via the CX-7cm1 sync hook
  # (`NodeSync.import_with_translation`). Each peer learns about the
  # other's divergent commit; the hook invokes the late-edit
  # auto-translator (CX-atk3) when the incoming commit's
  # snapshot_parent doesn't match the local epoch, so cross-epoch
  # peers auto-recover at sync time. Imports do NOT touch `:latest`.
  defp sibling_exchange(store_a, store_b, uuid) do
    ids_a = CommitStore.commit_ids_for_doc(store_a, uuid)
    ids_b = CommitStore.commit_ids_for_doc(store_b, uuid)

    {missing_a, missing_b} = NodeSync.diff_commit_ids(ids_a, ids_b)

    Enum.each(missing_a, fn id ->
      {:ok, c} = CommitStore.get_commit(store_b, id)
      NodeSync.import_with_translation(store_a, c)
    end)

    Enum.each(missing_b, fn id ->
      {:ok, c} = CommitStore.get_commit(store_a, id)
      NodeSync.import_with_translation(store_b, c)
    end)

    :ok
  end

  defp reconstruct_text(store, uuid) do
    {:ok, doc} = DocBuilder.reconstruct_doc(store, uuid)
    Text.to_string(doc, "t")
  end

  describe ":translate strategy" do
    test "two peers diverge, each merges locally, both observable texts contain X and Y",
         %{store_a: store_a, store_b: store_b} do
      uuid = "e2e-translate"
      {_snap, l, r} = seed_diverged_text(store_a, store_b, uuid)

      :ok = sibling_exchange(store_a, store_b, uuid)

      # Each peer invokes merge with its own :latest as l_id, the
      # imported sibling as other_ref. Both succeed locally because
      # commit.parent_id = local :latest, so the CAS gate passes.
      {:ok, m_a} =
        MergePolicy.merge(store_a, l.id, r.id, strategy: :translate)

      :ok = persist_or_skip(store_a, m_a)

      {:ok, m_b} =
        MergePolicy.merge(store_b, r.id, l.id, strategy: :translate)

      :ok = persist_or_skip(store_b, m_b)

      text_a = reconstruct_text(store_a, uuid)
      text_b = reconstruct_text(store_b, uuid)

      assert String.contains?(text_a, "abc"),
             "peer A text missing baseline: #{inspect(text_a)}"

      assert String.contains?(text_a, "X"),
             "peer A text missing local edit X: #{inspect(text_a)}"

      assert String.contains?(text_a, "Y"),
             "peer A text missing imported edit Y: #{inspect(text_a)}"

      assert String.contains?(text_b, "abc"),
             "peer B text missing baseline: #{inspect(text_b)}"

      assert String.contains?(text_b, "X"),
             "peer B text missing imported edit X: #{inspect(text_b)}"

      assert String.contains?(text_b, "Y"),
             "peer B text missing local edit Y: #{inspect(text_b)}"
    end
  end

  describe ":merge_snapshot strategy" do
    test "two peers diverge, each merges locally, both observable texts contain X and Y",
         %{store_a: store_a, store_b: store_b} do
      uuid = "e2e-snap"
      {_snap, l, r} = seed_diverged_text(store_a, store_b, uuid)

      :ok = sibling_exchange(store_a, store_b, uuid)

      {:ok, m_a} =
        MergePolicy.merge(store_a, l.id, r.id, strategy: :merge_snapshot)

      :ok = persist_or_skip(store_a, m_a)

      {:ok, m_b} =
        MergePolicy.merge(store_b, r.id, l.id, strategy: :merge_snapshot)

      :ok = persist_or_skip(store_b, m_b)

      text_a = reconstruct_text(store_a, uuid)
      text_b = reconstruct_text(store_b, uuid)

      for text <- [text_a, text_b] do
        assert String.contains?(text, "abc"), "missing baseline: #{inspect(text)}"
        assert String.contains?(text, "X"), "missing X: #{inspect(text)}"
        assert String.contains?(text, "Y"), "missing Y: #{inspect(text)}"
      end
    end
  end

  describe "SiblingMerger path (CX-4qn1 + CX-csmr)" do
    test "each peer auto-merges off-chain siblings — observable state converges",
         %{store_a: store_a, store_b: store_b} do
      # Exercises CX-4qn1: distributed siblings imported via sync stay
      # off `:latest`. SiblingMerger.maybe_merge_siblings folds them in
      # via Merger.merge with the local head as parent, so the CAS gate
      # passes locally. Default strategy comes from the CX-csmr policy.
      # Observable convergence without explicit user invocation.
      uuid = "e2e-sibmerger"
      {_snap, _l, _r} = seed_diverged_text(store_a, store_b, uuid)

      :ok = sibling_exchange(store_a, store_b, uuid)

      {:ok, :merged, _} = SiblingMerger.maybe_merge_siblings(store_a, uuid)
      {:ok, :merged, _} = SiblingMerger.maybe_merge_siblings(store_b, uuid)

      text_a = reconstruct_text(store_a, uuid)
      text_b = reconstruct_text(store_b, uuid)

      for text <- [text_a, text_b] do
        assert String.contains?(text, "abc"), "missing baseline: #{inspect(text)}"
        assert String.contains?(text, "X"), "missing X: #{inspect(text)}"
        assert String.contains?(text, "Y"), "missing Y: #{inspect(text)}"
      end
    end
  end

  # CX-hmkz cross-epoch scenario fixture using the production
  # ContentType envelope (raw Text "t" bypasses ContentType and hits
  # the CX-k250 fixture artifact). Peer A takes a POST-divergence
  # snapshot so peer A and peer B end up in different namespaces.
  defp seed_diverged_content_cross_epoch(store_a, store_b, uuid) do
    {:ok, _} = CommitStore.ensure_genesis(store_a, uuid)
    {:ok, _} = CommitStore.ensure_genesis(store_b, uuid)

    base_doc = Doc.new(client_id: 1)
    base_doc = ContentType.create(base_doc, :text, "greet.txt")
    base_doc = ContentType.insert_text(base_doc, 0, "abc")
    base_update = Encoding.encode_update(base_doc)

    CommitStore.create_chained_commit(store_a, uuid, base_update, %{kind: :regular})
    CommitStore.create_chained_commit(store_b, uuid, base_update, %{kind: :regular})

    {:ok, snap_a} = CommitStore.snapshot(store_a, uuid)
    {:ok, snap_b} = CommitStore.snapshot(store_b, uuid)
    assert snap_a.id == snap_b.id

    {:ok, base} = Encoding.apply_update(Doc.new(), snap_a.update)
    base_post_snap = Encoding.encode_update(base)

    # Peer A: insert X, then take a SECOND snapshot (new epoch)
    doc_l = Doc.new(client_id: 100)
    {:ok, doc_l} = Encoding.apply_update(doc_l, base_post_snap)
    doc_l = ContentType.insert_text(doc_l, 0, "X")

    _l_commit =
      CommitStore.create_chained_commit(
        store_a,
        uuid,
        Encoding.encode_update(doc_l),
        %{kind: :regular}
      )

    {:ok, snap_l} = CommitStore.snapshot(store_a, uuid)

    # Peer B: insert Y at 3 (after "abc") — still in C's namespace
    doc_r = Doc.new(client_id: 200)
    {:ok, doc_r} = Encoding.apply_update(doc_r, base_post_snap)
    doc_r = ContentType.insert_text(doc_r, 3, "Y")

    r_commit =
      CommitStore.create_chained_commit(
        store_b,
        uuid,
        Encoding.encode_update(doc_r),
        %{kind: :regular}
      )

    {snap_a, snap_l, r_commit}
  end

  defp reconstruct_content(store, uuid) do
    {:ok, doc} = DocBuilder.reconstruct_doc(store, uuid)
    ContentType.get_content(doc)
  end

  describe "cross-epoch two-peer merge (CX-hmkz)" do
    test "peer A post-divergence snapshot + bilateral sibling-merger — no duplication",
         %{store_a: store_a, store_b: store_b} do
      uuid = "e2e-hmkz-cross-epoch"
      {_snap_a, _snap_l, _r_commit} = seed_diverged_content_cross_epoch(store_a, store_b, uuid)

      :ok = sibling_exchange(store_a, store_b, uuid)

      {:ok, :merged, _} = SiblingMerger.maybe_merge_siblings(store_a, uuid, strategy: :translate)
      {:ok, :merged, _} = SiblingMerger.maybe_merge_siblings(store_b, uuid, strategy: :translate)

      content_a = reconstruct_content(store_a, uuid)
      content_b = reconstruct_content(store_b, uuid)

      for {content, peer} <- [{content_a, :a}, {content_b, :b}] do
        assert String.contains?(content, "abc"),
               "peer #{peer} missing baseline: #{inspect(content)}"

        assert String.contains?(content, "X"),
               "peer #{peer} missing X: #{inspect(content)}"

        assert String.contains?(content, "Y"),
               "peer #{peer} missing Y: #{inspect(content)}"

        refute String.length(content) > 5,
               "peer #{peer} duplication: #{inspect(content)}"
      end
    end
  end

  defp persist_or_skip(store, %Commit{} = commit) do
    case CommitStore.write_prebuilt_commit_cas(store, commit) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, :parent_moved} -> :ok
      other -> other
    end
  end

end
