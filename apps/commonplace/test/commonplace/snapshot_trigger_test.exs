defmodule Commonplace.SnapshotTriggerTest do
  @moduledoc """
  CX-4e2g: Snapshot-trigger primitive — mandatory-threshold check.

  `SnapshotTrigger.maybe_snapshot/3` reads the post-snapshot chain
  length for `doc_uuid`, compares it to a configured threshold, and
  either:

    - cuts a new snapshot via `CommitStore.snapshot/2` (returning
      `{:ok, :snapshotted, commit}`), or
    - no-ops (returning `{:ok, :below_threshold, detail}`).

  Safe to call concurrently from multiple hooks. Thanks to
  deterministic-anyone snapshotting (CX-umz), concurrent callers that
  observe the same parent chain produce the same snapshot commit id,
  so the CubDB writes collapse idempotently. Callers that serialize
  through the mailbox naturally see `chain_length = 0` after the
  first snapshot lands and no-op.

  This is the mandatory-threshold primitive the producer-side hook
  (CX-tvyb), heartbeat sweep (CX-fab5), reader lazy path (CX-fkvc),
  and explicit CLI command (CX-2ok0) will all sit on top of.
  """
  use ExUnit.Case, async: false

  alias Commonplace.SnapshotTrigger
  alias Commonplace.Store.CommitStore

  setup do
    dir = Path.join(System.tmp_dir!(), "snaptrig_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    name = :"snaptrig_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: name})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: name}
  end

  defp update_from(client_id, content) do
    doc = Yelixer.Doc.new(client_id: client_id)
    {doc, _} = Yelixer.Doc.get_or_create_type(doc, "t", :text)
    doc = Yelixer.Types.Text.insert(doc, "t", 0, content)
    Yelixer.Encoding.encode_update(doc)
  end

  defp seed_regular(store, uuid, n) do
    for i <- 1..n do
      CommitStore.create_chained_commit(
        store,
        uuid,
        update_from(1, "c#{i}"),
        %{kind: :regular}
      )
    end
  end

  defp count_snapshots(store, uuid) do
    store
    |> CommitStore.commit_ids_for_doc(uuid)
    |> Enum.count(fn id ->
      case CommitStore.get_commit(store, id) do
        {:ok, %{metadata: %{kind: :snapshot}}} -> true
        _ -> false
      end
    end)
  end

  describe "maybe_snapshot/3 — mandatory threshold" do
    test "no-ops when chain length below threshold", %{store: store} do
      uuid = "below"
      seed_regular(store, uuid, 3)

      before = count_snapshots(store, uuid)

      assert {:ok, :below_threshold, _detail} =
               SnapshotTrigger.maybe_snapshot(store, uuid, chain_length_threshold: 10)

      assert count_snapshots(store, uuid) == before
    end

    test "cuts a snapshot when chain length meets threshold", %{store: store} do
      uuid = "at"
      seed_regular(store, uuid, 5)

      before = count_snapshots(store, uuid)

      assert {:ok, :snapshotted, commit} =
               SnapshotTrigger.maybe_snapshot(store, uuid, chain_length_threshold: 5)

      assert commit.metadata[:kind] == :snapshot
      assert count_snapshots(store, uuid) == before + 1
    end

    test "cuts a snapshot when chain length exceeds threshold", %{store: store} do
      uuid = "above"
      seed_regular(store, uuid, 12)

      assert {:ok, :snapshotted, commit} =
               SnapshotTrigger.maybe_snapshot(store, uuid, chain_length_threshold: 5)

      assert commit.metadata[:kind] == :snapshot
    end

    test "below_threshold detail surfaces current chain length and threshold",
         %{store: store} do
      uuid = "detail"
      seed_regular(store, uuid, 3)

      assert {:ok, :below_threshold, detail} =
               SnapshotTrigger.maybe_snapshot(store, uuid, chain_length_threshold: 10)

      assert detail == {:chain_length, 3, 10}
    end
  end

  describe "chain length measurement" do
    test "chain_length = 0 when :latest is already a snapshot", %{store: store} do
      uuid = "already-snap"
      seed_regular(store, uuid, 5)

      assert {:ok, :snapshotted, _} =
               SnapshotTrigger.maybe_snapshot(store, uuid, chain_length_threshold: 5)

      # Now :latest is the snapshot — a second call should see chain_length 0.
      assert {:ok, :below_threshold, {:chain_length, 0, _}} =
               SnapshotTrigger.maybe_snapshot(store, uuid, chain_length_threshold: 5)
    end

    test "chain_length counts only commits strictly after the most recent snapshot",
         %{store: store} do
      uuid = "post-snap"
      seed_regular(store, uuid, 5)

      # Force a snapshot.
      assert {:ok, :snapshotted, _snap} =
               SnapshotTrigger.maybe_snapshot(store, uuid, chain_length_threshold: 5)

      # Add 2 more regular commits on top of the snapshot.
      seed_regular(store, uuid, 2)

      # Chain length since last snapshot is now 2, not 7.
      assert {:ok, :below_threshold, {:chain_length, 2, 10}} =
               SnapshotTrigger.maybe_snapshot(store, uuid, chain_length_threshold: 10)
    end

    test "no-ops safely when the uuid has no commits at all", %{store: store} do
      uuid = "empty"

      assert {:ok, :below_threshold, {:chain_length, 0, _}} =
               SnapshotTrigger.maybe_snapshot(store, uuid, chain_length_threshold: 5)
    end

    test "chain_length stops at :genesis (treated as an implicit snapshot boundary)",
         %{store: store} do
      uuid = "gen-only"
      {:ok, _genesis} = CommitStore.ensure_genesis(store, uuid)
      seed_regular(store, uuid, 4)

      # 4 real commits above genesis; genesis itself should NOT be counted.
      assert {:ok, :below_threshold, {:chain_length, 4, 10}} =
               SnapshotTrigger.maybe_snapshot(store, uuid, chain_length_threshold: 10)
    end
  end

  describe "configuration" do
    test "threshold configurable via opts :chain_length_threshold", %{store: store} do
      uuid = "opts"
      seed_regular(store, uuid, 7)

      # Threshold 100 — clearly below.
      assert {:ok, :below_threshold, _} =
               SnapshotTrigger.maybe_snapshot(store, uuid, chain_length_threshold: 100)

      # Threshold 3 — clearly above.
      assert {:ok, :snapshotted, _} =
               SnapshotTrigger.maybe_snapshot(store, uuid, chain_length_threshold: 3)
    end

    test "threshold defaults from Application env when opts omit it", %{store: store} do
      uuid = "app-env"
      prior = Application.get_env(:commonplace, :snapshot_chain_threshold)
      Application.put_env(:commonplace, :snapshot_chain_threshold, 4)

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:commonplace, :snapshot_chain_threshold)
          v -> Application.put_env(:commonplace, :snapshot_chain_threshold, v)
        end
      end)

      seed_regular(store, uuid, 4)

      assert {:ok, :snapshotted, _commit} = SnapshotTrigger.maybe_snapshot(store, uuid)
    end

    test "has a built-in default when neither opts nor Application env provide one",
         %{store: store} do
      # Explicitly delete the env so the hard-coded default kicks in.
      prior = Application.get_env(:commonplace, :snapshot_chain_threshold)
      Application.delete_env(:commonplace, :snapshot_chain_threshold)

      on_exit(fn ->
        case prior do
          nil -> :ok
          v -> Application.put_env(:commonplace, :snapshot_chain_threshold, v)
        end
      end)

      uuid = "default"
      seed_regular(store, uuid, 3)

      # With the hard-coded default (expected to be large, e.g. 100), chain_length=3 is below.
      assert {:ok, :below_threshold, {:chain_length, 3, default}} =
               SnapshotTrigger.maybe_snapshot(store, uuid)

      assert is_integer(default)
      assert default > 3
    end
  end

  describe "deterministic-anyone concurrency (CX-umz)" do
    test "N concurrent maybe_snapshot calls add exactly one new snapshot",
         %{store: store} do
      uuid = "concurrent-one"
      seed_regular(store, uuid, 5)

      snapshots_before = count_snapshots(store, uuid)
      n = 20

      tasks =
        for _ <- 1..n do
          Task.async(fn ->
            SnapshotTrigger.maybe_snapshot(store, uuid, chain_length_threshold: 5)
          end)
        end

      _ = Task.await_many(tasks, 10_000)

      assert count_snapshots(store, uuid) == snapshots_before + 1
    end

    test "all concurrent callers that snapshotted observe the same commit id",
         %{store: store} do
      uuid = "concurrent-same"
      seed_regular(store, uuid, 5)

      n = 10

      tasks =
        for _ <- 1..n do
          Task.async(fn ->
            SnapshotTrigger.maybe_snapshot(store, uuid, chain_length_threshold: 5)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      snapshot_ids =
        results
        |> Enum.filter(fn
          {:ok, :snapshotted, _} -> true
          _ -> false
        end)
        |> Enum.map(fn {:ok, :snapshotted, c} -> c.id end)

      # Every caller that wrote must have produced the SAME snapshot id.
      assert snapshot_ids != []
      assert Enum.uniq(snapshot_ids) |> length() == 1
    end

    test "callers that don't snapshot return :below_threshold with chain_length 0",
         %{store: store} do
      uuid = "concurrent-noop-after"
      seed_regular(store, uuid, 5)

      n = 10

      tasks =
        for _ <- 1..n do
          Task.async(fn ->
            SnapshotTrigger.maybe_snapshot(store, uuid, chain_length_threshold: 5)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      noop_details =
        results
        |> Enum.filter(fn
          {:ok, :below_threshold, _} -> true
          _ -> false
        end)
        |> Enum.map(fn {:ok, :below_threshold, d} -> d end)

      # Every no-op must report chain_length 0 — i.e., the caller saw
      # the post-snapshot chain state, not stale pre-snapshot state.
      for detail <- noop_details do
        assert match?({:chain_length, 0, _}, detail)
      end
    end
  end

  describe "heuristic lull-aware threshold (CX-592q)" do
    # Layered on top of the mandatory threshold: when `soft_chain_length_threshold`
    # and `lull_window_ms` are set together, the primitive fires a snapshot
    # when the post-snapshot chain is past the SOFT threshold AND the most
    # recent commit is older than `lull_window_ms`. The mandatory threshold
    # still wins — "hard" firing never gets gated by lull. If either
    # heuristic opt is omitted, behavior falls back to pure mandatory.
    #
    # Tests inject `now:` (millisecond timestamp) for deterministic time,
    # since commit timestamps are set via DateTime.utc_now() at write.

    defp latest_ts_ms(store, uuid) do
      {:ok, latest} = CommitStore.latest_commit(store, uuid)
      DateTime.to_unix(latest.timestamp, :millisecond)
    end

    test "sustained load: no lull → only mandatory fires, not heuristic",
         %{store: store} do
      uuid = "lull-sustained"
      seed_regular(store, uuid, 7)
      before = count_snapshots(store, uuid)
      now = latest_ts_ms(store, uuid) + 100

      assert {:ok, :below_threshold, {:chain_length, 7, 100}} =
               SnapshotTrigger.maybe_snapshot(store, uuid,
                 chain_length_threshold: 100,
                 soft_chain_length_threshold: 5,
                 lull_window_ms: 5_000,
                 now: now
               )

      assert count_snapshots(store, uuid) == before
    end

    test "bursty load with lull: fires during first post-interesting lull",
         %{store: store} do
      uuid = "lull-bursty"
      seed_regular(store, uuid, 7)
      before = count_snapshots(store, uuid)
      now = latest_ts_ms(store, uuid) + 10_000

      assert {:ok, :snapshotted, commit} =
               SnapshotTrigger.maybe_snapshot(store, uuid,
                 chain_length_threshold: 100,
                 soft_chain_length_threshold: 5,
                 lull_window_ms: 5_000,
                 now: now
               )

      assert commit.metadata[:kind] == :snapshot
      assert count_snapshots(store, uuid) == before + 1
    end

    test "below soft threshold: no-op even in lull",
         %{store: store} do
      uuid = "lull-below-soft"
      seed_regular(store, uuid, 3)
      now = latest_ts_ms(store, uuid) + 10_000

      assert {:ok, :below_threshold, {:chain_length, 3, 100}} =
               SnapshotTrigger.maybe_snapshot(store, uuid,
                 chain_length_threshold: 100,
                 soft_chain_length_threshold: 5,
                 lull_window_ms: 5_000,
                 now: now
               )
    end

    test "at soft threshold + lull boundary: lull defined as >= window_ms",
         %{store: store} do
      uuid = "lull-boundary"
      seed_regular(store, uuid, 5)

      latest_ms = latest_ts_ms(store, uuid)

      # Exactly at the window → in lull.
      assert {:ok, :snapshotted, _commit} =
               SnapshotTrigger.maybe_snapshot(store, uuid,
                 chain_length_threshold: 100,
                 soft_chain_length_threshold: 5,
                 lull_window_ms: 5_000,
                 now: latest_ms + 5_000
               )
    end

    test "mandatory threshold still wins regardless of lull state",
         %{store: store} do
      uuid = "lull-mandatory-wins"
      seed_regular(store, uuid, 6)
      now = latest_ts_ms(store, uuid) + 100

      # Even with no lull, mandatory threshold fires.
      assert {:ok, :snapshotted, _commit} =
               SnapshotTrigger.maybe_snapshot(store, uuid,
                 chain_length_threshold: 5,
                 soft_chain_length_threshold: 3,
                 lull_window_ms: 5_000,
                 now: now
               )
    end

    test "heuristic opts omitted: behavior unchanged from CX-4e2g mandatory-only",
         %{store: store} do
      uuid = "lull-nil-opts"
      seed_regular(store, uuid, 3)

      # No soft_chain_length_threshold, no lull_window_ms → pure mandatory.
      assert {:ok, :below_threshold, {:chain_length, 3, 100}} =
               SnapshotTrigger.maybe_snapshot(store, uuid, chain_length_threshold: 100)
    end

    test "soft threshold set but no lull_window_ms: ignored (both required together)",
         %{store: store} do
      uuid = "lull-soft-only"
      seed_regular(store, uuid, 7)
      before = count_snapshots(store, uuid)

      # Without lull_window_ms the heuristic layer is inert.
      assert {:ok, :below_threshold, {:chain_length, 7, 100}} =
               SnapshotTrigger.maybe_snapshot(store, uuid,
                 chain_length_threshold: 100,
                 soft_chain_length_threshold: 5
               )

      assert count_snapshots(store, uuid) == before
    end

    test "now defaults to System.system_time when omitted",
         %{store: store} do
      uuid = "lull-default-now"
      seed_regular(store, uuid, 7)
      before = count_snapshots(store, uuid)

      # With a very short window the default `now` (real wall clock) is
      # essentially guaranteed to be past the commit timestamp → fires.
      assert {:ok, :snapshotted, _commit} =
               SnapshotTrigger.maybe_snapshot(store, uuid,
                 chain_length_threshold: 100,
                 soft_chain_length_threshold: 5,
                 lull_window_ms: 0
               )

      assert count_snapshots(store, uuid) == before + 1
    end
  end
end
