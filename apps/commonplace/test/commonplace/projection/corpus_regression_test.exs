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
    %{store: name}
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
end
