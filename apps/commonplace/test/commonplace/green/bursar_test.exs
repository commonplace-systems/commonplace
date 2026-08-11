defmodule Commonplace.Green.BursarTest do
  use ExUnit.Case, async: false

  alias Commonplace.Store.CommitStore
  alias Commonplace.Green.Bursar
  alias Commonplace.Tree.Schema
  alias Commonplace.Tree.DocBuilder
  alias Commonplace.Dataflow.RedLog

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bursar_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store_name = :"bursar_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store_name})
    on_exit(fn -> File.rm_rf!(dir) end)

    # Create root schema
    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(store_name, root_uuid, update, nil)

    %{store: store_name, root: root_uuid, dir: dir}
  end

  defp start_bursar(ctx, name \\ nil, opts \\ []) do
    name = name || :"bursar_#{:rand.uniform(1_000_000)}"
    {:ok, pid} = Bursar.start_link(
      [root_uuid: ctx.root,
       store: ctx.store,
       name: name] ++ opts
    )
    on_exit(fn ->
      if Process.alive?(pid), do: (try do GenServer.stop(pid) catch (:exit, _ -> :ok) end)
    end)
    {pid, name}
  end

  describe "acquire/release basics" do
    test "acquire available token succeeds", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, info} = Bursar.acquire(name, "readme.txt", "alice")
      assert info.holder == "alice"
      assert %DateTime{} = info.acquired_at
    end

    test "acquire held token is denied", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice")
      assert {:denied, %{holder: "alice"}} = Bursar.acquire(name, "readme.txt", "bob")
    end

    test "acquire is idempotent for same holder", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, info1} = Bursar.acquire(name, "readme.txt", "alice")
      assert {:ok, info2} = Bursar.acquire(name, "readme.txt", "alice")
      assert info1.acquired_at == info2.acquired_at
    end

    test "release held token succeeds", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice")
      assert :ok = Bursar.release(name, "readme.txt", "alice")
    end

    test "release by non-holder fails", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice")
      assert {:error, {:not_holder, "alice"}} = Bursar.release(name, "readme.txt", "bob")
    end

    test "release unheld token fails", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:error, :not_held} = Bursar.release(name, "readme.txt", "alice")
    end

    test "token available after release", ctx do
      {_pid, name} = start_bursar(ctx)

      Bursar.acquire(name, "readme.txt", "alice")
      Bursar.release(name, "readme.txt", "alice")
      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "bob")
    end
  end

  describe "query" do
    test "query available token", ctx do
      {_pid, name} = start_bursar(ctx)

      assert :available = Bursar.query(name, "readme.txt")
    end

    test "query held token", ctx do
      {_pid, name} = start_bursar(ctx)

      Bursar.acquire(name, "readme.txt", "alice")
      assert {:held, %{holder: "alice"}} = Bursar.query(name, "readme.txt")
    end
  end

  describe "list_tokens" do
    test "lists all held tokens", ctx do
      {_pid, name} = start_bursar(ctx)

      Bursar.acquire(name, "a.txt", "alice")
      Bursar.acquire(name, "b.txt", "bob")

      tokens = Bursar.list_tokens(name)
      assert map_size(tokens) == 2
      assert tokens["a.txt"].holder == "alice"
      assert tokens["b.txt"].holder == "bob"
    end
  end

  describe "force_release" do
    test "force-releases a held token", ctx do
      {_pid, name} = start_bursar(ctx)

      Bursar.acquire(name, "readme.txt", "alice")
      assert :ok = Bursar.force_release(name, "readme.txt")
      assert :available = Bursar.query(name, "readme.txt")
    end

    test "force_release on unheld token fails", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:error, :not_held} = Bursar.force_release(name, "readme.txt")
    end
  end

  describe "persistence across restarts" do
    test "tokens survive restart", ctx do
      {pid, _name} = start_bursar(ctx, :persist_test)

      Bursar.acquire(:persist_test, "readme.txt", "alice")
      Bursar.acquire(:persist_test, "docs/guide.md", "bob")
      GenServer.stop(pid)

      # Start a new bursar with the same root — should reload tokens
      {:ok, _pid2} = Bursar.start_link(
        root_uuid: ctx.root,
        store: ctx.store,
        name: :persist_test2
      )

      tokens = Bursar.list_tokens(:persist_test2)
      assert tokens["readme.txt"].holder == "alice"
      assert tokens["docs/guide.md"].holder == "bob"

      GenServer.stop(:persist_test2)
    end
  end

  describe "multiple independent tokens" do
    test "different paths are independent", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, _} = Bursar.acquire(name, "a.txt", "alice")
      assert {:ok, _} = Bursar.acquire(name, "b.txt", "bob")
      assert {:denied, _} = Bursar.acquire(name, "a.txt", "bob")
      assert {:ok, _} = Bursar.acquire(name, "c.txt", "bob")
    end
  end

  describe "TTL expiry" do
    test "acquire with TTL stores ttl_ms", ctx do
      {_pid, name} = start_bursar(ctx, nil, sweep_interval: 60_000)

      assert {:ok, info} = Bursar.acquire(name, "readme.txt", "alice", ttl: 5000)
      assert info.ttl_ms == 5000
    end

    test "acquire without TTL has nil ttl_ms", ctx do
      {_pid, name} = start_bursar(ctx, nil, sweep_interval: 60_000)

      assert {:ok, info} = Bursar.acquire(name, "readme.txt", "alice")
      assert info.ttl_ms == nil
    end

    test "expired token is released by sweep", ctx do
      {pid, name} = start_bursar(ctx, nil, sweep_interval: 60_000)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice", ttl: 100)
      Process.sleep(200)
      send(pid, :sweep_ttl)
      # Give the GenServer time to process the sweep message
      Process.sleep(50)

      assert :available = Bursar.query(name, "readme.txt")
    end

    test "non-expired token survives sweep", ctx do
      {pid, name} = start_bursar(ctx, nil, sweep_interval: 60_000)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice", ttl: 10_000)
      send(pid, :sweep_ttl)
      # Give the GenServer time to process the sweep message
      Process.sleep(50)

      assert {:held, %{holder: "alice"}} = Bursar.query(name, "readme.txt")
    end

    test "expired token logs an event", ctx do
      {pid, name} = start_bursar(ctx, nil, sweep_interval: 60_000)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice", ttl: 100)
      Process.sleep(200)
      send(pid, :sweep_ttl)
      # Give the GenServer time to process the sweep message
      Process.sleep(50)

      # Read the red log by finding the __bursar.log UUID from the root schema
      {:ok, schema} = DocBuilder.reconstruct_snapshot(ctx.store, ctx.root)
      {:ok, log_entry} = Schema.get_entry(schema, "__bursar.log")
      log = RedLog.load(log_entry.node_id, ctx.store)
      events = RedLog.read(log)

      expired_events = Enum.filter(events, fn e -> e["event"] == "expired" end)
      assert length(expired_events) >= 1

      expired_event = List.last(expired_events)
      assert expired_event["path"] == "readme.txt"
      assert expired_event["holder"] == "alice"
      assert expired_event["ttl_ms"] == 100
    end
  end

  describe "transfer" do
    test "transfer hands off to new holder", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice")
      assert {:ok, info} = Bursar.transfer(name, "readme.txt", "alice", "bob")
      assert info.holder == "bob"
      assert {:held, %{holder: "bob"}} = Bursar.query(name, "readme.txt")
    end

    test "transfer by non-holder is rejected", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice")
      assert {:error, {:not_holder, "alice"}} =
               Bursar.transfer(name, "readme.txt", "bob", "carol")
      assert {:held, %{holder: "alice"}} = Bursar.query(name, "readme.txt")
    end

    test "transfer on unheld token fails", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:error, :not_held} = Bursar.transfer(name, "readme.txt", "alice", "bob")
    end

    test "transfer preserves acquired_at and ttl_ms", ctx do
      {_pid, name} = start_bursar(ctx, nil, sweep_interval: 60_000)

      assert {:ok, original} = Bursar.acquire(name, "readme.txt", "alice", ttl: 10_000)
      Process.sleep(20)
      assert {:ok, after_transfer} = Bursar.transfer(name, "readme.txt", "alice", "bob")
      assert after_transfer.acquired_at == original.acquired_at
      assert after_transfer.ttl_ms == 10_000
    end

    test "transfer logs an event with from/to", ctx do
      {_pid, name} = start_bursar(ctx)

      Bursar.acquire(name, "readme.txt", "alice")
      assert {:ok, _} = Bursar.transfer(name, "readme.txt", "alice", "bob")

      {:ok, schema} = DocBuilder.reconstruct_snapshot(ctx.store, ctx.root)
      {:ok, log_entry} = Schema.get_entry(schema, "__bursar.log")
      log = RedLog.load(log_entry.node_id, ctx.store)
      events = RedLog.read(log)

      transfer_events = Enum.filter(events, fn e -> e["event"] == "transfer" end)
      assert length(transfer_events) == 1
      [e] = transfer_events
      assert e["path"] == "readme.txt"
      assert e["from"] == "alice"
      assert e["to"] == "bob"
    end

    test "transferred token survives restart with new holder", ctx do
      {pid, _name} = start_bursar(ctx, :xfer_persist)

      Bursar.acquire(:xfer_persist, "readme.txt", "alice")
      Bursar.transfer(:xfer_persist, "readme.txt", "alice", "bob")
      GenServer.stop(pid)

      {:ok, _pid2} = Bursar.start_link(
        root_uuid: ctx.root,
        store: ctx.store,
        name: :xfer_persist2
      )

      assert {:held, %{holder: "bob"}} = Bursar.query(:xfer_persist2, "readme.txt")
      GenServer.stop(:xfer_persist2)
    end

    test "transfer via magenta", ctx do
      {_pid, name} = start_bursar(ctx)

      Bursar.acquire(name, "readme.txt", "alice")

      Commonplace.Dataflow.Magenta.send(
        "__bursar",
        Commonplace.Dataflow.Magenta.message(
          "green:transfer",
          "alice",
          %{"path" => "readme.txt", "from" => "alice", "to" => "bob"}
        )
      )

      Process.sleep(50)
      assert {:held, %{holder: "bob"}} = Bursar.query(name, "readme.txt")
    end
  end

  # Lease semantics (move #4 CX-tdkq.7, REVISED by CX-i9ca): liveness is
  # EPHEMERAL, ownership is DURABLE. Renewals never touch the store. As of
  # CX-i9ca, ephemeral (ttl'd) tokens are NOT persisted at all — a Bursar
  # restart drops every lease, and holders RE-ACQUIRE (re-election) rather
  # than inherit a re-clocked lease. The never-two-concurrent-holders
  # invariant is now guaranteed by the single-writer Bursar (only one acquire
  # can win against the authoritative in-memory table), not by lease survival:
  # every leader (e.g. TickBot) re-validates via `acquire` before each act, so
  # a restarted Bursar with an empty ephemeral table hands leadership to
  # exactly one contender. (Persisting ttl'd leases + re-clocking them on load
  # was the CX-i9ca churn source that wedged the serve.)
  describe "lease semantics (move #4, CX-i9ca)" do
    defp latest_commit_ids(ctx) do
      {:ok, schema} = DocBuilder.reconstruct_snapshot(ctx.store, ctx.root)
      {:ok, state_entry} = Schema.get_entry(schema, "__bursar.json")
      {:ok, log_entry} = Schema.get_entry(schema, "__bursar.log")
      {:ok, state_commit} = CommitStore.latest_commit(ctx.store, state_entry.node_id)
      {:ok, log_commit} = CommitStore.latest_commit(ctx.store, log_entry.node_id)
      {state_commit.id, log_commit.id}
    end

    test "renew is memory-only: no commit to state or log docs", ctx do
      {_pid, name} = start_bursar(ctx, nil, sweep_interval: 60_000)

      assert {:ok, _} = Bursar.acquire(name, "lease.txt", "alice", ttl: 60_000)
      before_ids = latest_commit_ids(ctx)

      assert {:ok, renewed} = Bursar.renew(name, "lease.txt", "alice")
      assert renewed.holder == "alice"

      assert latest_commit_ids(ctx) == before_ids
    end

    test "renew via magenta is memory-only too", ctx do
      {pid, name} = start_bursar(ctx, nil, sweep_interval: 60_000)

      assert {:ok, _} = Bursar.acquire(name, "lease.txt", "alice", ttl: 60_000)
      before_ids = latest_commit_ids(ctx)

      Commonplace.Dataflow.Magenta.send(
        "__bursar",
        Commonplace.Dataflow.Magenta.message("green:renew", "alice", %{
          "path" => "lease.txt",
          "holder" => "alice"
        })
      )

      # Synchronize on the GenServer having processed the magenta cast
      _ = :sys.get_state(pid)
      assert {:held, %{holder: "alice"}} = Bursar.query(name, "lease.txt")
      assert latest_commit_ids(ctx) == before_ids
    end

    test "CX-i9ca: an ephemeral (ttl'd) token does NOT survive a Bursar restart", ctx do
      {pid, _name} = start_bursar(ctx, :ephem_src, sweep_interval: 60_000)

      # A ttl'd lease held by a live holder — before CX-i9ca this was
      # persisted and re-clocked on load so it survived a restart. Now
      # ephemeral tokens are memory-only: a restart drops them entirely.
      assert {:ok, _} = Bursar.acquire(:ephem_src, "lease.txt", "alice", ttl: 200)
      assert {:held, %{holder: "alice"}} = Bursar.query(:ephem_src, "lease.txt")
      GenServer.stop(pid)

      {:ok, pid2} =
        Bursar.start_link(root_uuid: ctx.root, store: ctx.store,
          name: :ephem_dst, sweep_interval: 60_000)
      on_exit(fn -> if Process.alive?(pid2), do: (try do GenServer.stop(pid2) catch (:exit, _ -> :ok) end) end)

      # The lease is GONE after reload (not carried across, not re-clocked) —
      # and immediately re-acquirable by anyone (re-election), no TTL wait.
      assert :available = Bursar.query(:ephem_dst, "lease.txt")
      assert {:ok, %{holder: "bob"}} =
               Bursar.acquire(:ephem_dst, "lease.txt", "bob", ttl: 200)
    end

    test "CX-i9ca: a PERMANENT (ttl:nil) possession token DOES survive a Bursar restart", ctx do
      {pid, _name} = start_bursar(ctx, :perm_src, sweep_interval: 60_000)

      # No ttl → a durable OWNERSHIP token. This is the flip side of the
      # ephemeral case and the invariant jes cares about: possession (hence
      # droppability of the held item) must survive a Bursar restart.
      assert {:ok, _} = Bursar.acquire(:perm_src, "sword-abcd1234.obj", "alice")
      GenServer.stop(pid)

      {:ok, pid2} =
        Bursar.start_link(root_uuid: ctx.root, store: ctx.store,
          name: :perm_dst, sweep_interval: 60_000)
      on_exit(fn -> if Process.alive?(pid2), do: (try do GenServer.stop(pid2) catch (:exit, _ -> :ok) end) end)

      assert {:held, %{holder: "alice"}} =
               Bursar.query(:perm_dst, "sword-abcd1234.obj")
      # A contender is still denied post-restart — ownership is intact.
      assert {:denied, %{holder: "alice"}} =
               Bursar.acquire(:perm_dst, "sword-abcd1234.obj", "bob")
    end

    test "INVARIANT (CX-i9ca): dead holder + bursar restart → immediate re-election, single holder", ctx do
      ttl = 300
      {pid, _name} = start_bursar(ctx, :invariant_src, sweep_interval: 60_000)

      # "alice" acquires an ephemeral lease, then dies (the Bursar OOM-restart
      # scenario). Under the pre-CX-i9ca re-clock model bob had to wait out the
      # re-clocked TTL; now the lease is not persisted, so the restarted Bursar
      # boots with an empty ephemeral table and bob is elected IMMEDIATELY.
      assert {:ok, _} = Bursar.acquire(:invariant_src, "lease.txt", "alice", ttl: ttl)

      GenServer.stop(pid)

      {:ok, pid2} =
        Bursar.start_link(root_uuid: ctx.root, store: ctx.store,
          name: :invariant_dst, sweep_interval: 50)
      on_exit(fn -> if Process.alive?(pid2), do: (try do GenServer.stop(pid2) catch (:exit, _ -> :ok) end) end)
      restarted_at = System.monotonic_time(:millisecond)

      assert {:ok, %{holder: "bob"}} =
               Bursar.acquire(:invariant_dst, "lease.txt", "bob", ttl: ttl)
      elapsed = System.monotonic_time(:millisecond) - restarted_at
      assert elapsed < ttl,
             "re-election took #{elapsed}ms — should be immediate, no 2×TTL wait"

      # The never-two-concurrent-holders invariant still holds: bob is now the
      # SOLE holder, and a third contender against the single-writer Bursar is
      # denied — leadership is exclusive whether inherited or re-elected.
      assert {:held, %{holder: "bob"}} = Bursar.query(:invariant_dst, "lease.txt")
      assert {:denied, %{holder: "bob"}} =
               Bursar.acquire(:invariant_dst, "lease.txt", "carol", ttl: ttl)
    end
  end

  # CX-i9ca persist-path fix. Two obligations: (1) ephemeral churn must not
  # touch the store at ALL (the tick-lease/1s + move-locks/move that bloated
  # the doc), and (2) each durable persist must stay O(table), never
  # O(history) — the retired CX-pyi diff-onto-previous pattern re-encoded an
  # ever-growing op-log every op and wedged the live serve at 11.5 GB
  # (2026-07-10). These would have caught the wedge.
  describe "bounded persistence (CX-i9ca)" do
    defp bursar_state_uuid(ctx) do
      {:ok, schema} = DocBuilder.reconstruct_snapshot(ctx.store, ctx.root)
      {:ok, entry} = Schema.get_entry(schema, "__bursar.json")
      entry.node_id
    end

    defp state_commit_count(ctx) do
      CommitStore.commit_log(ctx.store, bursar_state_uuid(ctx)) |> length()
    end

    defp state_latest_update_size(ctx) do
      {:ok, commit} = CommitStore.latest_commit(ctx.store, bursar_state_uuid(ctx))
      byte_size(commit.update)
    end

    # 500 acquire/release CYCLES = 1000 GenServer ops. Uncontended this runs in
    # <1s (~0.7ms/op), but each op runs the durable skip-guard (an O(table)
    # encode+hash to detect no-change), which contends on CubDB I/O — so under a
    # loaded parallel suite run it can blow the 60s default. Raise the per-test
    # timeout for a stable check of the ZERO-commit invariant, not a wall-clock
    # race. This does NOT mask an unboundedness regression: that would show as a
    # failing SIZE assertion in the "stays O(table)" sibling test (persistence is
    # bounded per that pin), not merely as a timeout.
    # CI-determinism (2026-07-12): each cycle does 2 SYNCHRONOUS Bursar ops, each
    # log_event'ing a real __bursar.log store write, so under I/O load a single op
    # can exceed the default 5s GenServer.call timeout → a spurious "failure" (a
    # HANG at the acquire call, NOT the assertion). Cut the cycle count 5× (100
    # still proves ephemeral churn writes zero __bursar.json commits; the
    # "stays O(table)" SIZE sibling is the real unboundedness guard) and mark it
    # :io_heavy with a generous timeout so it stops flaking CI.
    @tag timeout: 300_000
    @tag :io_heavy
    test "ephemeral churn writes ZERO new commits (tick-lease / move-lock storm)", ctx do
      {_pid, name} = start_bursar(ctx, nil, sweep_interval: 60_000)

      before = state_commit_count(ctx)

      # 100 acquire/release cycles of a ttl'd lease — the tick-lease's 1Hz
      # churn, or a move-lock per move. None changes the permanent (ttl:nil)
      # subset, so the skip-if-unchanged guard writes nothing.
      for _ <- 1..100 do
        assert {:ok, _} = Bursar.acquire(name, "__singletons/tick", "leader", ttl: 5_000)
        assert :ok = Bursar.release(name, "__singletons/tick", "leader")
      end

      assert state_commit_count(ctx) == before,
             "ephemeral churn appended commits to __bursar.json (should be zero)"
    end

    # CX-6scm: 400 SYNCHRONOUS Bursar ops, each a real durable commit. On
    # an unloaded box this is seconds; under a parallel suite run on a
    # shared machine it blows the 60 s default — observed twice in full
    # runs, green at 44/0 in isolation. Same class its `:io_heavy`
    # sibling above already documents ("under a loaded parallel suite run
    # it can blow the 60s default"), which got the raised timeout while
    # this one did not.
    #
    # This does NOT mask an unboundedness regression: that is the SIZE
    # assertion below, which is unaffected by how long the loop takes.
    @tag timeout: 600_000
    test "each durable persist stays O(table), not O(history)", ctx do
      {_pid, name} = start_bursar(ctx, nil, sweep_interval: 60_000)

      # Acquire+release the SAME permanent token 200 times. Every op IS a
      # durable change (adds/removes the token) so every op commits — the
      # churn this fix does NOT skip. Invariant under test: because each
      # commit is a FRESH full snapshot (not a diff onto an ever-growing
      # op-log), the latest commit's encoded size stays ~constant. Under the
      # retired diff-onto-previous code it grew ~linearly with the op count.
      assert {:ok, _} = Bursar.acquire(name, "p-00000001.obj", "alice")
      baseline = state_latest_update_size(ctx)

      for _ <- 1..200 do
        assert :ok = Bursar.release(name, "p-00000001.obj", "alice")
        assert {:ok, _} = Bursar.acquire(name, "p-00000001.obj", "alice")
      end

      final = state_latest_update_size(ctx)

      assert final <= baseline * 2,
             "latest __bursar.json commit grew #{baseline}B -> #{final}B over 200 " <>
               "cycles — the op-log is accumulating (O(history), not O(table))"
    end

    # CX-5gkw: 200 distinct permanent acquires are 200 SYNCHRONOUS durable
    # commits, followed by a Bursar restart and a 200-token reload. That is the
    # same >200-durable-op workload class as the 400-op sibling above, whose
    # 600 s budget is green in isolation but avoids the inherited 60 s race
    # under parallel-suite CubDB I/O load; use that same-class budget here.
    # This does NOT mask a persistence regression: the deliverables are the
    # reload-count and snapshot-SIZE assertions, neither of which depends on
    # how long the durable loop takes.
    @tag timeout: 600_000
    test "a large permanent table stays bounded and survives restart at scale", ctx do
      {pid, name} = start_bursar(ctx, nil, sweep_interval: 60_000)

      # 200 DISTINCT permanent acquires — the bulk re-anchor shape that
      # OOM-wedged the live serve pre-fix. The run must complete promptly and
      # the final snapshot is O(200 tokens), not O(sum of prior op-logs).
      # CX-7b53: the inner call timeout is a HANG DETECTOR, not a per-op
      # performance assertion — it must sit far above the worst plausible
      # SLOW op, or it recreates the spurious failure it replaces. Measured
      # slow-op ceiling history: the 5 s default fired at op #152 under
      # suite load (the original ticket), and a 2.5 s draft of this budget
      # fired at op #173 under suite-plus-concurrent-build load (reviewer
      # gate run, 2026-08-11). 30 s is ~6x the worst budget ever crossed:
      # a genuine hang, never a slow op. Nesting: the OUTER 600 s ExUnit
      # timeout bounds the TOTAL (and fires first if many ops go
      # pathological — as it always did); the inner ceiling bounds a
      # single hung call, so their product intentionally exceeds the
      # outer. Call the GenServer directly so this scale-only budget does
      # not change Bursar's production API or its callers' 5 s default.
      for i <- 1..200 do
        path = "item-#{String.pad_leading(Integer.to_string(i), 8, "0")}.obj"

        assert {:ok, _} =
                 GenServer.call(name, {:acquire, path, "owner-#{i}", nil}, 30_000)
      end

      GenServer.stop(pid)

      # All 200 durable tokens reload after a restart (ownership at scale).
      {:ok, pid2} =
        Bursar.start_link(root_uuid: ctx.root, store: ctx.store,
          name: :"scale_dst_#{:rand.uniform(1_000_000)}")
      on_exit(fn -> if Process.alive?(pid2), do: (try do GenServer.stop(pid2) catch (:exit, _ -> :ok) end) end)

      assert map_size(Bursar.list_tokens(pid2)) == 200
    end
  end

  describe "renew" do
    test "renew by holder resets the TTL clock", ctx do
      {pid, name} = start_bursar(ctx, nil, sweep_interval: 60_000)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice", ttl: 300)
      Process.sleep(200)
      assert {:ok, info} = Bursar.renew(name, "readme.txt", "alice")
      assert info.ttl_ms == 300

      # Sweep at this point — should NOT expire because renew reset acquired_at
      send(pid, :sweep_ttl)
      Process.sleep(50)
      assert {:held, %{holder: "alice"}} = Bursar.query(name, "readme.txt")
    end

    test "renew can change the TTL value", ctx do
      {_pid, name} = start_bursar(ctx, nil, sweep_interval: 60_000)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice", ttl: 1000)
      assert {:ok, info} = Bursar.renew(name, "readme.txt", "alice", ttl: 5000)
      assert info.ttl_ms == 5000
    end

    test "renew on token with no TTL sets one", ctx do
      {_pid, name} = start_bursar(ctx, nil, sweep_interval: 60_000)

      assert {:ok, _} = Bursar.acquire(name, "readme.txt", "alice")
      assert {:ok, info} = Bursar.renew(name, "readme.txt", "alice", ttl: 2000)
      assert info.ttl_ms == 2000
    end

    test "renew by non-holder is rejected", ctx do
      {_pid, name} = start_bursar(ctx)

      Bursar.acquire(name, "readme.txt", "alice", ttl: 5000)
      assert {:error, {:not_holder, "alice"}} = Bursar.renew(name, "readme.txt", "bob")
    end

    test "renew on unheld token fails", ctx do
      {_pid, name} = start_bursar(ctx)

      assert {:error, :not_held} = Bursar.renew(name, "readme.txt", "alice")
    end

    test "renew logs NO event (liveness is ephemeral — move #4)", ctx do
      {_pid, name} = start_bursar(ctx, nil, sweep_interval: 60_000)

      Bursar.acquire(name, "readme.txt", "alice", ttl: 1000)
      assert {:ok, info} = Bursar.renew(name, "readme.txt", "alice", ttl: 5000)
      assert info.ttl_ms == 5000

      {:ok, schema} = DocBuilder.reconstruct_snapshot(ctx.store, ctx.root)
      {:ok, log_entry} = Schema.get_entry(schema, "__bursar.log")
      log = RedLog.load(log_entry.node_id, ctx.store)
      events = RedLog.read(log)

      assert Enum.filter(events, fn e -> e["event"] == "renew" end) == []
    end

    test "renew via magenta", ctx do
      {pid, name} = start_bursar(ctx, nil, sweep_interval: 60_000)

      Bursar.acquire(name, "readme.txt", "alice", ttl: 300)
      Process.sleep(200)

      Commonplace.Dataflow.Magenta.send(
        "__bursar",
        Commonplace.Dataflow.Magenta.message(
          "green:renew",
          "alice",
          %{"path" => "readme.txt", "holder" => "alice", "ttl_ms" => 10_000}
        )
      )

      Process.sleep(50)
      send(pid, :sweep_ttl)
      Process.sleep(50)
      assert {:held, %{holder: "alice", ttl_ms: 10_000}} = Bursar.query(name, "readme.txt")
    end
  end

  # CX-sqyc: identical repeat denials must not each persist a red event
  # — a 1Hz retry loop otherwise grows __bursar.log unboundedly (this
  # crashed the 2026-07-06 dogfood serve). Denied REPLIES are unchanged;
  # only the persisted audit trail is deduplicated, re-armed by any
  # custody change on the path.
  describe "denial dedup (CX-sqyc)" do
    defp denied_events(ctx) do
      {:ok, schema} = DocBuilder.reconstruct_snapshot(ctx.store, ctx.root)
      {:ok, log_entry} = Schema.get_entry(schema, "__bursar.log")
      log = RedLog.load(log_entry.node_id, ctx.store)
      Enum.filter(RedLog.read(log), fn e -> e["event"] == "denied" end)
    end

    test "repeat identical denials persist a single red event", ctx do
      {_pid, name} = start_bursar(ctx)
      {:ok, _} = Bursar.acquire(name, "a.txt", "alice")

      for _ <- 1..5 do
        assert {:denied, %{holder: "alice"}} = Bursar.acquire(name, "a.txt", "bob")
      end

      assert [%{"holder" => "bob", "current_holder" => "alice"}] = denied_events(ctx)
    end

    test "a distinct contender still logs its own first denial", ctx do
      {_pid, name} = start_bursar(ctx)
      {:ok, _} = Bursar.acquire(name, "a.txt", "alice")

      {:denied, _} = Bursar.acquire(name, "a.txt", "bob")
      {:denied, _} = Bursar.acquire(name, "a.txt", "bob")
      {:denied, _} = Bursar.acquire(name, "a.txt", "carol")
      {:denied, _} = Bursar.acquire(name, "a.txt", "carol")

      assert denied_events(ctx) |> Enum.map(& &1["holder"]) |> Enum.sort() ==
               ["bob", "carol"]
    end

    test "custody transition re-arms denial logging for the path", ctx do
      {_pid, name} = start_bursar(ctx)
      {:ok, _} = Bursar.acquire(name, "a.txt", "alice")

      {:denied, _} = Bursar.acquire(name, "a.txt", "bob")
      {:denied, _} = Bursar.acquire(name, "a.txt", "bob")

      :ok = Bursar.release(name, "a.txt", "alice")
      {:ok, _} = Bursar.acquire(name, "a.txt", "alice")
      {:denied, _} = Bursar.acquire(name, "a.txt", "bob")

      assert length(denied_events(ctx)) == 2
    end
  end
end
