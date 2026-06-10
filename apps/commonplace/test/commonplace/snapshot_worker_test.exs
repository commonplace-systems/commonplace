defmodule Commonplace.SnapshotWorkerTest do
  @moduledoc """
  CX-tdkq.4 R4(b): the single-flight SnapshotWorker that replaces the
  per-doc time debounce (CX-0nkq). The debounce was a coarse 10s window in
  front of `SnapshotTrigger.maybe_snapshot`; it suppressed the reader-side
  lazy-snapshot storm at the cost of also delaying legitimate snapshots.
  The worker is precise: at most one snapshot computation per doc is
  in-flight at a time, and concurrent same-doc requests collapse to a
  single coalesced re-run.

  The trigger is injected so these tests are deterministic — they don't
  depend on snapshot timing, only on how the worker schedules calls.
  """
  use ExUnit.Case, async: true

  alias Commonplace.SnapshotWorker

  test "a single request invokes the trigger exactly once" do
    test = self()
    trigger = fn _store, doc, _opts -> send(test, {:ran, doc}) end
    {:ok, w} = SnapshotWorker.start_link(name: nil, trigger: trigger)

    SnapshotWorker.request(w, :store, "doc-1")
    assert_receive {:ran, "doc-1"}
    refute_receive {:ran, "doc-1"}, 100
  end

  test "concurrent same-doc requests during an in-flight run coalesce to one re-run" do
    test = self()

    # The trigger announces itself (with its own pid) and blocks until the
    # test releases it, so we can pile up requests while one is in-flight.
    trigger = fn _store, doc, _opts ->
      send(test, {:started, doc, self()})

      receive do
        :proceed -> :ok
      after
        2_000 -> :ok
      end
    end

    {:ok, w} = SnapshotWorker.start_link(name: nil, trigger: trigger)

    # First request dispatches; trigger starts and blocks.
    SnapshotWorker.request(w, :store, "doc-A")
    assert_receive {:started, "doc-A", t1}

    # Three more arrive while doc-A is in-flight — they must coalesce into a
    # SINGLE pending re-run, not three.
    SnapshotWorker.request(w, :store, "doc-A")
    SnapshotWorker.request(w, :store, "doc-A")
    SnapshotWorker.request(w, :store, "doc-A")

    # Release the first run → the one coalesced pending dispatches.
    send(t1, :proceed)
    assert_receive {:started, "doc-A", t2}
    send(t2, :proceed)

    # And nothing further: 4 requests during one in-flight → 2 runs total.
    refute_receive {:started, "doc-A", _}, 200
  end

  test "distinct docs run independently (single-flight is per-doc)" do
    test = self()
    trigger = fn _store, doc, _opts -> send(test, {:ran, doc}) end
    {:ok, w} = SnapshotWorker.start_link(name: nil, trigger: trigger)

    SnapshotWorker.request(w, :store, "doc-X")
    SnapshotWorker.request(w, :store, "doc-Y")

    assert_receive {:ran, "doc-X"}
    assert_receive {:ran, "doc-Y"}
  end

  test "after a run completes, a later request for the same doc dispatches again" do
    test = self()
    trigger = fn _store, doc, _opts -> send(test, {:ran, doc}) end
    {:ok, w} = SnapshotWorker.start_link(name: nil, trigger: trigger)

    SnapshotWorker.request(w, :store, "doc-Q")
    assert_receive {:ran, "doc-Q"}

    # Not coalesced this time — the prior run finished, so this is a fresh
    # single-flight dispatch.
    SnapshotWorker.request(w, :store, "doc-Q")
    assert_receive {:ran, "doc-Q"}
  end

  test "a crashing trigger does not take down the worker and still re-dispatches pending" do
    test = self()

    trigger = fn _store, doc, _opts ->
      send(test, {:started, doc, self()})

      receive do
        :boom -> raise "intentional"
        :proceed -> :ok
      after
        2_000 -> :ok
      end
    end

    {:ok, w} = SnapshotWorker.start_link(name: nil, trigger: trigger)
    Process.unlink(w)

    SnapshotWorker.request(w, :store, "doc-Z")
    assert_receive {:started, "doc-Z", t1}

    # Queue a coalesced re-run, then crash the in-flight one.
    SnapshotWorker.request(w, :store, "doc-Z")
    send(t1, :boom)

    # Worker survived and dispatched the pending re-run.
    assert Process.alive?(w)
    assert_receive {:started, "doc-Z", t2}
    send(t2, :proceed)
  end
end
