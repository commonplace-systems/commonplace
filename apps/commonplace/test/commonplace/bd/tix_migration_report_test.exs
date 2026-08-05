defmodule Commonplace.Bd.TixMigrationReportTest do
  @moduledoc """
  CX-6n62 — `bin/tix-migrate`'s pre-write report, rendered with no node
  involved.

  The report is the part of a migration tool an operator actually
  reads, and inside a `mix run` probe it would be the one part nobody
  can exercise — which is how a scope line quietly stops matching the
  figures beside it.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Bd.TixMigration
  alias Commonplace.Bd.TixMigration.Report

  @fixture Path.join([__DIR__, "..", "..", "fixtures", "tix_migration", "bd-export-sample.jsonl"])

  defp render(tix_ids, opts \\ []) do
    export = TixMigration.parse_export(File.read!(@fixture), Keyword.get(opts, :deps, ""))
    diff = TixMigration.live_set_diff(TixMigration.record_ids(export.records), tix_ids)
    records = TixMigration.select_records(export.records, diff.bd_only)
    {folded, fold_report} = TixMigration.fold_needs(records, export.edges_in)

    Report.pre_write(%{
      mode: Keyword.get(opts, :mode, "dry-run"),
      serve_node: :commonplace_dev@commonplace,
      issues_path: "/tmp/bd-issues.jsonl",
      deps_path: "",
      measured_at: "2026-08-05T20:00:00Z",
      diff: diff,
      declared: diff.bd_only,
      batch_records: TixMigration.build_batch(folded),
      parse_refusals: export.parse_refusals,
      fold_report: fold_report
    })
  end

  test "the dry-run report names the declared set, the mapping, and every edge refusal" do
    out = render(["CX-samp2", "CX-substrate-native"])

    assert out =~ "tix-migrate — DRY RUN"
    assert out =~ ~s(bd "A blocks B" ↦ tix "B needs A")
    assert out =~ "2588425"

    # The denominator, and the fact that it was re-measured.
    assert out =~ "RE-MEASURED at 2026-08-05T20:00:00Z"
    assert out =~ "bd export total : 3"
    assert out =~ "tix corpus total: 2"
    assert out =~ "DECLARED-EXPECTED (bd-only, the set this run would import): 2"

    # Per-hit shapes for the declared set, with the mapped needs shown.
    assert out =~ "CX-samp1"
    assert out =~ "needs=CX-samp2"
    assert out =~ "CX-samp3"
    refute out =~ "CX-samp2       closed", "an id already in tix is not in the declared set"

    # EDGES accounting with the refusal named.
    assert out =~ "EDGES-IN : 3"
    assert out =~ "REFUSED CX-samp0 blocks CX-samp1"
    assert out =~ "not_a_blocks_edge"
  end

  test "the execute header says EXECUTE, and the dry-run banner is never part of pre_write" do
    out = render([], mode: "execute")
    assert out =~ "tix-migrate — EXECUTE"
    refute out =~ "NOTHING WAS WRITTEN"
  end

  test "the dry-run banner says loudly that nothing was written" do
    banner = Report.dry_run_banner()
    assert banner =~ "DRY RUN — NOTHING WAS WRITTEN"
    assert banner =~ "No commit landed"
    assert banner =~ "The live serve is unchanged"
  end

  test "an export with no dependency rows says its edge figures are VACUOUS" do
    export = TixMigration.parse_export(~s({"id":"CX-lonely","title":"no deps","status":"open"}))
    diff = TixMigration.live_set_diff(["CX-lonely"], [])
    {folded, fold_report} = TixMigration.fold_needs(export.records, export.edges_in)

    out =
      Report.pre_write(%{
        mode: "dry-run",
        serve_node: :n@h,
        issues_path: "x",
        deps_path: "",
        measured_at: "now",
        diff: diff,
        declared: diff.bd_only,
        batch_records: TixMigration.build_batch(folded),
        parse_refusals: export.parse_refusals,
        fold_report: fold_report
      })

    assert out =~ "EDGES-IN : 0"
    assert out =~ "vacuous, not evidence"
  end

  test "unparseable export lines are named in the report, not just counted" do
    export = TixMigration.parse_export(~s({"id":"CX-ok","title":"t"}\n{broken\n))
    diff = TixMigration.live_set_diff(["CX-ok"], [])
    {folded, fold_report} = TixMigration.fold_needs(export.records, export.edges_in)

    out =
      Report.pre_write(%{
        mode: "dry-run",
        serve_node: :n@h,
        issues_path: "x",
        deps_path: "",
        measured_at: "now",
        diff: diff,
        declared: diff.bd_only,
        batch_records: TixMigration.build_batch(folded),
        parse_refusals: export.parse_refusals,
        fold_report: fold_report
      })

    assert out =~ "EXPORT LINES THAT WOULD NOT PARSE (1)"
    assert out =~ "issues line 1"
  end
end
