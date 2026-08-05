defmodule Commonplace.Bd.TixMigration.Report do
  @moduledoc """
  Rendering for `bin/tix-migrate`'s pre-write report (CX-6n62).

  It lives here rather than inline in the probe script for one
  reason: a report only means something if you can see it go wrong.
  Rendering inside a `mix run` probe that requires a live serve makes
  the report the one part of the tool nobody can exercise, which is
  how a scope line quietly stops matching the figures beside it.
  `Commonplace.Bd.TixMigrationReportTest` renders this against the
  fixture export with no node involved.

  Design:
  `/home/jes/commonplace-plan/docs/plans/2026-08-05-tix-authority-migration-design.md`
  §7 ruling (b) (the declared denominator) and §8 (@2588425, the edge
  mapping and EDGES-IN == LANDED ∪ REFUSED).
  """

  alias Commonplace.Bd.TixMigration.EdgeMapping

  @doc """
  Renders everything `tix-migrate` prints BEFORE it writes anything —
  identical in both modes, because the point of a dry run is to show
  you exactly what the execute run will act on.

  Expects:

      %{
        mode: "dry-run" | "execute",
        serve_node: term(),
        issues_path: String.t(),
        deps_path: String.t(),          # "" when there is no deps stream
        measured_at: String.t(),
        diff: TixMigration.live_set_diff/2 result,
        declared: [id],
        batch_records: [map()],         # post-fold, post-strip
        parse_refusals: [map()],
        fold_report: TixMigration.fold_needs/2 report
      }
  """
  @spec pre_write(map()) :: String.t()
  def pre_write(%{} = r) do
    [
      header(r),
      declared_block(r),
      parse_refusal_block(r),
      edge_block(r)
    ]
    |> Enum.join("")
  end

  @doc """
  The loud DRY RUN banner. Separate from `pre_write/1` so nothing can
  accidentally print it on an execute run.
  """
  @spec dry_run_banner() :: String.t()
  def dry_run_banner do
    """

    ############################################################
    #  DRY RUN — NOTHING WAS WRITTEN.                          #
    #  No commit landed. No ticket was created or updated.     #
    #  No comment was imported. The live serve is unchanged.   #
    #  Re-run with --execute to actually migrate.              #
    ############################################################
    """
  end

  defp header(r) do
    """

    tix-migrate — #{if r.mode == "execute", do: "EXECUTE", else: "DRY RUN"}
    ==========================================================
    substrate node : #{inspect(r.serve_node)}
    issues export  : #{r.issues_path}
    deps export    : #{deps_label(r.deps_path)}
    #{EdgeMapping.direction_statement()}

    RE-MEASURED at #{r.measured_at} — the design's "26 live bd-only" is a
    dated figure and is NOT used anywhere below.

    bd export total : #{r.diff.bd_total}
    tix corpus total: #{r.diff.tix_total}
    in both         : #{length(r.diff.both)}
    tix-only        : #{length(r.diff.tix_only)}   (expected during transition — §4's substrate-native tickets)

    DECLARED-EXPECTED (bd-only, the set this run would import): #{length(r.declared)}
    """
  end

  defp deps_label(""), do: "(none — inline dependencies only)"
  defp deps_label(path), do: path

  defp declared_block(r) do
    by_id = Map.new(r.batch_records, fn rec -> {Map.get(rec, "id"), rec} end)

    r.declared
    |> Enum.map(fn id ->
      record = Map.get(by_id, id, %{})
      needs = Map.get(record, "needs") || []

      needs_str =
        if needs == [],
          do: "",
          else: "  needs=" <> (needs |> Enum.map(&Map.get(&1, "ticket")) |> Enum.join(","))

      "  #{String.pad_trailing(id, 14)} " <>
        "#{String.pad_trailing(to_string(Map.get(record, "status", "?")), 12)}" <>
        "#{String.slice(to_string(Map.get(record, "title", "")), 0, 58)}#{needs_str}\n"
    end)
    |> Enum.join("")
  end

  defp parse_refusal_block(%{parse_refusals: []}), do: ""

  defp parse_refusal_block(%{parse_refusals: refusals}) do
    body = Enum.map_join(refusals, "", fn r -> "  #{r.id}: #{r.reason}\n" end)

    "\nEXPORT LINES THAT WOULD NOT PARSE (#{length(refusals)}) — named, not dropped:\n" <> body
  end

  defp edge_block(%{fold_report: fold}) do
    head = """

    EDGES (fold stage) — #{EdgeMapping.direction_statement()}
      EDGES-IN : #{length(fold.edges_in)}
      mapped   : #{length(fold.landed)}
      refused  : #{length(fold.refused)}
    """

    refusals =
      Enum.map_join(fold.refused, "", fn r -> "  REFUSED #{r.edge}\n          #{r.reason}\n" end)

    broken =
      if fold.unaccounted == [] do
        ""
      else
        "\n❌ EDGES ACCOUNTING BROKE at the fold stage — unaccounted: " <>
          "#{inspect(fold.unaccounted)}\n"
      end

    vacuous =
      if fold.edges_in == [] do
        "\n⚠️  the export carried NO dependency rows — the edge figures above are " <>
          "vacuous, not evidence that there are no dependencies.\n"
      else
        ""
      end

    head <> refusals <> broken <> vacuous
  end
end
