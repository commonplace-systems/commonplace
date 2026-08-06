defmodule Commonplace.Projection.CorpusRegressionTest do
  @moduledoc """
  CX-6scm acceptance #3, corpus half: run `project_at/3` over the real
  head-disagreement set and the real conflicted pins recorded in
  `test/fixtures/verified_projection/conflicted_pins_census_2026-08-06.md`.

  ## Why this is tagged and skipped by default

  The census was measured against a `CubDB.back_up/2` copy of the live
  serve, and that copy was **deleted after measurement** per the standing
  rule that half-gigabyte store copies are not left on a disk at 87% use.
  So the input this test needs does not exist in the repo and cannot: it
  is 537 MB of production history.

  Rather than pretend, the harness is here and the corpus is a parameter.
  Regenerate the copy per the census's own "Reproducing" section — a
  fresh read-only `CubDB.back_up/2`, `:code.is_loaded/1` checked first,
  `:code.all_loaded` counted either side — then:

      CX_CORPUS=/path/to/backup mix test \\
        apps/commonplace/test/commonplace/projection/corpus_regression_test.exs \\
        --include corpus

  ## Store layout — get this wrong and every read returns `:none`

  `CubDB.back_up/2` writes the data file **flat** into the target
  directory. `CommitStore` opens `<data_dir>/commits/`. So `CX_CORPUS`
  must point at a directory whose `commits/` subdirectory holds the
  backed-up `.cub` file — NOT at the directory the backup was written
  into.

  Point it at the wrong level and `CommitStore` **creates an empty
  `commits/0.cub` beside the real one**: the store opens cleanly, every
  read returns `:none`, and the census's exact false-zero failure
  reproduces itself in the harness meant to prevent it. That happened on
  the first real run of this test. The setup therefore asserts the opened
  store is **non-empty** before any assertion is allowed to count — the
  project rule the census's false zero bought: a measurement over an
  empty corpus is not a passing measurement, it is no measurement.

  ## Timing

  80 cold reads over a 537 MB store took **117 s** measured. The 60 s
  ExUnit default times that out, so these tests carry an explicit
  10-minute timeout.

  **Note one thing the census's reproduction section warns about is now
  fixed here**: it records that `reconstruct_doc/3` MINTS a snapshot on
  deep docs and "would write against a live store", so the measurement
  had to disable `:reader_lazy_snapshot_enabled` by hand. `project_at/3`
  passes `mint: false` itself, so this harness cannot write to the copy
  even if that knob is forgotten. The knob is still set below — belt and
  braces on a read that must not mutate evidence.

  ## What it asserts, with denominators

  Part 2 (head): each of the 80 recorded docs, projected at head with
  `head_path: :direct`, must return the LIVE path's recorded sha — the
  data-preserving side. Undeclared, each must return conflicted-unknown
  rather than silently picking. Denominator: 80.

  Part 1 (pins): each of the 27 recorded A≠B pins must return
  `{:unknown, {:conflicted, _}}`, with the two digests matching the
  recorded candidate shas. Denominator: 27 of 163 comparable pin
  attempts; the other 47 attempts are genesis pins, which F7 answers as
  the empty state rather than the census's Path-B `{:error, …}`.
  """
  use ExUnit.Case, async: false

  @moduletag :corpus
  # 80 cold reads over 537 MB: 117 s measured. The 60 s default is not a
  # correctness bound here, just a stopwatch that was set for unit tests.
  @moduletag timeout: 600_000

  alias Commonplace.Projection
  alias Commonplace.Store.CommitStore

  @census Path.join(__DIR__, "../../fixtures/verified_projection/conflicted_pins_census_2026-08-06.md")

  setup do
    corpus = System.get_env("CX_CORPUS")

    if is_nil(corpus) or not File.dir?(corpus) do
      flunk("""
      CX_CORPUS is not set to a readable CubDB store copy.

      This test's input is a 537 MB backup of live history that is deliberately
      not in the repo. See the moduledoc for how to regenerate it read-only.
      """)
    end

    Application.put_env(:commonplace, :reader_lazy_snapshot_enabled, false)
    on_exit(fn -> Application.delete_env(:commonplace, :reader_lazy_snapshot_enabled) end)

    name = :"corpus_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: corpus, name: name})

    # THE NON-EMPTY GATE. `CommitStore` create-on-opens its CubDB, so
    # pointing at the wrong directory level yields a store that opens
    # perfectly and answers `:none` to everything — the census's own
    # false-zero failure, reproduced inside the harness built to prevent
    # it. Measured: that is exactly what the first real run did.
    #
    # An empty corpus must say WHY it is empty, not merely fail some
    # assertion further down where the reason is guesswork.
    rows = CubDB.size(CommitStore.db_handle(name))

    if rows == 0 do
      flunk("""
      CX_CORPUS opened successfully but the store is EMPTY (0 rows).

      This is the false-zero shape, not a result. Almost certainly a layout
      problem: `CubDB.back_up/2` writes the .cub file FLAT, and `CommitStore`
      opens `<data_dir>/commits/` — so CX_CORPUS must be the directory whose
      `commits/` subdirectory contains the backup. Pointing one level off makes
      CommitStore create an empty `commits/0.cub` beside the real file.

        CX_CORPUS = #{corpus}
        contents  = #{inspect(File.ls(corpus))}
        commits/  = #{inspect(File.ls(Path.join(corpus, "commits")))}
      """)
    end

    %{store: name, rows: rows}
  end

  # Rows look like: | `id` | ... | `sha_live` | `sha_replay` | ... |
  defp census_rows(section_heading, arity) do
    @census
    |> File.read!()
    |> String.split("## ")
    |> Enum.find(&String.starts_with?(&1, section_heading))
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "| `"))
    |> Enum.map(fn line ->
      line |> String.split("|", trim: true) |> Enum.map(&String.trim(&1) |> String.trim("`"))
    end)
    |> Enum.filter(&(length(&1) >= arity))
  end

  defp sha(%Yelixer.Doc{} = doc),
    do: doc |> Yelixer.Encoding.encode_update() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  test "Part 2: at head, all 80 recorded docs return the live path's bytes", %{store: store} do
    rows = census_rows("Part 2", 8)
    assert length(rows) == 80, "census Part 2 must carry 80 rows, got #{length(rows)}"

    results =
      for [doc_id, _depth, _class, live_sha, replay_sha | _] <- rows do
        {:ok, head} = CommitStore.latest_commit(store, doc_id)

        declared =
          Projection.project_doc_at(doc_id, head.id, store: store, head_path: :direct)

        undeclared = Projection.project_doc_at(doc_id, head.id, store: store)

        {doc_id, live_sha, replay_sha, declared, undeclared}
      end

    matched_live =
      Enum.count(results, fn {_, live_sha, _, declared, _} ->
        match?({:ok, _, _}, declared) and sha(elem(declared, 1)) == live_sha
      end)

    refused_undeclared =
      Enum.count(results, fn {_, _, _, _, undeclared} ->
        match?({:unknown, {:conflicted, _}}, undeclared)
      end)

    silent_bytes =
      Enum.count(results, fn {_, live_sha, _, declared, _} ->
        match?({:ok, _, _}, declared) and sha(elem(declared, 1)) != live_sha
      end)

    assert {matched_live, refused_undeclared, silent_bytes} == {80, 80, 0},
           "declared-live #{matched_live}/80 · undeclared-refused #{refused_undeclared}/80 · " <>
             "silent-wrong #{silent_bytes}/80"
  end

  test "Part 1: all 27 recorded conflicted pins return conflicted-unknown", %{store: store} do
    rows = census_rows("Part 1", 9)
    assert length(rows) == 27, "census Part 1 must carry 27 rows, got #{length(rows)}"

    outcomes =
      for [doc_id, commit_hex, _pin, _mclass, _cclass, sha_a, sha_b | _] <- rows do
        commit_id = Base.decode16!(commit_hex, case: :lower)
        {doc_id, sha_a, sha_b, Projection.project_at(doc_id, commit_id, store: store)}
      end

    conflicted = Enum.count(outcomes, &match?({_, _, _, {:unknown, {:conflicted, _}}}, &1))
    ok_bytes = Enum.count(outcomes, &match?({_, _, _, {:ok, _, _}}, &1))

    assert {conflicted, ok_bytes} == {27, 0},
           "conflicted #{conflicted}/27 · silently-returned-bytes #{ok_bytes}/27"
  end

  # ══ CX-ggdv: the walk-bounding neutrality fence ═════════════════════
  #
  # Walk-bounding is a PERFORMANCE change whose one non-negotiable fence
  # is byte-neutrality: identical bytes, identical verdicts, only
  # cheaper. This is that fence, run against real history rather than
  # constructed chains — the constructed-chain half lives in
  # `test/commonplace/tree/doc_builder_bounded_walk_test.exs`.
  #
  # `require_head_reachable: true` selects the pre-CX-ggdv head-anchored
  # walk, so both sides of the comparison run in ONE process against ONE
  # store. Comparing whole `project_at/3` RESULTS (not just bytes) makes
  # the verdict half of the fence a real assertion: a `{:corroborated,
  # methods}` list that reordered, a tier that flipped, or a digest that
  # moved all fail here.
  #
  # Denominators are printed on both the pass and the fail path — a
  # neutrality run whose sample silently shrank to zero is the false-zero
  # shape this file already exists to refuse.
  describe "CX-ggdv walk-bounding neutrality" do
    defp compare(store, pairs) do
      Enum.map(pairs, fn {uuid, pin} ->
        old = Projection.project_at(uuid, pin, store: store, require_head_reachable: true)
        new = Projection.project_at(uuid, pin, store: store)
        {uuid, pin, old == new, old, new}
      end)
    end

    defp report(results, label, expected_n) do
      divergences = Enum.reject(results, &elem(&1, 2))

      detail =
        divergences
        |> Enum.take(5)
        |> Enum.map_join("\n", fn {u, p, _, old, new} ->
          "  #{u} @ #{Base.encode16(p, case: :lower)}\n" <>
            "    old=#{inspect(old, limit: 3, printable_limit: 60)}\n" <>
            "    new=#{inspect(new, limit: 3, printable_limit: 60)}"
        end)

      assert length(results) == expected_n,
             "#{label}: sample is #{length(results)}, expected #{expected_n} — " <>
               "a shrunken sample is not a passing measurement"

      assert divergences == [],
             "#{label}: #{length(divergences)}/#{length(results)} DIVERGED\n#{detail}"

      length(results)
    end

    test "80 census head docs: bounded walk == head-anchored walk", %{store: store} do
      pairs =
        for [doc_id | _] <- census_rows("Part 2", 8) do
          {:ok, head} = CommitStore.latest_commit(store, doc_id)
          {doc_id, head.id}
        end

      assert report(compare(store, pairs), "census head docs", 80) == 80
    end

    test "27 census conflicted pins: bounded walk == head-anchored walk", %{store: store} do
      pairs =
        for [doc_id, hex | _] <- census_rows("Part 1", 9),
            do: {doc_id, Base.decode16!(hex, case: :lower)}

      assert report(compare(store, pairs), "census conflicted pins", 27) == 27
    end

    # A random sample stratified by DEPTH CLASS, because depth is exactly
    # the axis walk-bounding changes: the old walk's cost (and its
    # truncation window) scaled with distance-to-head, the new walk's with
    # distance-to-snapshot. A sample drawn without regard to depth would
    # be dominated by the corpus's ~4,100 shallow docs and would not
    # exercise the shapes that can separate the two walks at all.
    #
    # The seed is FIXED so a divergence is reproducible by re-running,
    # and every doc in the deepest class is taken rather than sampled.
    test "≥100 random (doc, pin) pairs across depth classes", %{store: store} do
      :rand.seed(:exsss, {20_260_806, 9, 9})

      logs =
        CommitStore.all_doc_uuids(store)
        |> Enum.sort()
        |> Enum.map(fn u ->
          {u, CommitStore.commit_log(store, u, limit: CommitStore.max_commit_log_limit())}
        end)

      class = fn
        d when d <= 1 -> :d1
        d when d <= 10 -> :d2_10
        d when d <= 100 -> :d11_100
        d when d <= 1000 -> :d101_1000
        _ -> :d1000plus
      end

      pairs =
        logs
        |> Enum.group_by(fn {_u, l} -> class.(length(l)) end)
        |> Enum.flat_map(fn {cls, group} ->
          take = if cls == :d1000plus, do: length(group), else: min(30, length(group))

          group
          |> Enum.shuffle()
          |> Enum.take(take)
          |> Enum.flat_map(fn {u, log} ->
            asc = Enum.reverse(log)
            n = length(asc)

            [div(n, 4), div(n, 2), n - 1]
            |> Enum.uniq()
            |> Enum.filter(&(&1 >= 0 and &1 < n))
            |> Enum.map(&{u, Enum.at(asc, &1).id})
          end)
        end)

      assert length(pairs) >= 100,
             "stratified sample is #{length(pairs)} pairs, need ≥100 — " <>
               "check the corpus actually has depth spread"

      assert report(compare(store, pairs), "stratified depth sample", length(pairs)) >= 100
    end
  end
end
