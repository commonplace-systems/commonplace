defmodule Commonplace.ScaleBenchmarkTest do
  @moduledoc """
  CX-tdkq.9 (architecture-review R9): "measure before the limits are
  load-bearing." §7's scalability claims are derived, not measured. This
  suite converts the named scenarios into real timings.

  Excluded by default (see test_helper.exs); run with:

      mix test apps/commonplace/test/commonplace/scale_benchmark_test.exs --include scale

  Magnitudes default to modest, runnable-in-seconds values; scale them up
  via env vars (SCALE_FORK, SCALE_MERGE, SCALE_MAT, SCALE_INSERT,
  SCALE_VIEWS) to push toward the review's targets (e.g. SCALE_FORK=10000).
  Each scenario prints `[scale] <label>: <ms> ms` to stderr.
  """
  use ExUnit.Case, async: false
  @moduletag :scale
  @moduletag timeout: 600_000

  alias Commonplace.Document.ContentType
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Fork, Merge, Schema}

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_scale_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, CommitStore)
    _ = Supervisor.delete_child(sup, CommitStore)
    {:ok, _} = Supervisor.start_child(sup, {CommitStore, data_dir: dir})
    Commonplace.Tree.DocCache.clear()

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, CommitStore)
      _ = Supervisor.delete_child(sup, CommitStore)
      Application.put_env(:commonplace, :data_dir, "tmp/test_data")
      {:ok, _} = Supervisor.start_child(sup, {CommitStore, data_dir: "tmp/test_data"})
      Commonplace.Tree.DocCache.clear()
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp scale(env, default) do
    case System.get_env(env) do
      nil -> default
      v -> String.to_integer(v)
    end
  end

  defp bench(label, fun) do
    {us, result} = :timer.tc(fun)
    ms = Float.round(us / 1000, 1)
    IO.puts(:stderr, "  [scale] #{label}: #{ms} ms")
    result
  end

  defp text_doc(content) do
    doc = ContentType.create(Yelixer.Doc.new(), :text, "f")
    if content != "", do: ContentType.insert_text(doc, 0, content), else: doc
  end

  defp commit_doc(uuid, doc) do
    CommitStore.create_commit(CommitStore, uuid, Yelixer.Encoding.encode_update(doc), nil)
  end

  test "insert-heavy yelixer doc: M sequential inserts into one Text" do
    m = scale("SCALE_INSERT", 2_000)

    bench("insert-heavy yelixer (#{m} appends)", fn ->
      doc = ContentType.create(Yelixer.Doc.new(), :text, "f")

      # Track the offset incrementally — recomputing get_content/String.length
      # each step would make the benchmark itself O(n²) and mask the actual
      # per-insert cost.
      {final, _len} =
        Enum.reduce(0..(m - 1), {doc, 0}, fn i, {d, len} ->
          chunk = "x#{rem(i, 10)}"
          {ContentType.insert_text(d, len, chunk), len + String.length(chunk)}
        end)

      final
    end)
  end

  test "materialize K entries" do
    k = scale("SCALE_MAT", 1_000)
    entries = Enum.map(1..k, fn i -> %{"id" => "m#{i}", "text" => "entry #{i}"} end)

    out =
      bench("materialize (#{k} entries)", fn ->
        Commonplace.Materialize.materialize(entries, %{chains: []})
      end)

    assert length(out) == k
  end

  test "fork a directory tree of N docs" do
    n = scale("SCALE_FORK", 200)

    dir_uuid = UUID.uuid4()

    dir_doc =
      Enum.reduce(1..n, Schema.new_schema(), fn i, schema ->
        child = UUID.uuid4()
        commit_doc(child, text_doc("child #{i}"))
        Schema.add_file(schema, "f#{i}.txt", child)
      end)

    commit_doc(dir_uuid, dir_doc)

    forked =
      bench("fork directory (#{n} docs)", fn ->
        Fork.fork_directory(dir_uuid, CommitStoreClient)
      end)

    assert is_binary(forked)
  end

  test "reconstruct a deep commit chain of D commits" do
    d = scale("SCALE_MERGE", 200)
    uuid = UUID.uuid4()

    # Build a chain of D commits (each a chained text edit).
    doc0 = text_doc("v0")
    commit_doc(uuid, doc0)

    Enum.each(1..(d - 1), fn i ->
      doc = ContentType.create(Yelixer.Doc.new(), :text, "f")
      doc = ContentType.insert_text(doc, 0, "v#{i}")

      CommitStoreClient.create_chained_commit(
        CommitStore,
        uuid,
        Yelixer.Encoding.encode_update(doc)
      )
    end)

    {:ok, _doc} =
      bench("reconstruct deep chain (#{d} commits)", fn ->
        DocBuilder.reconstruct_doc(CommitStore, uuid)
      end)
  end

  test "merge after divergence (D commits each side)" do
    d = scale("SCALE_MERGE", 100)

    # Source dir, forked, then both sides accrue D edits to a shared child.
    src_dir = UUID.uuid4()
    child = UUID.uuid4()
    commit_doc(child, text_doc("base"))
    commit_doc(src_dir, Schema.add_file(Schema.new_schema(), "c.txt", child))

    target_dir = Fork.fork_directory(src_dir, CommitStoreClient)

    diverge = fn uuid ->
      Enum.each(1..d, fn i ->
        doc =
          ContentType.insert_text(
            ContentType.create(Yelixer.Doc.new(), :text, "f"),
            0,
            "edit #{i}"
          )

        CommitStoreClient.create_chained_commit(
          CommitStore,
          uuid,
          Yelixer.Encoding.encode_update(doc)
        )
      end)
    end

    diverge.(src_dir)
    diverge.(target_dir)

    result =
      bench("merge after divergence (#{d}/side)", fn ->
        Merge.merge(src_dir, target_dir, CommitStoreClient)
      end)

    assert match?({:ok, _}, result)
  end

  test "100-view fan-out: V ViewComputes on one source, single recompute round" do
    v = scale("SCALE_VIEWS", 100)
    test_pid = self()

    source = UUID.uuid4()
    commit_doc(source, text_doc("seed"))

    compute_fn = fn content -> "out:" <> content end

    pids =
      bench("start #{v} ViewComputes", fn ->
        Enum.map(1..v, fn _i ->
          target = UUID.uuid4()
          commit_doc(target, text_doc(""))

          {:ok, pid} =
            Commonplace.ViewCompute.start_link(
              source_uuid: source,
              target_uuid: target,
              compute_fn: compute_fn,
              store: CommitStore
            )

          {pid, target}
        end)
      end)

    # Let initial computes settle, then drive one source edit and measure
    # how long until every view has rewritten its target.
    Process.sleep(200)

    bench("fan-out single recompute round (#{v} views)", fn ->
      doc =
        ContentType.insert_text(ContentType.create(Yelixer.Doc.new(), :text, "f"), 0, "edited")

      CommitStoreClient.create_chained_commit(
        CommitStore,
        source,
        Yelixer.Encoding.encode_update(doc)
      )

      deadline = System.monotonic_time(:millisecond) + 30_000

      Enum.each(pids, fn {_pid, target} ->
        wait_target(target, "out:edited", deadline)
      end)
    end)

    Enum.each(pids, fn {pid, _t} ->
      if Process.alive?(pid),
        do:
          (try do
             GenServer.stop(pid)
           catch
             (:exit, _ -> :ok)
           end)
    end)

    send(test_pid, :done)
  end

  defp wait_target(target, expected, deadline) do
    content =
      case DocBuilder.reconstruct_snapshot(CommitStoreClient, target) do
        {:ok, doc} -> ContentType.get_content(doc) || ""
        :none -> ""
      end

    cond do
      content == expected ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        :ok

      true ->
        Process.sleep(10)
        wait_target(target, expected, deadline)
    end
  end
end
