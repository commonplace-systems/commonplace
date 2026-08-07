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
          assert first.commits_total == 5
          assert first.commits_scanned == 5
          assert first.docs_skipped == 0
          assert first.affected_docs == 1
          assert first.hits == 1
          assert first.commits_this_run == 5
        end)

      assert first_output =~ "HIT doc=235d73b5-a44a-44de-91ad-a753c61f7407 commit="

      assert first_output =~
               "SUMMARY docs_total=1 docs_scanned=1 commits_total=5 commits_scanned=5"

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
        assert summary.commits_scanned == 1
        assert summary.docs_skipped == 1
      end)

    assert output =~ "SKIP doc=doc-unreadable commit=#{Base.encode16(commit_id, case: :lower)}"
    assert output =~ "reason={:error, :bad_pin}"
    assert output =~ "docs_skipped=1"
  end

  defp receive_sweep_lines(lines) do
    receive do
      {:sweep_line, line} -> receive_sweep_lines([line | lines])
    after
      0 -> Enum.reverse(lines)
    end
  end
end
