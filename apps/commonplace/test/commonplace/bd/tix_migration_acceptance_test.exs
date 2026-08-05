defmodule Commonplace.Bd.TixMigrationAcceptanceTest do
  @moduledoc """
  CX-6n62 — the store-touching half: the 3-way acceptance comparators
  and the post-import EDGES accounting, against a workspace seeded
  through the `ticket_import` verb ITSELF (the same fixture pattern as
  `Commonplace.Bd.TicketCreateImportVerbsTest`, so what is measured is
  what the migration would actually land, not a hand-built graph that
  happens to agree).

  Design:
  `/home/jes/commonplace-plan/docs/plans/2026-08-05-tix-authority-migration-design.md`
  §3 (acceptance, amended by §8's projection rule) and §8's edge
  ruling (@2588425).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bd.Issue
  alias Commonplace.Bd.TixMigration
  alias Commonplace.Crypto.Signing
  alias Commonplace.Crypto.SigningContext
  alias Commonplace.Store.CommitStore
  alias Commonplace.Store.CommitStoreClient
  alias Commonplace.Tree.Schema
  alias Commonplace.ViewActionDispatch

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_tix_migration_test_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
    {:ok, _pid} = Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    root_uuid = UUID.uuid4()
    update = Yelixer.Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, update, nil)
    File.write!(Path.join(dir, "root"), root_uuid)

    on_exit(fn ->
      Application.put_env(:commonplace, :data_dir, prior_data_dir || "tmp/test_data")
      File.rm_rf!(dir)
    end)

    {pub, priv} = Signing.generate_keypair()
    ctx = %SigningContext{identity_uuid: "test-tix-migration", private_key: priv, public_key: pub}

    %{root: root_uuid, signing_context: ctx}
  end

  defp import_batch(records, ctx) do
    {:ok, :tree_mutation, report} =
      ViewActionDispatch.dispatch("ticket_import", %{
        args: %{"records" => TixMigration.build_batch(records)},
        signing_context: ctx,
        source: "test"
      })

    report
  end

  defp export(issues_jsonl, deps_jsonl \\ "") do
    TixMigration.parse_export(issues_jsonl, deps_jsonl)
  end

  defp jsonl(records), do: records |> Enum.map(&Jason.encode!/1) |> Enum.join("\n")

  describe "the 3-way acceptance: walk == query, bd leg through the mapping" do
    test "a clean migration agrees on all three legs", %{root: root, signing_context: ctx} do
      issues =
        jsonl([
          %{"id" => "CX-mA", "title" => "A", "status" => "open", "priority" => 2},
          %{"id" => "CX-mB", "title" => "B", "status" => "open", "priority" => 2},
          %{"id" => "CX-mC", "title" => "C", "status" => "open", "priority" => 2}
        ])

      # bd: A blocks B, B blocks C  ↦  tix: B needs A, C needs B.
      deps =
        jsonl([
          %{"from" => "CX-mA", "to" => "CX-mB", "kind" => "blocks"},
          %{"from" => "CX-mB", "to" => "CX-mC", "kind" => "blocks"}
        ])

      ex = export(issues, deps)
      ids = TixMigration.record_ids(ex.records)
      {folded, fold_report} = TixMigration.fold_needs(ex.records, ex.edges_in)

      batch = import_batch(folded, ctx)
      assert batch.unaccounted == []
      assert length(batch.landed) == 3

      walk = TixMigration.walk_needs(root, CommitStoreClient)
      query = TixMigration.query_needs(root, ids, CommitStoreClient)
      projection = TixMigration.bd_edge_projection(ex.edges_in)

      result = TixMigration.three_way(walk, query, projection, ids)

      # Scope printed BESIDE the verdict: "agree" over an empty
      # comparison is not evidence of anything.
      assert result.scope.ids == 3
      assert result.scope.walk_edges == 2
      assert result.scope.bd_edges == 2
      assert result.agree?, inspect(result)

      # And the direction actually landed: B needs A, not A needs B.
      {:ok, b} = Issue.show(root, "CX-mB")
      assert b.needs == [%{"ticket" => "CX-mA"}]
      {:ok, a} = Issue.show(root, "CX-mA")
      assert a.needs == []

      final = TixMigration.final_edge_accounting(fold_report, batch, walk)
      assert final.unaccounted == []
      assert length(final.landed) == 2
      assert final.refused == []
    end

    test "a needs ref tix has and bd never implied shows as extra_in_tix, not as agreement", %{
      root: root,
      signing_context: ctx
    } do
      issues =
        jsonl([
          %{"id" => "CX-xA", "title" => "A", "status" => "open"},
          %{"id" => "CX-xB", "title" => "B", "status" => "open"}
        ])

      ex = export(issues)
      ids = TixMigration.record_ids(ex.records)
      {folded, _} = TixMigration.fold_needs(ex.records, ex.edges_in)
      _ = import_batch(folded, ctx)

      # A post-cutover native edge, added through the gated verb.
      assert {:ok, :tree_mutation, _} =
               ViewActionDispatch.dispatch("ticket_add_needs", %{
                 args: %{"ticket" => "CX-xB", "needs_ticket" => "CX-xA"},
                 signing_context: ctx,
                 source: "test"
               })

      walk = TixMigration.walk_needs(root, CommitStoreClient)
      query = TixMigration.query_needs(root, ids, CommitStoreClient)
      result = TixMigration.three_way(walk, query, TixMigration.bd_edge_projection([]), ids)

      assert result.bd_vs_tix.extra_in_tix == [{"CX-xB", "CX-xA"}]
      assert result.bd_vs_tix.missing_in_tix == []
      # extra_in_tix is EXPECTED during transition, so it does not
      # break agreement — missing_in_tix would.
      assert result.agree?
    end

    test "a declared id that never landed is NAMED in scope, not hidden behind agree?", %{
      root: root,
      signing_context: ctx
    } do
      ex = export(jsonl([%{"id" => "CX-present", "title" => "here", "status" => "open"}]))
      {folded, _} = TixMigration.fold_needs(ex.records, ex.edges_in)
      _ = import_batch(folded, ctx)

      walk = TixMigration.walk_needs(root, CommitStoreClient)
      query = TixMigration.query_needs(root, ["CX-present", "CX-never-landed"], CommitStoreClient)

      result = TixMigration.three_way(walk, query, %{}, ["CX-present", "CX-never-landed"])

      # Both legs agree the ticket is absent — that IS agreement
      # between the legs, and a gate refusal is a finding, not an
      # acceptance failure. But "the legs agree" over a corpus that
      # landed half of what it declared must not READ as clean.
      assert result.agree?
      assert result.scope.ids == 2
      assert result.scope.walk_tickets == 1
      assert result.scope.query_tickets == 1
      assert result.scope.tickets_absent == ["CX-never-landed"]
    end
  end

  describe "EDGES-IN == LANDED ∪ REFUSED holds when the cycle gate refuses a ticket" do
    test "a mapped needs pair that closes a loop: the second record is refused BY NAME", %{
      root: root,
      signing_context: ctx
    } do
      # The legacy-cycle case §8 says to expect: the bd `blocks` graph
      # has never been under any cycle rule, so a pair of edges can
      # close a loop once mapped. bd: A blocks B AND B blocks A.
      # Mapped: B needs A, A needs B.
      issues =
        jsonl([
          %{"id" => "CX-loopA", "title" => "A", "status" => "open"},
          %{"id" => "CX-loopB", "title" => "B", "status" => "open"},
          %{"id" => "CX-loopOK", "title" => "innocent", "status" => "open"}
        ])

      deps =
        jsonl([
          %{"from" => "CX-loopB", "to" => "CX-loopA", "kind" => "blocks"},
          %{"from" => "CX-loopA", "to" => "CX-loopB", "kind" => "blocks"}
        ])

      ex = export(issues, deps)
      ids = TixMigration.record_ids(ex.records)
      {folded, fold_report} = TixMigration.fold_needs(ex.records, ex.edges_in)

      # Both edges FOLD cleanly — no pre-cleaning, the gate decides.
      assert length(fold_report.landed) == 2
      assert fold_report.refused == []
      assert fold_report.unaccounted == []

      batch = import_batch(folded, ctx)

      # A lands (needs B, which does not exist yet — nothing to walk).
      # B is refused: walking A's local-needs ancestors reaches B.
      assert batch.unaccounted == []
      assert [%{id: "CX-loopB", reason: reason}] = batch.refused
      assert reason =~ "cycle"
      assert reason =~ "CX-loopA"

      # Per-record: the innocent ticket in the same batch still lands.
      landed_ids = Enum.map(batch.landed, & &1.id) |> Enum.sort()
      assert landed_ids == ["CX-loopA", "CX-loopOK"]
      assert {:error, :not_found} = Issue.show(root, "CX-loopB")

      # THE EDGES IDENTITY, re-run against what tix actually holds.
      walk = TixMigration.walk_needs(root, CommitStoreClient)
      final = TixMigration.final_edge_accounting(fold_report, batch, walk)

      assert final.unaccounted == [],
             "every edge that arrived must still be landed-or-refused after the gate ran"

      accounted = MapSet.new(final.landed ++ Enum.map(final.refused, & &1.edge))
      assert MapSet.equal?(accounted, MapSet.new(final.edges_in))

      assert final.landed == ["CX-loopB blocks CX-loopA"]

      assert [%{edge: "CX-loopA blocks CX-loopB", reason: post_reason}] = final.refused
      assert post_reason =~ "ticket_refused_by_gate"
      assert post_reason =~ "cycle"

      # And the 3-way check REFUSES to call this clean: the bd leg
      # implies an edge tix does not have.
      result =
        TixMigration.three_way(
          walk,
          TixMigration.query_needs(root, ids, CommitStoreClient),
          TixMigration.bd_edge_projection(ex.edges_in),
          ids
        )

      assert result.bd_vs_tix.missing_in_tix == [{"CX-loopB", "CX-loopA"}]
      refute result.agree?
    end

    test "a self-blocking bd edge maps to a self-need and is refused, still accounted", %{
      root: root,
      signing_context: ctx
    } do
      ex =
        export(
          jsonl([%{"id" => "CX-selfblock", "title" => "S", "status" => "open"}]),
          jsonl([%{"from" => "CX-selfblock", "to" => "CX-selfblock", "kind" => "blocks"}])
        )

      {folded, fold_report} = TixMigration.fold_needs(ex.records, ex.edges_in)
      batch = import_batch(folded, ctx)

      assert [%{id: "CX-selfblock", reason: reason}] = batch.refused
      assert reason =~ "cycle"

      walk = TixMigration.walk_needs(root, CommitStoreClient)
      final = TixMigration.final_edge_accounting(fold_report, batch, walk)

      assert final.landed == []
      assert [%{edge: "CX-selfblock blocks CX-selfblock"}] = final.refused
      assert final.unaccounted == []
    end
  end

  describe "field_divergence/2 against a real tix corpus (CX-q7nh)" do
    test "an unchanged export diverges on nothing; a changed one shows per-hit shapes", %{
      root: root,
      signing_context: ctx
    } do
      records = [%{"id" => "CX-dv1", "title" => "same", "status" => "open", "priority" => 2}]
      _ = import_batch(records, ctx)

      tix =
        Issue.list(root, CommitStoreClient)
        |> Map.new(fn {issue, _uuid} -> {issue.id, issue} end)

      assert TixMigration.field_divergence(records, tix) == []

      drifted = [%{"id" => "CX-dv1", "title" => "different", "status" => "open", "priority" => 0}]
      hits = TixMigration.field_divergence(drifted, tix)

      assert %{id: "CX-dv1", field: :title, bd: "different", tix: "same"} in hits
      assert %{id: "CX-dv1", field: :priority, bd: "p0", tix: "p2"} in hits
    end
  end

  describe "live_set_diff/2 against a real tix listing — the RE-MEASURED denominator" do
    test "bd_only is derived from the actual corpora, not from a dated number", %{
      root: root,
      signing_context: ctx
    } do
      _ = import_batch([%{"id" => "CX-both", "title" => "in both", "status" => "open"}], ctx)

      _ =
        ViewActionDispatch.dispatch("ticket_create", %{
          args: %{"title" => "substrate native"},
          signing_context: ctx,
          source: "test"
        })

      bd_ids = ["CX-both", "CX-onlybd"]

      tix_ids =
        Issue.list(root, CommitStoreClient) |> Enum.map(fn {issue, _} -> issue.id end)

      diff = TixMigration.live_set_diff(bd_ids, tix_ids)

      assert diff.bd_only == ["CX-onlybd"]
      assert diff.both == ["CX-both"]
      assert length(diff.tix_only) == 1, "the natively-created ticket is tix-only, and expected"
      assert diff.tix_total == 2
    end
  end
end
