defmodule Commonplace.Bd.MigrateTest do
  use ExUnit.Case

  alias Commonplace.Bd.{Issue, Migrate}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bd_migrate_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_migrate_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    root = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root, update, nil)

    %{store: store, root: root}
  end

  defp jsonl(records) do
    records
    |> Enum.map(&Jason.encode!/1)
    |> Enum.join("\n")
  end

  describe "status filter" do
    test "closed and wontfix are skipped; open/in_progress/blocked/review are imported verbatim", ctx do
      export =
        jsonl([
          %{"id" => "CX-1", "title" => "open one", "status" => "open", "priority" => 2, "issue_type" => "task"},
          %{"id" => "CX-2", "title" => "in progress one", "status" => "in_progress", "priority" => 1, "issue_type" => "bug"},
          %{"id" => "CX-3", "title" => "blocked one", "status" => "blocked", "priority" => 2, "issue_type" => "task"},
          %{"id" => "CX-4", "title" => "review one", "status" => "review", "priority" => 2, "issue_type" => "task"},
          %{"id" => "CX-5", "title" => "closed one", "status" => "closed", "priority" => 2, "issue_type" => "task"},
          %{"id" => "CX-6", "title" => "wontfix one", "status" => "wontfix", "priority" => 2, "issue_type" => "task"}
        ])

      {:ok, result} = Migrate.import_from_export(ctx.root, export, ctx.store)

      assert result.imported == 4
      assert result.skipped_closed == 2

      for {id, expected_status} <- [
            {"CX-1", "open"},
            {"CX-2", "in_progress"},
            {"CX-3", "blocked"},
            {"CX-4", "review"}
          ] do
        {:ok, issue} = Issue.show(ctx.root, id, ctx.store)
        assert issue.status == expected_status
        assert issue.legacy_id == id
        assert issue.done_when == "manual"
        assert issue.claimed_by == nil
        assert issue.needs == []
      end

      assert {:error, :not_found} = Issue.show(ctx.root, "CX-5", ctx.store)
      assert {:error, :not_found} = Issue.show(ctx.root, "CX-6", ctx.store)
    end
  end

  describe "no tokens minted" do
    test "an imported in_progress issue has claimed_by nil", ctx do
      export =
        jsonl([
          %{"id" => "CX-ip", "title" => "wip", "status" => "in_progress", "priority" => 1, "issue_type" => "task"}
        ])

      {:ok, _result} = Migrate.import_from_export(ctx.root, export, ctx.store)

      {:ok, issue} = Issue.show(ctx.root, "CX-ip", ctx.store)
      assert issue.claimed_by == nil
    end
  end

  describe "C-invariant drop" do
    test "a dep whose prereq is closed (not imported) is dropped and manifested", ctx do
      export =
        jsonl([
          %{"id" => "CX-closed-prereq", "title" => "closed prereq", "status" => "closed", "priority" => 2, "issue_type" => "task"},
          %{
            "id" => "CX-dependent",
            "title" => "dependent",
            "status" => "open",
            "priority" => 2,
            "issue_type" => "task",
            "dependencies" => [
              %{"issue_id" => "CX-dependent", "depends_on_id" => "CX-closed-prereq", "type" => "blocks"}
            ]
          }
        ])

      {:ok, result} = Migrate.import_from_export(ctx.root, export, ctx.store)

      assert result.edges_added == 0
      assert [%{from: "CX-closed-prereq", to: "CX-dependent", reason: :prereq_not_imported}] = result.manifest

      {:ok, issue} = Issue.show(ctx.root, "CX-dependent", ctx.store)
      refute Enum.any?(issue.needs, fn %{"ticket" => t} -> t == "CX-closed-prereq" end)
    end
  end

  describe "guarded edge add" do
    test "a dep between two imported tickets adds needs via the guard", ctx do
      export =
        jsonl([
          %{"id" => "CX-a", "title" => "A", "status" => "open", "priority" => 2, "issue_type" => "task"},
          %{
            "id" => "CX-b",
            "title" => "B",
            "status" => "open",
            "priority" => 2,
            "issue_type" => "task",
            "dependencies" => [%{"issue_id" => "CX-b", "depends_on_id" => "CX-a", "type" => "blocks"}]
          }
        ])

      {:ok, result} = Migrate.import_from_export(ctx.root, export, ctx.store)

      assert result.edges_added == 1
      assert result.manifest == []

      {:ok, issue_b} = Issue.show(ctx.root, "CX-b", ctx.store)
      assert Enum.any?(issue_b.needs, fn %{"ticket" => t} -> t == "CX-a" end)
    end

    test "a would-be cycle among imported tickets is refused and manifested, not forced", ctx do
      # X blocks Y (Y.needs gains X), Y blocks X (X.needs would gain Y) -> cycle.
      export =
        jsonl([
          %{
            "id" => "CX-x",
            "title" => "X",
            "status" => "open",
            "priority" => 2,
            "issue_type" => "task",
            "dependencies" => [%{"issue_id" => "CX-x", "depends_on_id" => "CX-y", "type" => "blocks"}]
          },
          %{
            "id" => "CX-y",
            "title" => "Y",
            "status" => "open",
            "priority" => 2,
            "issue_type" => "task",
            "dependencies" => [%{"issue_id" => "CX-y", "depends_on_id" => "CX-x", "type" => "blocks"}]
          }
        ])

      {:ok, result} = Migrate.import_from_export(ctx.root, export, ctx.store)

      # One edge lands, the other is refused as a cycle.
      assert result.edges_added == 1
      assert [%{reason: :guard_refused} = manifested] = result.manifest
      assert manifested.from in ["CX-x", "CX-y"]
      assert manifested.to in ["CX-x", "CX-y"]
    end
  end

  describe "blocks-only filter" do
    test "a parent-child dependency edge is NOT converted into needs", ctx do
      export =
        jsonl([
          %{"id" => "CX-epic", "title" => "epic", "status" => "open", "priority" => 2, "issue_type" => "epic"},
          %{
            "id" => "CX-sub",
            "title" => "subtask",
            "status" => "open",
            "priority" => 2,
            "issue_type" => "task",
            "dependencies" => [
              %{"issue_id" => "CX-sub", "depends_on_id" => "CX-epic", "type" => "parent-child"}
            ]
          }
        ])

      {:ok, result} = Migrate.import_from_export(ctx.root, export, ctx.store)

      assert result.edges_added == 0
      assert result.manifest == []

      {:ok, issue_sub} = Issue.show(ctx.root, "CX-sub", ctx.store)
      assert issue_sub.needs == []
    end

    test "supersedes and related edges are also skipped, only blocks converts", ctx do
      export =
        jsonl([
          %{"id" => "CX-old", "title" => "old", "status" => "open", "priority" => 2, "issue_type" => "task"},
          %{"id" => "CX-friend", "title" => "friend", "status" => "open", "priority" => 2, "issue_type" => "task"},
          %{"id" => "CX-blocker", "title" => "blocker", "status" => "open", "priority" => 2, "issue_type" => "task"},
          %{
            "id" => "CX-mixed",
            "title" => "mixed",
            "status" => "open",
            "priority" => 2,
            "issue_type" => "task",
            "dependencies" => [
              %{"issue_id" => "CX-mixed", "depends_on_id" => "CX-old", "type" => "supersedes"},
              %{"issue_id" => "CX-mixed", "depends_on_id" => "CX-friend", "type" => "related"},
              %{"issue_id" => "CX-mixed", "depends_on_id" => "CX-blocker", "type" => "blocks"}
            ]
          }
        ])

      {:ok, result} = Migrate.import_from_export(ctx.root, export, ctx.store)

      assert result.edges_added == 1
      assert result.manifest == []

      {:ok, issue_mixed} = Issue.show(ctx.root, "CX-mixed", ctx.store)
      needs_tickets = Enum.map(issue_mixed.needs, & &1["ticket"])
      assert needs_tickets == ["CX-blocker"]
    end
  end

  describe "three_way/3" do
    test "agrees when query, walk, and supplied bd_cli ready ids all match", ctx do
      export =
        jsonl([
          %{"id" => "CX-r1", "title" => "ready one", "status" => "open", "priority" => 2, "issue_type" => "task"},
          %{
            "id" => "CX-blocked1",
            "title" => "blocked one",
            "status" => "open",
            "priority" => 2,
            "issue_type" => "task",
            "dependencies" => [%{"issue_id" => "CX-blocked1", "depends_on_id" => "CX-r1", "type" => "blocks"}]
          }
        ])

      {:ok, _result} = Migrate.import_from_export(ctx.root, export, ctx.store)

      result = Migrate.three_way(ctx.root, ctx.store, MapSet.new(["CX-r1"]))

      assert result.agree? == true
      assert result.query == MapSet.new(["CX-r1"])
      assert result.walk == MapSet.new(["CX-r1"])
      assert result.bd_cli == MapSet.new(["CX-r1"])
    end

    test "disagreement is localized and non-vacuous when bd_cli set is wrong", ctx do
      export =
        jsonl([
          %{"id" => "CX-r2", "title" => "ready two", "status" => "open", "priority" => 2, "issue_type" => "task"}
        ])

      {:ok, _result} = Migrate.import_from_export(ctx.root, export, ctx.store)

      # Perturb: claim a bd-ready set that has a spurious extra id not
      # actually ready per query/walk.
      bad_bd_cli = MapSet.new(["CX-r2", "CX-phantom"])

      result = Migrate.three_way(ctx.root, ctx.store, bad_bd_cli)

      refute result.agree?
      assert MapSet.member?(result.only_in_bd_cli, "CX-phantom")
      refute MapSet.member?(result.only_in_query, "CX-phantom")
      refute MapSet.member?(result.only_in_walk, "CX-phantom")
    end
  end
end
