defmodule Commonplace.ViewComputeBackpressureTest do
  @moduledoc """
  CX-tdkq.6 (architecture-review R6): backpressure + loop-safety for the
  reactive layer.

    * coalesce — a burst of source commits during an in-flight compute
      collapses to a single re-run against the latest state;
    * async + timeout — a slow/hanging compute_fn does not block the
      GenServer, and is killed once it overruns its timeout;
    * rate fuse — a reactive cycle that recomputes faster than the
      threshold trips a fuse and halts, instead of spinning forever.
  """
  use ExUnit.Case, async: false

  alias Commonplace.{CommandRouter, ViewCompute}
  alias Commonplace.Document.ContentType
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.DocBuilder

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_vc_bp_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_vcbp_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    router = :"router_vcbp_#{:rand.uniform(1_000_000_000)}"
    start_supervised!({CommandRouter, name: router, store: store})
    on_exit(fn -> File.rm_rf!(dir) end)
    %{store: store, router: router}
  end

  defp seed(store, content) do
    uuid = UUID.uuid4()
    doc = ContentType.create(Yelixer.Doc.new(), :text, "seed")
    doc = if content != "", do: ContentType.insert_text(doc, 0, content), else: doc
    CommitStore.create_commit(store, uuid, Yelixer.Encoding.encode_update(doc), nil)
    uuid
  end

  defp read(store, uuid) do
    case DocBuilder.reconstruct_snapshot(store, uuid) do
      {:ok, doc} -> ContentType.get_content(doc) || ""
      :none -> ""
    end
  end

  defp wait_until(fun, n \\ 100) do
    Enum.reduce_while(1..n, false, fn _, _ ->
      if fun.(), do: {:halt, true}, else: Process.sleep(20) && {:cont, false}
    end)
    |> case do
      true -> :ok
      false -> flunk("condition never became true")
    end
  end

  test "coalesces a burst of source commits into a single re-run", %{store: store, router: router} do
    test = self()
    source = seed(store, "v0")
    target = seed(store, "")

    # compute_fn announces itself and blocks until released, so we can pile
    # up source commits while a compute is in-flight.
    compute_fn = fn content ->
      send(test, {:compute, self()})

      receive do
        :go -> :ok
      after
        2_000 -> :ok
      end

      "out:" <> content
    end

    {:ok, pid} =
      ViewCompute.start_link(
        source_uuid: source,
        target_uuid: target,
        compute_fn: compute_fn,
        store: store,
        router: router
      )

    # Initial compute starts and blocks.
    assert_receive {:compute, task1}, 1_000

    # Three source commits arrive while the first compute is in-flight.
    {:ok, _} = CommandRouter.write(router, source, "v1")
    {:ok, _} = CommandRouter.write(router, source, "v2")
    {:ok, _} = CommandRouter.write(router, source, "v3")

    # They must coalesce: a single pending re-run, not three.
    wait_until(fn -> ViewCompute.state(pid).pending == true end)

    send(task1, :go)

    # Exactly one coalesced re-run fires…
    assert_receive {:compute, task2}, 1_000
    send(task2, :go)

    # …and no third/fourth.
    refute_receive {:compute, _}, 300

    GenServer.stop(pid)
  end

  test "a hanging compute does not block the GenServer and is killed on timeout", %{
    store: store,
    router: router
  } do
    handler = {__MODULE__, :timeout_evt, make_ref()}
    test = self()

    :telemetry.attach(
      handler,
      [:commonplace, :view_compute, :compute_timeout],
      fn _e, _m, meta, _ -> send(test, {:timeout_fired, meta}) end,
      nil
    )

    source = seed(store, "x")
    target = seed(store, "")

    compute_fn = fn _ -> Process.sleep(:infinity) end

    {:ok, pid} =
      ViewCompute.start_link(
        source_uuid: source,
        target_uuid: target,
        compute_fn: compute_fn,
        store: store,
        router: router,
        compute_timeout_ms: 150
      )

    # If the compute ran inline this GenServer.call would block for the full
    # (infinite) compute; async means it returns immediately.
    assert %ViewCompute{} = ViewCompute.state(pid)

    # The hung compute is killed once it overruns the timeout.
    assert_receive {:timeout_fired, _meta}, 1_000

    # And the GenServer is still alive and responsive afterwards.
    assert Process.alive?(pid)
    assert %ViewCompute{} = ViewCompute.state(pid)

    :telemetry.detach(handler)
    GenServer.stop(pid)
  end

  test "trips the rate fuse on a tight reactive cycle instead of spinning forever", %{
    store: store,
    router: router
  } do
    handler = {__MODULE__, :fuse_evt, make_ref()}
    test = self()

    :telemetry.attach(
      handler,
      [:commonplace, :view_compute, :fuse_tripped],
      fn _e, meas, meta, _ -> send(test, {:fuse_tripped, meas, meta}) end,
      nil
    )

    # source == target + a non-idempotent compute = an infinite cycle: each
    # write re-triggers a recompute that changes the content again.
    doc = seed(store, "a")
    compute_fn = fn content -> content <> "x" end

    {:ok, pid} =
      ViewCompute.start_link(
        source_uuid: doc,
        target_uuid: doc,
        compute_fn: compute_fn,
        store: store,
        router: router,
        fuse_max: 3,
        fuse_window_ms: 1_000
      )

    # The fuse trips rather than letting the loop run unbounded.
    assert_receive {:fuse_tripped, %{rate: rate}, _meta}, 2_000
    assert rate > 3

    wait_until(fn -> ViewCompute.state(pid).tripped == true end)

    # After tripping, recomputes are halted: the content stops changing.
    settled = read(store, doc)
    Process.sleep(150)
    assert read(store, doc) == settled

    :telemetry.detach(handler)
    GenServer.stop(pid)
  end
end
