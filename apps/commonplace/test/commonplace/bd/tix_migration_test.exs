defmodule Commonplace.Bd.TixMigrationTest do
  @moduledoc """
  CX-6n62 / CX-q7nh — the PURE half of the bd→tix migration tooling
  (`/home/jes/commonplace-plan/docs/plans/2026-08-05-tix-authority-migration-design.md`,
  §8 deps ruling @2588425).

  The store-touching acceptance comparators live in
  `Commonplace.Bd.TixMigrationAcceptanceTest`, which seeds a real
  workspace through the `ticket_import` verb itself.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Bd.TixMigration
  alias Commonplace.Bd.TixMigration.EdgeMapping

  @fixture Path.join([__DIR__, "..", "..", "fixtures", "tix_migration", "bd-export-sample.jsonl"])

  describe "THE DIRECTION PIN: bd \"A blocks B\" ↦ tix \"B needs A\"" do
    test "a concrete, human-obvious example — CX-a blocks CX-b produces CX-b needs CX-a" do
      # Read this assertion out loud. CX-a BLOCKS CX-b. Therefore the
      # ticket that gains a `needs` ref is CX-b (the blocked one), and
      # the ref points at CX-a (the blocker). The inverse is the
      # CX-di2m directed-graph error, and it is invisible in any test
      # whose two ids are not distinguishable by name.
      {:ok, edge} = EdgeMapping.normalize(%{"from" => "CX-a", "to" => "CX-b", "kind" => "blocks"})

      assert {ticket_that_gains_the_ref, ref} = EdgeMapping.to_needs_ref(edge)

      assert ticket_that_gains_the_ref == "CX-b",
             "bd says CX-a BLOCKS CX-b, so it is CX-b — the BLOCKED ticket — that gains a needs ref"

      assert ref == %{"ticket" => "CX-a"},
             "the ref must point at CX-a, the BLOCKER; pointing it at CX-b inverts the graph"
    end

    test "the inline bd-export wire shape maps the same direction (field order is reversed there)" do
      # bd's export rows say "issue_id DEPENDS ON depends_on_id",
      # which is "depends_on_id blocks issue_id" — the endpoints are
      # written in the opposite order from the deps-stream shape. Both
      # must land on the same mapped edge.
      {:ok, edge} =
        EdgeMapping.normalize(%{
          "issue_id" => "CX-b",
          "depends_on_id" => "CX-a",
          "type" => "blocks"
        })

      assert EdgeMapping.to_needs_ref(edge) == {"CX-b", %{"ticket" => "CX-a"}}
    end

    test "both wire shapes normalize to the same edge" do
      {:ok, from_deps_stream} =
        EdgeMapping.normalize(%{"from" => "CX-a", "to" => "CX-b", "kind" => "blocks"})

      {:ok, from_export_row} =
        EdgeMapping.normalize(%{"issue_id" => "CX-b", "depends_on_id" => "CX-a", "type" => "blocks"})

      assert from_deps_stream == from_export_row
    end

    test "a non-blocks edge is NAMED, not silently dropped" do
      assert {:error, {:not_a_blocks_edge, "parent-child"}} =
               EdgeMapping.normalize(%{
                 "issue_id" => "CX-b",
                 "depends_on_id" => "CX-a",
                 "type" => "parent-child"
               })
    end

    test "a malformed edge is named too" do
      assert {:error, {:malformed_edge, _}} = EdgeMapping.normalize(%{"nope" => 1})
    end

    test "the direction statement scripts print says the same thing this test pins" do
      statement = EdgeMapping.direction_statement()
      assert statement =~ "A blocks B"
      assert statement =~ "B needs A"
      assert statement =~ "2588425"
    end
  end

  describe "parse_export/2" do
    test "reads the fixture export: records, inline edges, no parse refusals" do
      export = File.read!(@fixture) |> TixMigration.parse_export()

      assert TixMigration.record_ids(export.records) == ["CX-samp1", "CX-samp2", "CX-samp3"]
      assert export.parse_refusals == []

      # Three inline dependency rows across the fixture: two on samp1
      # (one blocks, one parent-child) and one on samp3.
      assert length(export.edges_in) == 3
    end

    test "an unparseable line is a NAMED refusal carrying its stream and line" do
      export = TixMigration.parse_export("{\"id\":\"CX-ok\"}\n{not json\n")

      assert TixMigration.record_ids(export.records) == ["CX-ok"]
      assert [%{stream: "issues", line: 1, id: id, reason: reason}] = export.parse_refusals
      assert id =~ "line 1"
      assert reason =~ "parse"
    end

    test "the separate deps stream is collected alongside the inline edges" do
      export =
        TixMigration.parse_export(
          ~s({"id":"CX-b"}\n),
          ~s({"from":"CX-a","to":"CX-b","kind":"blocks"}\n)
        )

      assert length(export.edges_in) == 1
    end

    test "an edge present in BOTH streams counts once — EDGES-IN is the distinct set" do
      issues =
        Jason.encode!(%{
          "id" => "CX-b",
          "dependencies" => [
            %{"issue_id" => "CX-b", "depends_on_id" => "CX-a", "type" => "blocks"}
          ]
        })

      # The same edge, in the other wire shape, in the deps stream.
      deps = ~s({"from":"CX-a","to":"CX-b","kind":"blocks"})

      export = TixMigration.parse_export(issues, deps)
      # Different wire shapes dedupe to different keys by design (the
      # dedupe reads endpoints WITHOUT judging them, so it can never
      # remove an edge that would have been refused) — the fold below
      # is what makes the duplicate harmless.
      {[record], report} = TixMigration.fold_needs(export.records, export.edges_in)

      assert record["needs"] == [%{"ticket" => "CX-a"}],
             "folding the same edge twice must not duplicate the ref"

      assert report.unaccounted == []
    end
  end

  describe "live_set_diff/2 — the denominator is RE-MEASURED, never inherited" do
    test "splits the two corpora three ways" do
      diff = TixMigration.live_set_diff(["CX-1", "CX-2", "CX-3"], ["CX-2", "CX-9"])

      assert diff.bd_only == ["CX-1", "CX-3"]
      assert diff.tix_only == ["CX-9"]
      assert diff.both == ["CX-2"]
      assert diff.bd_total == 3
      assert diff.tix_total == 2
    end

    test "tix-only ids are reported, not treated as an error (§4: nine real substrate-only)" do
      diff = TixMigration.live_set_diff([], ["CX-substrate-native"])
      assert diff.bd_only == []
      assert diff.tix_only == ["CX-substrate-native"]
    end

    test "select_records/2 picks exactly the re-measured set, in input order" do
      records = [%{"id" => "CX-1"}, %{"id" => "CX-2"}, %{"id" => "CX-3"}]
      assert TixMigration.select_records(records, ["CX-3", "CX-1"]) ==
               [%{"id" => "CX-1"}, %{"id" => "CX-3"}]
    end
  end

  describe "fold_needs/2 — the EDGES accounting (EDGES-IN == LANDED ∪ REFUSED)" do
    test "folds a blocks edge onto the BLOCKED record" do
      records = [%{"id" => "CX-a"}, %{"id" => "CX-b"}]
      edges = [%{"from" => "CX-a", "to" => "CX-b", "kind" => "blocks"}]

      {[a, b], report} = TixMigration.fold_needs(records, edges)

      assert Map.get(a, "needs") == nil, "the BLOCKER gains nothing"
      assert b["needs"] == [%{"ticket" => "CX-a"}]

      assert report.landed == ["CX-a blocks CX-b"]
      assert report.refused == []
      assert report.unaccounted == []
    end

    test "THE IDENTITY: every edge that arrived is either landed or refused" do
      records = [%{"id" => "CX-b"}]

      edges = [
        # lands
        %{"from" => "CX-a", "to" => "CX-b", "kind" => "blocks"},
        # refused: dependent not in batch
        %{"from" => "CX-a", "to" => "CX-elsewhere", "kind" => "blocks"},
        # refused: not a blocks edge
        %{"issue_id" => "CX-b", "depends_on_id" => "CX-parent", "type" => "parent-child"},
        # refused: malformed
        %{"nope" => true}
      ]

      {_records, report} = TixMigration.fold_needs(records, edges)

      # THE IDENTITY FIRST — it is the claim; the counts below are the
      # shapes that make the claim readable.
      assert report.unaccounted == [],
             "every edge that ARRIVED must be landed or refused — a silently skipped edge shows up here"

      accounted = MapSet.new(report.landed ++ Enum.map(report.refused, & &1.edge))
      assert MapSet.equal?(accounted, MapSet.new(report.edges_in))

      assert length(report.edges_in) == 4
      assert length(report.landed) == 1
      assert length(report.refused) == 3

      reasons = Enum.map(report.refused, & &1.reason)
      assert Enum.any?(reasons, &(&1 =~ "dependent_not_in_batch"))
      assert Enum.any?(reasons, &(&1 =~ "not_a_blocks_edge"))
      assert Enum.any?(reasons, &(&1 =~ "malformed_edge"))
    end

    test "DANGLING REF: an edge whose BLOCKER is absent from the batch still maps" do
      # The decision, documented in the moduledoc: a needs ref is
      # shape-valid whether or not its target exists, so refusing here
      # would drop real dependency information for an accident of
      # batch composition — and it self-heals when the prerequisite
      # lands later.
      records = [%{"id" => "CX-b"}]
      edges = [%{"from" => "CX-absent", "to" => "CX-b", "kind" => "blocks"}]

      {[b], report} = TixMigration.fold_needs(records, edges)

      assert b["needs"] == [%{"ticket" => "CX-absent"}]
      assert report.landed == ["CX-absent blocks CX-b"]
      assert report.refused == []
    end

    test "DANGLING DEPENDENT: an edge whose BLOCKED ticket is absent is a NAMED refusal" do
      records = [%{"id" => "CX-a"}]
      edges = [%{"from" => "CX-a", "to" => "CX-absent", "kind" => "blocks"}]

      {[a], report} = TixMigration.fold_needs(records, edges)

      assert Map.get(a, "needs") == nil
      assert report.landed == []
      assert [%{edge: "CX-a blocks CX-absent", reason: reason}] = report.refused
      assert reason =~ "dependent_not_in_batch"
      assert reason =~ "CX-absent"
      assert report.unaccounted == []
    end

    test "folding is idempotent and preserves needs the record already carried" do
      records = [%{"id" => "CX-b", "needs" => [%{"ticket" => "CX-pre"}]}]
      edges = [%{"from" => "CX-a", "to" => "CX-b", "kind" => "blocks"}]

      {[once], _} = TixMigration.fold_needs(records, edges)
      {[twice], _} = TixMigration.fold_needs([once], edges)

      assert once["needs"] == [%{"ticket" => "CX-pre"}, %{"ticket" => "CX-a"}]
      assert twice["needs"] == once["needs"]
    end

    test "the fixture export: two edges land (one with a dangling blocker), the parent-child is refused" do
      export = File.read!(@fixture) |> TixMigration.parse_export()
      ids = TixMigration.record_ids(export.records)

      {records, report} =
        TixMigration.fold_needs(TixMigration.select_records(export.records, ids), export.edges_in)

      samp1 = Enum.find(records, &(&1["id"] == "CX-samp1"))
      assert samp1["needs"] == [%{"ticket" => "CX-samp2"}]

      # CX-not-migrating is not in the batch, but it is the BLOCKER —
      # the ref still maps (see the dangling-ref decision).
      samp3 = Enum.find(records, &(&1["id"] == "CX-samp3"))
      assert samp3["needs"] == [%{"ticket" => "CX-not-migrating"}]

      assert report.landed == ["CX-samp2 blocks CX-samp1", "CX-not-migrating blocks CX-samp3"]
      assert [%{edge: "CX-samp0 blocks CX-samp1", reason: reason}] = report.refused
      assert reason =~ "not_a_blocks_edge"
      assert report.unaccounted == []
    end
  end

  describe "build_batch/1 — transport keys never become record content" do
    test "strips the inline edge graph and comment stream, keeps everything else" do
      export = File.read!(@fixture) |> TixMigration.parse_export()
      [samp1 | _] = TixMigration.build_batch(export.records)

      for key <- TixMigration.transport_only_keys() do
        refute Map.has_key?(samp1, key), "#{key} is transport, not record content"
      end

      assert samp1["title"] == "the migration driver"
      assert samp1["labels"] == ["migration"]
    end

    test "the stripped keys are exactly the declared list" do
      assert TixMigration.transport_only_keys() ==
               ~w(dependencies dependency_count dependent_count comments comment_count)
    end
  end

  describe "comment_record_lists/2" do
    test "extracts per-issue comment RECORDS for the migrating ids only" do
      export = File.read!(@fixture) |> TixMigration.parse_export()

      assert [{"CX-samp1", [comment]}] =
               TixMigration.comment_record_lists(export.records, [
                 "CX-samp1",
                 "CX-samp2",
                 "CX-samp3"
               ])

      assert comment["id"] == "c-0001"

      # CX-xmsd: handed over RAW. The `text` -> `body` translation is
      # the gate's job (`Importer.normalize_comment_record/1`), not a
      # client-side pre-fill — that pre-fill is what let the field-shape
      # mismatch pass unnoticed.
      assert (comment["body"] || comment["text"]) =~ "re-measure"
    end

    test "an id outside the migrating set contributes no records" do
      export = File.read!(@fixture) |> TixMigration.parse_export()
      assert TixMigration.comment_record_lists(export.records, ["CX-samp3"]) == []
    end
  end

  describe "bd_edge_projection/1 — the bd leg of the 3-way, through THE mapping" do
    test "projects blocks edges into the needs-graph shape" do
      projection =
        TixMigration.bd_edge_projection([
          %{"from" => "CX-a", "to" => "CX-b", "kind" => "blocks"},
          %{"from" => "CX-c", "to" => "CX-b", "kind" => "blocks"},
          %{"issue_id" => "CX-b", "depends_on_id" => "CX-p", "type" => "parent-child"}
        ])

      assert Map.keys(projection) == ["CX-b"]
      assert MapSet.equal?(projection["CX-b"], MapSet.new(["CX-a", "CX-c"]))
    end
  end

  describe "field_divergence/2 — per-hit shapes, compared through normalization" do
    test "bd's integer priority is judged against tix's stored form, not against itself" do
      bd = [%{"id" => "CX-x", "title" => "t", "status" => "open", "priority" => 2}]
      tix = %{"CX-x" => %Commonplace.Bd.Schemas.Issue{id: "CX-x", title: "t", status: "open", priority: "p2"}}

      assert TixMigration.field_divergence(bd, tix) == []
    end

    test "a real divergence is a shape, not a count" do
      bd = [%{"id" => "CX-x", "title" => "bd title", "status" => "open", "priority" => 0}]
      tix = %{"CX-x" => %Commonplace.Bd.Schemas.Issue{id: "CX-x", title: "tix title", status: "closed", priority: "p2"}}

      hits = TixMigration.field_divergence(bd, tix)

      assert %{id: "CX-x", field: :status, bd: "open", tix: "closed"} in hits
      assert %{id: "CX-x", field: :title, bd: "bd title", tix: "tix title"} in hits
      assert %{id: "CX-x", field: :priority, bd: "p0", tix: "p2"} in hits
    end

    test "an id present on only one side is not a field divergence" do
      bd = [%{"id" => "CX-only-bd", "title" => "t", "status" => "open"}]
      assert TixMigration.field_divergence(bd, %{}) == []
    end
  end
end
