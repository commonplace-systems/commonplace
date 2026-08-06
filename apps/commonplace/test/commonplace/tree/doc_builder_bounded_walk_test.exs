defmodule Commonplace.Tree.DocBuilderBoundedWalkTest do
  @moduledoc """
  CX-ggdv: walk-bounding for pin reads.

  The fence is BYTE-NEUTRALITY — identical bytes, identical verdicts,
  only cheaper. So every test here is one of exactly two shapes:

    1. **the bound** — `chain_to/4` walks O(distance-to-nearest-snapshot)
       commits, asserted as a NUMBER via the
       `[:commonplace, :doc_builder, :chain_to]` telemetry, not as a
       stopwatch. Against the pre-CX-ggdv implementation these assertions
       are red: it walked the whole chain from `:latest` every time.

    2. **the neutrality** — the bounded walk and the retained
       head-anchored implementation return the same commits and the same
       reconstructed bytes, on every chain shape that could plausibly
       separate them: forked (cross-doc) lineage, snapshot-at-target,
       snapshot-free, genesis pins, cap truncation.

  `head_anchored_chain_to/3` is the pre-CX-ggdv code retained verbatim in
  behaviour, so "old path" below is not a reconstruction from memory — it
  is the same function, reachable via `require_head_reachable: true`.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Store.{Commit, CommitStore}
  alias Commonplace.Tree.DocBuilder
  alias Commonplace.Document.ContentType
  alias Yelixer.{Doc, Encoding}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_ggdv_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    name = :"ggdv_store_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  # ── walk instrumentation ───────────────────────────────────────────

  defp with_walk_count(fun) do
    ref = make_ref()
    me = self()
    handler = {__MODULE__, ref}

    :telemetry.attach(
      handler,
      [:commonplace, :doc_builder, :chain_to],
      fn _e, meas, meta, _ -> send(me, {ref, meas.walked, meta.mode}) end,
      nil
    )

    try do
      result = fun.()

      walks =
        Stream.repeatedly(fn ->
          receive do
            {^ref, n, mode} -> {n, mode}
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(&(&1 != nil))

      {result, walks}
    after
      :telemetry.detach(handler)
    end
  end

  # ── chain builders ─────────────────────────────────────────────────

  # A chain of `n` text-append commits on `uuid`. Returns the commit ids
  # oldest-first. Every commit is a genuine Yjs delta, so replaying a
  # wrong subset produces different bytes rather than the same bytes by
  # accident — which is what makes the neutrality assertions mean
  # something.
  defp build_chain(store, uuid, n, opts \\ []) do
    parent = Keyword.get(opts, :parent, nil)
    seed_doc = Keyword.get(opts, :seed_doc, Doc.new(client_id: 7))

    Enum.reduce(1..n, {seed_doc, parent, []}, fn i, {doc, parent_id, ids} ->
      before_sv = Yelixer.BlockStore.state_vector(doc.store)

      doc =
        if i == 1 and parent_id == nil do
          doc |> ContentType.create(:text, "f.txt") |> ContentType.insert_text(0, "a")
        else
          ContentType.insert_text(doc, 0, "#{rem(i, 10)}")
        end

      update =
        if i == 1 and parent_id == nil,
          do: Encoding.encode_update(doc),
          else: Encoding.encode_diff(doc, before_sv)

      commit =
        if parent_id == nil,
          do: CommitStore.create_commit(store, uuid, update, nil),
          else: CommitStore.create_commit(store, uuid, update, parent_id)

      {doc, commit.id, [commit.id | ids]}
    end)
    |> then(fn {doc, _last, ids} -> {Enum.reverse(ids), doc} end)
  end

  # Mint a real snapshot commit: full state of `doc`, kind `:snapshot`,
  # chained on `parent_id`. This is what bounds the walk.
  defp snapshot_commit(store, uuid, doc, parent_id) do
    CommitStore.create_commit(
      store,
      uuid,
      Encoding.encode_update(doc),
      parent_id,
      %{kind: :snapshot}
    )
  end

  defp bytes(%Doc{} = doc), do: Encoding.encode_update(doc)

  defp old_path(store, uuid, id),
    do: DocBuilder.chain_to(store, uuid, id, require_head_reachable: true)

  defp new_path(store, uuid, id), do: DocBuilder.chain_to(store, uuid, id)

  defp ids({:ok, commits}), do: Enum.map(commits, & &1.id)
  defp ids(:none), do: :none

  # ═══ 1. THE BOUND ══════════════════════════════════════════════════

  describe "the bound" do
    test "a pin just past a snapshot on a long chain walks only to the snapshot",
         %{store: store} do
      uuid = "deep-doc"
      {ids0, doc} = build_chain(store, uuid, 200)
      snap = snapshot_commit(store, uuid, doc, List.last(ids0))
      {ids1, _doc} = build_chain(store, uuid, 50, parent: snap.id, seed_doc: doc)
      pin = List.last(ids1)

      {result, walks} = with_walk_count(fn -> new_path(store, uuid, pin) end)

      assert {:ok, commits} = result
      # snapshot + 50 chained on top
      assert length(commits) == 51
      assert hd(commits).id == snap.id

      # THE deliverable, as a number. Pre-CX-ggdv this was 251 (the whole
      # chain from :latest), and on the production shape it was 10,000.
      assert [{51, :bounded}] = walks
    end

    test "the head-anchored path on the same chain walks the whole chain",
         %{store: store} do
      uuid = "deep-doc-2"
      {ids0, doc} = build_chain(store, uuid, 200)
      snap = snapshot_commit(store, uuid, doc, List.last(ids0))
      {ids1, _doc} = build_chain(store, uuid, 50, parent: snap.id, seed_doc: doc)
      pin = List.last(ids1)

      {_result, walks} = with_walk_count(fn -> old_path(store, uuid, pin) end)

      # genesis + 200 + snapshot + 50. This is the term CX-ggdv removes,
      # measured rather than asserted — and it is why the bound above is a
      # real change and not a restatement. 252 walked to replay 51.
      assert [{252, :head_anchored}] = walks
    end

    test "the walk does not grow when history is added BELOW the snapshot",
         %{store: store} do
      counts =
        for depth <- [50, 400] do
          uuid = "depth-#{depth}"
          {ids0, doc} = build_chain(store, uuid, depth)
          snap = snapshot_commit(store, uuid, doc, List.last(ids0))
          {ids1, _} = build_chain(store, uuid, 10, parent: snap.id, seed_doc: doc)

          {_r, [{n, :bounded}]} =
            with_walk_count(fn -> new_path(store, uuid, List.last(ids1)) end)

          n
        end

      # Independent of distance-to-genesis: THAT is the M3 finding closed.
      assert counts == [11, 11]
    end
  end

  # ═══ 2. BYTE NEUTRALITY, PER CHAIN SHAPE ═══════════════════════════

  describe "neutrality: same commits, same bytes" do
    test "snapshot-bounded chain, pins at every position", %{store: store} do
      uuid = "neutral-snap"
      {ids0, doc} = build_chain(store, uuid, 30)
      snap = snapshot_commit(store, uuid, doc, List.last(ids0))
      {ids1, _} = build_chain(store, uuid, 20, parent: snap.id, seed_doc: doc)

      all = ids0 ++ [snap.id] ++ ids1
      assert length(all) == 51

      for id <- all do
        assert ids(new_path(store, uuid, id)) == ids(old_path(store, uuid, id)),
               "chain_to diverged at #{Base.encode16(id, case: :lower)}"

        assert DocBuilder.reconstruct_doc_at(store, uuid, id) |> unwrap_bytes() ==
                 DocBuilder.reconstruct_doc_at(store, uuid, id, require_head_reachable: true)
                 |> unwrap_bytes(),
               "bytes diverged at #{Base.encode16(id, case: :lower)}"
      end
    end

    test "snapshot-free chain, pins at every position", %{store: store} do
      uuid = "neutral-flat"
      {all, _} = build_chain(store, uuid, 40)

      for id <- all do
        assert ids(new_path(store, uuid, id)) == ids(old_path(store, uuid, id))

        assert unwrap_bytes(DocBuilder.reconstruct_doc_at(store, uuid, id)) ==
                 unwrap_bytes(
                   DocBuilder.reconstruct_doc_at(store, uuid, id, require_head_reachable: true)
                 )
      end
    end

    test "the target itself being a snapshot replays exactly that one commit",
         %{store: store} do
      uuid = "neutral-at-snap"
      {ids0, doc} = build_chain(store, uuid, 12)
      snap = snapshot_commit(store, uuid, doc, List.last(ids0))
      {_ids1, _} = build_chain(store, uuid, 5, parent: snap.id, seed_doc: doc)

      assert ids(new_path(store, uuid, snap.id)) == [snap.id]
      assert ids(old_path(store, uuid, snap.id)) == [snap.id]
    end

    test "multiple snapshots: both paths pick the NEAREST one at or before the pin",
         %{store: store} do
      uuid = "neutral-multi-snap"
      {ids0, doc} = build_chain(store, uuid, 10)
      s1 = snapshot_commit(store, uuid, doc, List.last(ids0))
      {ids1, doc} = build_chain(store, uuid, 10, parent: s1.id, seed_doc: doc)
      s2 = snapshot_commit(store, uuid, doc, List.last(ids1))
      {ids2, _} = build_chain(store, uuid, 10, parent: s2.id, seed_doc: doc)

      # a pin between s1 and s2 must ground on s1, not s2
      mid = Enum.at(ids1, 5)
      assert hd(elem(new_path(store, uuid, mid), 1)).id == s1.id
      assert ids(new_path(store, uuid, mid)) == ids(old_path(store, uuid, mid))

      late = Enum.at(ids2, 5)
      assert hd(elem(new_path(store, uuid, late), 1)).id == s2.id
      assert ids(new_path(store, uuid, late)) == ids(old_path(store, uuid, late))
    end
  end

  # ═══ 3. F5 — CROSS-DOC (FORK) LINEAGE ══════════════════════════════

  describe "F5: chains whose commits carry a FOREIGN doc_uuid" do
    # 2.2% of production docs have in-chain commits stamped with another
    # document's uuid — fork lineage: the fork points `:latest` for the
    # NEW uuid at a chain whose older commits were written under the
    # SOURCE uuid. The old forward walk followed `parent_id` and never
    # filtered on `doc_uuid`; the backward walk must traverse them
    # identically. Fixture, not argument.
    setup %{store: store} do
      src = "fork-source"
      {src_ids, doc} = build_chain(store, src, 25)

      # The fork: new uuid, commits chained onto the SOURCE's history and
      # stamped with the new uuid — so the chain crosses doc_uuids at the
      # seam, exactly as production fork lineage does.
      forked = "fork-child"
      {child_ids, _} = build_chain(store, forked, 15, parent: List.last(src_ids), seed_doc: doc)

      %{src: src, src_ids: src_ids, forked: forked, child_ids: child_ids}
    end

    test "the seam commit's doc_uuid really is foreign (the fixture is the shape it claims)",
         %{store: store, src_ids: src_ids, forked: forked} do
      {:ok, seam} = CommitStore.get_commit(store, List.last(src_ids))
      assert seam.doc_uuid == "fork-source"
      assert seam.doc_uuid != forked
    end

    test "a pin below the seam replays the identical commit list on both paths",
         %{store: store, forked: forked, src_ids: src_ids, child_ids: child_ids} do
      for id <- src_ids ++ child_ids do
        assert ids(new_path(store, forked, id)) == ids(old_path(store, forked, id)),
               "cross-doc chain_to diverged at #{Base.encode16(id, case: :lower)}"
      end
    end

    test "cross-doc bytes are identical, and the walk crosses the seam",
         %{store: store, forked: forked, src_ids: src_ids, child_ids: child_ids} do
      pin = List.last(child_ids)

      assert unwrap_bytes(DocBuilder.reconstruct_doc_at(store, forked, pin)) ==
               unwrap_bytes(
                 DocBuilder.reconstruct_doc_at(store, forked, pin, require_head_reachable: true)
               )

      {:ok, commits} = new_path(store, forked, pin)
      # It walked all the way through the foreign-stamped section.
      assert length(commits) == length(src_ids) + length(child_ids)
      assert Enum.any?(commits, &(&1.doc_uuid == "fork-source"))
      assert Enum.any?(commits, &(&1.doc_uuid == forked))
    end

    test "a snapshot BELOW the seam still bounds the cross-doc walk", %{store: store} do
      src = "fork-source-2"
      {ids0, doc} = build_chain(store, src, 30)
      snap = snapshot_commit(store, src, doc, List.last(ids0))
      {ids1, doc} = build_chain(store, src, 5, parent: snap.id, seed_doc: doc)

      child = "fork-child-2"
      {child_ids, _} = build_chain(store, child, 4, parent: List.last(ids1), seed_doc: doc)

      pin = List.last(child_ids)
      {_r, [{n, :bounded}]} = with_walk_count(fn -> new_path(store, child, pin) end)

      # snapshot + 5 + 4, not 39: the bound holds across the doc_uuid seam.
      assert n == 10
      assert ids(new_path(store, child, pin)) == ids(old_path(store, child, pin))
    end
  end

  # ═══ 4. GENESIS PINS ═══════════════════════════════════════════════

  describe "genesis pins" do
    test "a genesis pin replays nothing on both paths (F7)", %{store: store} do
      uuid = "genesis-doc"
      g = Commit.genesis(uuid)
      :ok = import_or_create_genesis(store, g)
      {_ids, _} = build_chain(store, uuid, 5, parent: g.id)

      assert new_path(store, uuid, g.id) == {:ok, []}
      assert old_path(store, uuid, g.id) == {:ok, []}
    end

    test "genesis is rejected from the replay of a later pin, on both paths",
         %{store: store} do
      uuid = "genesis-doc-2"
      g = Commit.genesis(uuid)
      :ok = import_or_create_genesis(store, g)
      {chain_ids, _} = build_chain(store, uuid, 5, parent: g.id)
      pin = List.last(chain_ids)

      assert ids(new_path(store, uuid, pin)) == chain_ids
      assert ids(old_path(store, uuid, pin)) == chain_ids
      refute g.id in ids(new_path(store, uuid, pin))
    end
  end

  # ═══ 5. TRUNCATION SEMANTICS ═══════════════════════════════════════

  describe "cap truncation" do
    # The old window was anchored at HEAD (positions 0..limit-1 from
    # `:latest`); the backward walk's natural window is anchored at the
    # TARGET. On a snapshot-free chain deeper than the cap those two
    # windows select different baselines — so that case must NOT take the
    # bounded path. It falls back to the head-anchored implementation and
    # returns the old bytes.
    #
    # The real cap is 10,000, which is too deep to build in a unit test;
    # the DETECTOR is what this asserts, on the smallest chain that
    # exhibits the shape, by driving the store primitive at a small limit.
    test "the store primitive stops at the cap with no snapshot found", %{store: store} do
      uuid = "cap-doc"
      {chain_ids, _} = build_chain(store, uuid, 30)
      pin = List.last(chain_ids)

      walked = CommitStore.commit_log_from(store, pin, limit: 10, until_snapshot: true)

      assert length(walked) == 10
      refute Enum.any?(walked, &match?(%{metadata: %{kind: :snapshot}}, &1))
      # the chain provably continues — this is the ambiguous shape
      assert {:ok, _} = CommitStore.get_commit(store, List.last(walked).parent_id)
    end

    test "until_snapshot stops BEFORE the cap when a snapshot is in range",
         %{store: store} do
      uuid = "cap-doc-2"
      {ids0, doc} = build_chain(store, uuid, 30)
      snap = snapshot_commit(store, uuid, doc, List.last(ids0))
      {ids1, _} = build_chain(store, uuid, 3, parent: snap.id, seed_doc: doc)

      walked =
        CommitStore.commit_log_from(store, List.last(ids1), limit: 10_000, until_snapshot: true)

      assert length(walked) == 4
      assert List.last(walked).id == snap.id
    end

    test "until_snapshot: false is the untouched pre-CX-ggdv behaviour", %{store: store} do
      uuid = "cap-doc-3"
      {ids0, doc} = build_chain(store, uuid, 12)
      snap = snapshot_commit(store, uuid, doc, List.last(ids0))
      {ids1, _} = build_chain(store, uuid, 3, parent: snap.id, seed_doc: doc)

      # genesis + 12 + snapshot + 3
      walked = CommitStore.commit_log_from(store, List.last(ids1), limit: 10_000)
      assert length(walked) == 17

      # and the default is off, so every existing caller is unaffected
      assert CommitStore.commit_log(store, uuid, limit: 10_000) |> length() == 17
    end

    # The branch that actually decides the cap-truncated docs. Reaching it
    # for real needs a >10,000-commit snapshot-free chain, which is why it
    # went untested until CX-ggdv made `max_commit_log_limit/0`
    # overridable. With the cap at 20 the shape is identical and fits in a
    # unit test.
    defp lower_the_cap! do
      Application.put_env(:commonplace, :max_commit_log_limit, 20)

      ExUnit.Callbacks.on_exit(fn ->
        Application.delete_env(:commonplace, :max_commit_log_limit)
      end)
    end

    test "a pin on a snapshot-free chain deeper than the cap returns the OLD window",
         %{store: store} do
      lower_the_cap!()
      uuid = "over-cap"
      {all, _} = build_chain(store, uuid, 60)

      # `all` holds the 60 non-genesis commits ascending, so head is
      # index 59 and the 20-commit head-anchored window is indices 40..59.
      # Every pin INSIDE that window must match the old path exactly.
      for idx <- [59, 55, 50, 45, 41] do
        pin = Enum.at(all, idx)

        assert ids(new_path(store, uuid, pin)) == ids(old_path(store, uuid, pin)),
               "cap-fallback diverged at ascending index #{idx}"
      end
    end

    test "the cap fallback reuses the backward walk instead of walking twice",
         %{store: store} do
      lower_the_cap!()
      uuid = "over-cap-2"
      {all, _} = build_chain(store, uuid, 60)
      pin = Enum.at(all, 55)

      {result, walks} = with_walk_count(fn -> new_path(store, uuid, pin) end)

      assert {:ok, _} = result
      # ONE walk event, mode :cap_fallback — not a bounded walk followed
      # by a second full head-anchored walk. Re-running the old walk here
      # measured 1.7 s → 3.8 s on a real >10,000-commit doc; a
      # performance ticket that makes its worst case worse has not
      # shipped.
      assert [{20, :cap_fallback}] = walks
    end

    # The reachability change again, in its cap-shaped form: a pin FURTHER
    # from head than the cap was outside the old window entirely, so the
    # old path called it "not on the chain". The backward walk sees a pin
    # that is perfectly well grounded in its own history and reconstructs
    # it. Strictly more information, and a byte change all the same, so it
    # is asserted rather than discovered later.
    test "a target beyond the cap from head: old :none, bounded reconstructs",
         %{store: store} do
      lower_the_cap!()
      uuid = "over-cap-3"
      {all, _} = build_chain(store, uuid, 60)
      # index 5 is ~54 back from head, far outside a 20-commit window
      pin = Enum.at(all, 5)

      assert old_path(store, uuid, pin) == :none
      assert {:ok, commits} = new_path(store, uuid, pin)
      # grounded at genesis (rejected) and replaying its own 6 commits
      assert length(commits) == 6
    end
  end

  # ═══ 6. REACHABILITY — THE ONE NAMED SEMANTIC CHANGE ═══════════════

  describe "reachability (the `:none`-as-ancestry-oracle contract)" do
    test "a commit on an abandoned branch: old path :none, bounded path reconstructs",
         %{store: store} do
      uuid = "abandoned"
      {chain_ids, doc} = build_chain(store, uuid, 6)
      # a commit that exists but is NOT reachable from :latest — the shape
      # a reflog reset leaves behind
      orphan =
        CommitStore.create_commit(
          store,
          uuid,
          Encoding.encode_diff(
            ContentType.insert_text(doc, 0, "z"),
            Yelixer.BlockStore.state_vector(doc.store)
          ),
          Enum.at(chain_ids, 2)
        )

      # rewind :latest so the orphan is off the head chain
      CommitStore.set_latest(store, uuid, List.last(chain_ids))

      assert old_path(store, uuid, orphan.id) == :none
      assert {:ok, _} = new_path(store, uuid, orphan.id)
    end

    test "a commit absent from the store is :none on both paths", %{store: store} do
      {_ids, _} = build_chain(store, "present", 3)
      missing = :crypto.hash(:sha256, "nope")

      assert new_path(store, "present", missing) == :none
      assert old_path(store, "present", missing) == :none
    end

    test "Fork keeps its ancestry-oracle contract", %{store: store} do
      {_a_ids, _} = build_chain(store, "fork-a", 4)
      {b_ids, _} = build_chain(store, "fork-b", 4)

      # a commit from doc B handed to a fork of doc A: refused, as before
      assert DocBuilder.reconstruct_doc_at(store, "fork-a", List.last(b_ids),
               require_head_reachable: true
             ) == :none
    end
  end

  defp unwrap_bytes({:ok, %Doc{} = d}), do: bytes(d)
  defp unwrap_bytes(other), do: other

  defp import_or_create_genesis(store, %Commit{} = g) do
    case CommitStore.import_commit(store, g) do
      {:ok, _} -> :ok
      :ok -> :ok
      other -> flunk("could not seed genesis: #{inspect(other)}")
    end
  end
end
