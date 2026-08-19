defmodule Commonplace.Projection.MixedPlaneHistoryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Commonplace.Projection.{MixedPlaneHistory, MixedPlaneHistoryFixture}

  @known_positive "235d73b5-a44a-44de-91ad-a753c61f7407"

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "mixed-plane-history-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "the reproducing positive-control fixture passes" do
    assert {:ok, %{commits: 5, armed_commit_id_hex: armed}} =
             MixedPlaneHistory.positive_control()

    assert byte_size(armed) == 64
  end

  test "a broken positive control aborts before document enumeration", %{dir: dir} do
    parent = self()

    output =
      capture_io(fn ->
        result =
          MixedPlaneHistory.run(
            checkpoint_path: Path.join(dir, "abort.json"),
            positive_control: fn -> {:error, :deliberately_broken} end,
            doc_uuids: fn ->
              send(parent, :enumerated)
              MapSet.new(["must-not-run"])
            end
          )

        send(parent, {:result, result})
      end)

    assert_receive {:result, {:error, {:positive_control_failed, :deliberately_broken}}}
    refute_receive :enumerated
    assert output =~ "GATE FAIL"
    assert output =~ "SWEEP ABORTED docs_enumerated=0 commits_scanned=0"

    IO.write(output)
  end

  test "a sweep that examined nothing does not report full coverage", %{dir: dir} do
    # Regression: coverage_percent/2 returned 100.0 for a 0-commit sweep, so a
    # run that learned NOTHING printed "coverage=0/0 (100.00%)" — the very
    # "0 out of 0 reads as clean" defect this module was fixed for, inside the
    # fix. Live mode is protected by the known-positives gate; fixture mode is
    # not, so the figure must be honest on its own.
    output =
      capture_io(fn ->
        MixedPlaneHistory.run(
          checkpoint_path: Path.join(dir, "empty-coverage"),
          scan_id: "empty-coverage",
          store: :unused_store,
          mode: :fixture,
          positive_control: fn -> {:ok, %{armed_commit_id_hex: "control"}} end,
          doc_uuids: fn -> MapSet.new() end,
          progress_every: 1,
          max_concurrency: 1
        )
      end)

    summary = output |> String.split("\n") |> Enum.find("", &String.contains?(&1, "SUMMARY"))

    assert summary =~ "commits_total=0"

    refute summary =~ "100.00%",
           "a sweep over zero commits must not report full coverage: #{summary}"

    assert summary =~ "coverage=0/0 (no commits"
  end

  test "live sweep is void without its expected known positive and emits no summary", %{dir: dir} do
    output =
      capture_io(fn ->
        result =
          MixedPlaneHistory.run(
            checkpoint_path: Path.join(dir, "missing-known-positive"),
            scan_id: "missing-known-positive",
            store: :unused_store,
            positive_control: fn -> {:ok, %{armed_commit_id_hex: "control"}} end,
            doc_uuids: fn -> MapSet.new() end,
            progress_every: 1,
            max_concurrency: 1
          )

        send(self(), {:void_result, result})
      end)

    assert_receive {:void_result, {:error, {:known_positives_missing, [@known_positive]}}}
    assert output =~ "SWEEP VOID"
    assert output =~ "absent_known_positives=#{@known_positive}"
    assert output =~ "SUMMARY SUPPRESSED"
    refute output =~ "SUMMARY docs_total="
  end

  test "expected known-positive set is parameterized", %{dir: dir} do
    expected = ["known-a", "known-b"]
    commit_id = <<9::256>>

    output =
      capture_io(fn ->
        assert {:error, {:known_positives_missing, ["known-b"]}} =
                 MixedPlaneHistory.run(
                   checkpoint_path: Path.join(dir, "parameterized-known-positives"),
                   scan_id: "parameterized-known-positives",
                   store: :unused_store,
                   expected_known_positives: expected,
                   positive_control: fn -> {:ok, %{armed_commit_id_hex: "control"}} end,
                   doc_uuids: fn -> MapSet.new(expected) end,
                   commit_ids: fn _doc_uuid -> MapSet.new([commit_id]) end,
                   project: fn
                     "known-a", ^commit_id, _opts -> {:unknown, {:mixed_plane, %{}}}
                     "known-b", ^commit_id, _opts -> {:ok, <<>>, %{}}
                   end,
                   progress_every: 1,
                   max_concurrency: 1
                 )
      end)

    assert output =~ "absent_known_positives=known-b"
    refute output =~ "absent_known_positives=known-a"
  end

  test "fixture sweep reports the hit and full denominators, then resumes", %{dir: dir} do
    checkpoint = Path.join(dir, "resume.json")

    MixedPlaneHistoryFixture.with_store(fn store, _fixture ->
      opts = [
        checkpoint_path: checkpoint,
        store: store,
        scan_id: "resume-fixture",
        progress_every: 1,
        max_concurrency: 1,
        scan_strategy: :oracle
      ]

      first_output =
        capture_io(fn ->
          assert {:ok, first} = MixedPlaneHistory.run(opts)
          assert first.docs_total == 1
          assert first.docs_scanned == 1
          assert first.docs_fully_unscanned == 0
          assert first.docs_partially_skipped == 0
          assert first.commits_total == 5
          assert first.commits_scanned == 5
          assert first.commits_skipped == 0
          assert first.coverage_percent == 100.0
          assert first.docs_skipped == 0
          assert first.affected_docs == 1
          assert first.hits == 1
          assert first.commits_this_run == 5
        end)

      assert first_output =~ "HIT doc=235d73b5-a44a-44de-91ad-a753c61f7407 commit="

      assert first_output =~
               "SUMMARY docs_total=1 docs_scanned=1 docs_fully_unscanned=0 " <>
                 "docs_partially_skipped=0 commits_total=5 commits_scanned=5 " <>
                 "commits_skipped=0 coverage=5/5 (100.00%)"

      second_output =
        capture_io(fn ->
          assert {:ok, second} =
                   MixedPlaneHistory.run(Keyword.put(opts, :scan_strategy, :incremental))

          assert second.resumed_docs == 1
          assert second.commits_this_run == 0
          assert second.commits_scanned == 5
        end)

      assert second_output =~ "resumed_docs=1 commits_this_run=0"
    end)
  end

  test "the default scanner strategy is oracle", %{dir: dir} do
    MixedPlaneHistoryFixture.with_store(fn store, fixture ->
      output =
        capture_io(fn ->
          assert {:ok, summary} =
                   MixedPlaneHistory.run(
                     checkpoint_path: Path.join(dir, "default-oracle"),
                     store: store,
                     scan_id: "default-oracle",
                     mode: :fixture,
                     positive_control: fn -> {:ok, %{armed_commit_id_hex: "control"}} end,
                     progress_every: 1,
                     max_concurrency: 1
                   )

          assert summary.commits_scanned == length(fixture.commit_ids)
        end)

      assert [_, observed_strategy] =
               Regex.run(~r/^SWEEP START .* strategy=(\S+)$/m, output)

      assert observed_strategy == "oracle",
             "expected default scanner strategy oracle, got #{observed_strategy}"
    end)
  end

  test "STOP finishes the current document, checkpoints it, and resumes cleanly", %{dir: dir} do
    checkpoint = Path.join(dir, "stoppable")
    parent = self()
    commit_id = <<11::256>>

    blocking_project = fn doc_uuid, ^commit_id, _opts ->
      send(parent, {:project_started, doc_uuid, self()})

      receive do
        :release_project -> {:ok, <<>>, %{}}
      end
    end

    opts = [
      checkpoint_path: checkpoint,
      scan_id: "stoppable-fixture",
      store: :unused_store,
      mode: :fixture,
      positive_control: fn -> {:ok, %{armed_commit_id_hex: "control"}} end,
      doc_uuids: fn -> MapSet.new(["doc-1", "doc-2", "doc-3"]) end,
      commit_ids: fn _doc_uuid -> MapSet.new([commit_id]) end,
      project: blocking_project,
      progress_every: 1,
      max_concurrency: 1,
      emit: fn line -> send(parent, {:sweep_line, line}) end
    ]

    task = Task.async(fn -> MixedPlaneHistory.run(opts) end)
    assert_receive {:project_started, "doc-1", worker}
    File.touch!(Path.join(checkpoint, "STOP"))
    send(worker, :release_project)

    assert {:error, {:sweep_stopped, checkpointed: 1, remaining: 2}} = Task.await(task)
    lines = receive_sweep_lines([])
    assert Enum.any?(lines, &String.starts_with?(&1, "SWEEP STOPPED"))
    refute Enum.any?(lines, &String.starts_with?(&1, "SUMMARY "))
    assert length(Path.wildcard(Path.join(checkpoint, "docs/*.json"))) == 1
    IO.puts(Enum.join(lines, "\n"))

    File.rm!(Path.join(checkpoint, "STOP"))

    assert {:ok, resumed} =
             MixedPlaneHistory.run(
               opts
               |> Keyword.delete(:emit)
               |> Keyword.put(:project, fn _doc_uuid, ^commit_id, _opts -> {:ok, <<>>, %{}} end)
             )

    assert resumed.resumed_docs == 1
    assert resumed.commits_this_run == 2
  end

  test "projection failures skip the document and print the commit-specific reason", %{dir: dir} do
    commit_id = <<7::256>>

    output =
      capture_io(fn ->
        assert {:ok, summary} =
                 MixedPlaneHistory.run(
                   checkpoint_path: Path.join(dir, "skipped.json"),
                   scan_id: "skip-fixture",
                   store: :unused_store,
                   positive_control: fn -> {:ok, %{armed_commit_id_hex: "control"}} end,
                   expected_known_positives: [],
                   doc_uuids: fn -> MapSet.new(["doc-unreadable"]) end,
                   commit_ids: fn "doc-unreadable" -> MapSet.new([commit_id]) end,
                   project: fn "doc-unreadable", ^commit_id, _opts -> {:error, :bad_pin} end,
                   progress_every: 1,
                   max_concurrency: 1
                 )

        assert summary.docs_total == 1
        assert summary.docs_scanned == 0
        assert summary.docs_fully_unscanned == 1
        assert summary.docs_partially_skipped == 0
        assert summary.commits_scanned == 0
        assert summary.commits_skipped == 1
        assert summary.coverage_percent == 0.0
        assert summary.docs_skipped == 1
      end)

    assert output =~ "SKIP doc=doc-unreadable commit=#{Base.encode16(commit_id, case: :lower)}"
    assert output =~ "reason={:error, :bad_pin}"
    assert output =~ "docs_skipped=1"
  end

  test "coverage does not improve when more documents fail commit enumeration", %{dir: dir} do
    commit_covered = <<17::256>>
    commit_unscanned = <<18::256>>

    run_fixture = fn name, enumeration_failures ->
      commits = %{
        "doc-covered" => MapSet.new([commit_covered]),
        "doc-unscanned-a" => MapSet.new([commit_unscanned]),
        "doc-unscanned-b" => MapSet.new([commit_unscanned])
      }

      assert {:ok, summary} =
               MixedPlaneHistory.run(
                 checkpoint_path: Path.join(dir, name),
                 scan_id: name,
                 store: :fixture_store,
                 mode: :fixture,
                 positive_control: fn -> {:ok, %{armed_commit_id_hex: "control"}} end,
                 doc_uuids: fn -> Map.keys(commits) |> MapSet.new() end,
                 commit_ids: fn doc_uuid ->
                   if MapSet.member?(enumeration_failures, doc_uuid) do
                     raise "deliberate enumeration failure for #{doc_uuid}"
                   else
                     Map.fetch!(commits, doc_uuid)
                   end
                 end,
                 project: fn
                   "doc-covered", ^commit_covered, _opts -> {:ok, <<>>, %{}}
                   _doc_uuid, ^commit_unscanned, _opts -> {:error, :unreadable}
                 end,
                 progress_every: 3,
                 max_concurrency: 1
               )

      summary
    end

    fewer_failures = run_fixture.("fewer-enumeration-failures", MapSet.new(["doc-unscanned-b"]))

    more_failures =
      run_fixture.(
        "more-enumeration-failures",
        MapSet.new(["doc-unscanned-a", "doc-unscanned-b"])
      )

    assert fewer_failures.docs_fully_unscanned == 2
    assert more_failures.docs_fully_unscanned == 2

    refute coverage_improved?(fewer_failures.coverage_percent, more_failures.coverage_percent),
           "coverage improved from #{inspect(fewer_failures.coverage_percent)} " <>
             "to #{inspect(more_failures.coverage_percent)} as enumeration got worse"
  end

  test "summary exposes partial commit coverage and separates fully from partially unscanned docs",
       %{dir: dir} do
    commit_1 = <<21::256>>
    commit_2 = <<22::256>>
    commit_3 = <<23::256>>
    commit_4 = <<24::256>>
    commit_5 = <<25::256>>

    commits = %{
      "doc-covered" => MapSet.new([commit_1]),
      "doc-partial" => MapSet.new([commit_2, commit_3]),
      "doc-fully-unscanned" => MapSet.new([commit_4, commit_5])
    }

    output =
      capture_io(fn ->
        assert {:ok, summary} =
                 MixedPlaneHistory.run(
                   checkpoint_path: Path.join(dir, "partial-coverage"),
                   scan_id: "partial-coverage",
                   store: :fixture_store,
                   mode: :fixture,
                   positive_control: fn -> {:ok, %{armed_commit_id_hex: "control"}} end,
                   doc_uuids: fn -> Map.keys(commits) |> MapSet.new() end,
                   commit_ids: &Map.fetch!(commits, &1),
                   project: fn
                     "doc-covered", ^commit_1, _opts ->
                       {:ok, <<>>, %{}}

                     "doc-partial", ^commit_2, _opts ->
                       {:ok, <<>>, %{}}

                     "doc-partial", ^commit_3, _opts ->
                       {:unknown, {:conflicted, :partial}}

                     "doc-fully-unscanned", commit_id, _opts
                     when commit_id in [commit_4, commit_5] ->
                       {:unknown, {:conflicted, :complete}}
                   end,
                   progress_every: 3,
                   max_concurrency: 1
                 )

        assert summary.commits_total == 5
        assert summary.commits_scanned == 2
        assert summary.commits_skipped == 3
        assert summary.coverage_percent == 40.0
        assert summary.docs_scanned == 2
        assert summary.docs_fully_unscanned == 1
        assert summary.docs_partially_skipped == 1
      end)

    assert output =~
             "SUMMARY docs_total=3 docs_scanned=2 docs_fully_unscanned=1 " <>
               "docs_partially_skipped=1 commits_total=5 commits_scanned=2 commits_skipped=3 " <>
               "coverage=2/5 (40.00%)"

    assert output =~ "SKIP doc=doc-partial commit=#{Base.encode16(commit_3, case: :lower)}"
    assert output =~ "reason={:unknown, {:conflicted, :partial}}"
  end

  test "a version-one checkpoint with skips is rescanned under verdict-count semantics", %{
    dir: dir
  } do
    checkpoint = Path.join(dir, "old-partial-checkpoint")
    docs_path = Path.join(checkpoint, "docs")
    doc_uuid = "doc-with-old-skip"
    commit_id = <<31::256>>
    commit_hex = Base.encode16(commit_id, case: :lower)
    digest = :crypto.hash(:sha256, doc_uuid) |> Base.encode16(case: :lower)

    File.mkdir_p!(docs_path)

    File.write!(
      Path.join(checkpoint, "manifest.json"),
      Jason.encode!(%{"version" => 1, "scan_id" => "old-partial-checkpoint"})
    )

    File.write!(
      Path.join(docs_path, digest <> ".json"),
      Jason.encode!(%{
        "doc_uuid" => doc_uuid,
        "record" => %{
          "commit_ids" => [commit_hex],
          "commits_scanned" => 1,
          "hits" => [],
          "skip_reasons" => [%{"commit_id" => commit_hex, "reason" => "old failure"}]
        }
      })
    )

    parent = self()

    assert {:ok, summary} =
             MixedPlaneHistory.run(
               checkpoint_path: checkpoint,
               scan_id: "old-partial-checkpoint",
               store: :fixture_store,
               mode: :fixture,
               positive_control: fn -> {:ok, %{armed_commit_id_hex: "control"}} end,
               doc_uuids: fn -> MapSet.new([doc_uuid]) end,
               commit_ids: fn ^doc_uuid -> MapSet.new([commit_id]) end,
               project: fn ^doc_uuid, ^commit_id, _opts ->
                 send(parent, :old_partial_rescanned)
                 {:ok, <<>>, %{}}
               end,
               progress_every: 1,
               max_concurrency: 1
             )

    assert_receive :old_partial_rescanned
    assert summary.resumed_docs == 0
    assert summary.commits_scanned == 1
    assert summary.commits_skipped == 0
  end

  defp receive_sweep_lines(lines) do
    receive do
      {:sweep_line, line} -> receive_sweep_lines([line | lines])
    after
      0 -> Enum.reverse(lines)
    end
  end

  defp coverage_improved?(before, later) when is_number(before) and is_number(later),
    do: later > before

  defp coverage_improved?(_before, _after), do: false
end
