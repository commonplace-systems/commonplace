defmodule Commonplace.Store.SnapshotReimportTest do
  @moduledoc """
  CX-x9vj: TARGETED INVESTIGATION TEST, not a regression guard.

  Open security question: can re-importing an old, validly-signed
  FULL-STATE snapshot commit (or re-chaining its raw update bytes) onto
  a doc whose `:latest` has since advanced cause CRDT LWW/clock
  resolution to silently REGRESS a field to an older value?

  Setup shared by all scenarios: a doc "A"/"B" YMap is written by THREE
  distinct client identities so the snapshot's re-minted item ids (which
  `Commonplace.Store.Snapshotter.deterministic_client_id/1` pins to the
  SMALLEST client id present in the source at snapshot time) are
  disjoint from the client id used for edits made *after* the snapshot.
  This is deliberately the least-favorable case for "coincidental
  idempotence via identical (client, clock) coordinates" — if a
  regression is reachable at all, this setup is where it should show up.

    * client 50  — writes A=1 (pre-snapshot)
    * client 200 — writes B=99 (pre-snapshot decoy, makes the snapshot's
      deterministic client_id computation non-trivial: min(50, 200) = 50)
    * snapshot S is cut here — its update bytes re-encode {A: 1, B: 99}
      under fresh ids minted with client_id 50 (the min of the source's
      clients).
    * client 100 — the doc's stable "writer hand" from here on — writes
      A=2, then B=3, chained after S.

  Each scenario below characterizes what ACTUALLY HAPPENS (not what
  "should" happen) when S — or its raw bytes — is reintroduced after
  that point. Assertions match OBSERVED behavior; see the per-test
  comments for what was found. If any scenario shows genuine regression
  (a field reading back an older value than the last real write), that
  is a P1 finding and must NOT be silently fixed here — see CX-x9vj.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.DocBuilder
  alias Yelixer.{BlockStore, Doc, Encoding}
  alias Yelixer.Types.YMap

  setup do
    dir = Path.join(System.tmp_dir!(), "snap_reimport_#{:rand.uniform(999_999_999)}")
    store_name = :"snap_reimport_store_#{System.unique_integer([:positive])}"
    {:ok, store} = CommitStore.start_link(data_dir: dir, name: store_name)

    on_exit(fn ->
      try do
        GenServer.stop(store)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(dir)
    end)

    %{store: store_name}
  end

  # Reconstruct the doc under a stable client_id "hand" (mirrors how a
  # real write funnel like CommandRouter/Sync.Agent would reconstruct
  # before minting its own next commit).
  defp reconstruct(store, uuid, client_id) do
    case DocBuilder.reconstruct_doc(store, uuid, client_id: client_id) do
      {:ok, doc} -> doc
      :none -> Doc.new(client_id: client_id)
    end
  end

  # Writes a single YMap key under `client_id`'s hand, diffed against the
  # doc's current state vector so the commit carries only the new ops
  # (not a full re-encode) — the ordinary "chained edit" shape.
  defp write_field(store, uuid, client_id, key, value) do
    doc = reconstruct(store, uuid, client_id)
    sv = BlockStore.state_vector(doc.store)
    doc = YMap.set(doc, "m", key, value)
    update = Encoding.encode_diff(doc, sv)
    CommitStore.create_chained_commit(store, uuid, update, %{kind: :regular})
  end

  defp read_fields(store, uuid) do
    doc = reconstruct(store, uuid, 999)
    {YMap.get(doc, "m", "A"), YMap.get(doc, "m", "B")}
  end

  defp seed(store) do
    uuid = "reimport-#{System.unique_integer([:positive])}"
    {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)

    # Pre-snapshot writes from two DIFFERENT clients so the snapshot's
    # deterministic client_id (the min) differs from the post-snapshot
    # writer's client_id (100) used below.
    write_field(store, uuid, 50, "A", 1)
    write_field(store, uuid, 200, "B", 99)

    {:ok, snapshot} = CommitStore.snapshot(store, uuid)

    # Post-snapshot writes from a third, stable writer identity.
    write_field(store, uuid, 100, "A", 2)
    write_field(store, uuid, 100, "B", 3)

    {uuid, snapshot}
  end

  describe "scenario (a): re-importing the SAME snapshot commit S is idempotent" do
    test "content-addressed dedup — import_commit sees S already present and no-ops", %{
      store: store
    } do
      {uuid, snapshot} = seed(store)

      assert read_fields(store, uuid) == {2, 3}

      # S's own commit id is already stored (it's how :latest got there
      # in the first place); import_commit's own dedup check
      # (`CubDB.get(state.db, {:commit, commit.id})` != nil) fires and it
      # replies :already_exists WITHOUT touching :latest at all — see
      # `Commonplace.Store.CommitStore.handle_validated_import/4`.
      assert CommitStore.import_commit(store, snapshot) == :already_exists

      # documents current behavior — see CX-x9vj: :latest is untouched by
      # an already-present commit id, so newer field values survive.
      assert read_fields(store, uuid) == {2, 3}
    end
  end

  describe "scenario (b): re-chaining S's raw update bytes as a NEW commit onto current :latest" do
    test "replaying S's bytes as a fresh :regular commit does not regress A or B", %{
      store: store
    } do
      {uuid, snapshot} = seed(store)
      assert read_fields(store, uuid) == {2, 3}

      # The sharp variant: don't re-import S itself — take its UPDATE
      # BYTES (still encoding {A: 1, B: 99} under client_id 50's fresh
      # ids) and land them as a BRAND NEW commit (a new content address,
      # since parent_id differs) chained onto the CURRENT :latest. This
      # simulates a buggy/malicious writer replaying old state as if it
      # were a fresh edit.
      replay_commit =
        CommitStore.create_chained_commit(store, uuid, snapshot.update, %{kind: :regular})

      # The replay DOES land as a distinct commit — it is not rejected
      # or deduped at the commit-store layer (different id, different
      # parent than S).
      refute replay_commit.id == snapshot.id

      result = read_fields(store, uuid)

      # documents current behavior — see CX-x9vj: OBSERVED result.
      #
      # DocBuilder.reconstruct_doc/2 trims to the most recent SNAPSHOT
      # commit (S) and replays forward from there — S, then the two
      # client-100 writes, then the replayed commit (S's bytes again).
      # Yelixer's `apply_update` is idempotent per (client, clock): S's
      # items (client_id 50, clocks 0..N) are already part of local
      # state via S itself, so re-applying byte-identical ops for the
      # SAME (client, clock) coordinates is a state-vector-checked no-op
      # — no new item is integrated, so there is no LWW conflict to
      # resolve and nothing regresses.
      assert result == {2, 3},
             "CX-x9vj FINDING: replaying snapshot S's raw bytes as a new commit " <>
               "changed observable state to #{inspect(result)} (expected {2, 3}) — " <>
               "this is the P1 regression the bead was filed to check for."
    end
  end

  describe "scenario (c): replay through a doc that has taken a NEWER snapshot after the writes" do
    test "old snapshot S is unreachable from the trim-to-latest-snapshot walk once a newer snapshot exists",
         %{store: store} do
      {uuid, snapshot} = seed(store)
      assert read_fields(store, uuid) == {2, 3}

      # Cut a NEW snapshot S2 capturing the current (correct) state.
      {:ok, snapshot_2} = CommitStore.snapshot(store, uuid)
      refute snapshot_2.id == snapshot.id
      assert read_fields(store, uuid) == {2, 3}

      # Now replay the OLD snapshot S's bytes again, chained after S2.
      _replay_commit =
        CommitStore.create_chained_commit(store, uuid, snapshot.update, %{kind: :regular})

      result = read_fields(store, uuid)

      # documents current behavior — see CX-x9vj: OBSERVED result.
      #
      # `trim_to_latest_snapshot/1` walks backward from the newest
      # commit and stops at the MOST RECENT snapshot — which is now S2,
      # not S. S's bytes are still landed as a dangling regular commit
      # on top of S2 in the DAG, and DocBuilder replays S2 forward
      # (S2's own re-encoded ids, minted under S2's own deterministic
      # client_id) followed by the stray replayed commit. Whether that
      # stray commit's (client 50) ids collide with anything in S2's
      # fresh id-space depends on S2's own deterministic client_id
      # choice — assert on the OBSERVED value rather than an assumed one.
      assert result == {2, 3},
             "CX-x9vj FINDING: replaying old snapshot S's bytes on top of a NEWER " <>
               "snapshot S2 changed observable state to #{inspect(result)} " <>
               "(expected {2, 3}) — potential P1, see bead."
    end
  end
end
