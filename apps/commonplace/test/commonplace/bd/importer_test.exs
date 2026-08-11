defmodule Commonplace.Bd.ImporterTest do
  use ExUnit.Case

  alias Commonplace.Bd.{Frontier, Importer, Issue}
  alias Commonplace.Bd.RetiredGraphError
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.{DocBuilder, Schema}
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bd_importer_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    root = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root, update, nil)

    %{dir: dir, store: store, root: root}
  end

  defp issue_jsonl(records) do
    records
    |> Enum.map(&Jason.encode!/1)
    |> Enum.join("\n")
  end

  test "a refused bd ensure stops the issue import without a partial /bd/", ctx do
    root = minimal_root!(ctx.store, ctx.dir)
    text = issue_jsonl([%{"id" => "CX-refused", "title" => "must not import"}])

    assert {:error, refusal} = Importer.import_issues_jsonl(root, text, ctx.store)

    assert refusal ==
             "bd ensure refused before issue import: " <>
               "{:trust_rejected, \"workspace class 'minimal' does not accept root entry 'bd' — declared in profile\"}; " <>
               "issue import did not run"

    assert :error = Schema.get_entry(load_schema!(ctx.store, root), "bd")
  end

  test "imports a single issue with priority-int normalization", ctx do
    text =
      issue_jsonl([
        %{
          "id" => "CX-test",
          "title" => "first import",
          "status" => "open",
          "priority" => 1,
          "issue_type" => "bug",
          "owner" => "alice",
          "description" => "the body",
          "created_at" => "2026-01-01T00:00:00Z"
        }
      ])

    {:ok, %{imported: 1, updated: 0, errors: []}} =
      Importer.import_issues_jsonl(ctx.root, text, ctx.store)

    {:ok, issue} = Issue.show(ctx.root, "CX-test", ctx.store)
    assert issue.title == "first import"
    assert issue.priority == "p1"
    assert issue.type == "bug"
    assert issue.owner == "alice"

    {:ok, body} = Issue.description(ctx.root, "CX-test", ctx.store)
    assert body == "the body"
  end

  defp minimal_root!(store, data_dir) do
    root = UUID.uuid4()
    schema = Schema.new_schema() |> Schema.put_workspace_profile(:minimal)
    CommitStore.create_commit(store, root, Encoding.encode_update(schema), nil)
    File.write!(Path.join(data_dir, "root"), root)
    root
  end

  defp load_schema!(store, uuid) do
    {:ok, schema} = DocBuilder.reconstruct_snapshot(store, uuid)
    schema
  end

  test "re-import is idempotent — second pass updates instead of duplicating", ctx do
    text =
      issue_jsonl([
        %{"id" => "CX-x", "title" => "v1", "status" => "open", "priority" => 2}
      ])

    {:ok, %{imported: 1, updated: 0}} = Importer.import_issues_jsonl(ctx.root, text, ctx.store)

    text2 =
      issue_jsonl([
        %{"id" => "CX-x", "title" => "v2", "status" => "in_progress", "priority" => 1}
      ])

    {:ok, %{imported: 0, updated: 1}} = Importer.import_issues_jsonl(ctx.root, text2, ctx.store)

    {:ok, issue} = Issue.show(ctx.root, "CX-x", ctx.store)
    assert issue.title == "v2"
    assert issue.status == "in_progress"
    assert issue.priority == "p1"

    # And the issue list still has just one entry.
    assert length(Issue.list(ctx.root, ctx.store)) == 1
  end

  # CX-hrbn. The separate edge stream wrote /bd/deps.json, retired at
  # the 2026-08-05 cutover. It refuses rather than reporting an import
  # count for edges nothing will ever read.
  test "the deps-stream leg refuses loudly and names its replacement", ctx do
    deps_text =
      [%{"from" => "CX-a", "to" => "CX-b", "kind" => "blocks"}]
      |> Enum.map(&Jason.encode!/1)
      |> Enum.join("\n")

    err =
      assert_raise(RetiredGraphError, fn ->
        Importer.import_deps_jsonl(ctx.root, deps_text, ctx.store)
      end)

    msg = Exception.message(err)
    assert msg =~ "RETIRED"
    assert msg =~ "2026-08-05"
    assert msg =~ "import_issues_jsonl/4"
    assert msg =~ "needs"
  end

  # ...and the replacement it names actually works: the same edge,
  # carried inline on the dependent's record, lands in the live graph.
  test "an edge carried as `needs` on the record imports and is walked by the frontier", ctx do
    issue_text =
      issue_jsonl([
        %{"id" => "CX-a", "title" => "A", "status" => "open", "priority" => 2},
        %{
          "id" => "CX-b",
          "title" => "B",
          "status" => "open",
          "priority" => 2,
          "needs" => [%{"ticket" => "CX-a"}]
        }
      ])

    {:ok, _} = Importer.import_issues_jsonl(ctx.root, issue_text, ctx.store)

    {:ok, b} = Issue.show(ctx.root, "CX-b", ctx.store)
    assert b.needs == [%{"ticket" => "CX-a"}]

    ready_ids = Frontier.ready_walk(ctx.root, ctx.store) |> Enum.map(& &1.id)
    blocked_ids = Frontier.blocked_walk(ctx.root, ctx.store) |> Enum.map(& &1.id)

    assert "CX-a" in ready_ids
    assert "CX-b" in blocked_ids
  end

  test "DEMO BAR — import + native create + bd ready returns the new issue", ctx do
    # Step 1: import a small JSONL fixture: one open issue, one closed.
    text =
      issue_jsonl([
        %{"id" => "CX-imp1", "title" => "from import (open)", "status" => "open", "priority" => 2},
        %{"id" => "CX-imp2", "title" => "from import (closed)", "status" => "closed", "priority" => 2}
      ])

    {:ok, %{imported: 2}} = Importer.import_issues_jsonl(ctx.root, text, ctx.store)

    # Step 2: native bd create (CX-test "thing").
    {:ok, native, _} = Issue.create(ctx.root, %{title: "thing"}, ctx.store)

    # Step 3: bd ready returns the native one + the imported open one,
    # filters out the closed one. Walk-based, over `needs` (CX-hrbn
    # repointed this off the retired /bd/deps.json walk).
    ready_ids = Frontier.ready_walk(ctx.root, ctx.store) |> Enum.map(& &1.id) |> Enum.sort()

    assert native.id in ready_ids
    assert "CX-imp1" in ready_ids
    refute "CX-imp2" in ready_ids
  end

  test "imports tolerate string-priority and string-status", ctx do
    text =
      issue_jsonl([
        %{"id" => "CX-str", "title" => "str", "status" => "open", "priority" => "p3"}
      ])

    {:ok, %{imported: 1}} = Importer.import_issues_jsonl(ctx.root, text, ctx.store)
    {:ok, issue} = Issue.show(ctx.root, "CX-str", ctx.store)
    assert issue.priority == "p3"
  end

  test "preserves unknown fields in extra", ctx do
    text =
      issue_jsonl([
        %{
          "id" => "CX-ex",
          "title" => "extra",
          "status" => "open",
          "priority" => 2,
          "severity" => "high",
          "team" => "platform"
        }
      ])

    {:ok, _} = Importer.import_issues_jsonl(ctx.root, text, ctx.store)
    {:ok, issue} = Issue.show(ctx.root, "CX-ex", ctx.store)
    assert issue.extra["severity"] == "high"
    assert issue.extra["team"] == "platform"
  end

  test "blocked-by-non-closed issues are excluded from ready", ctx do
    text =
      issue_jsonl([
        %{"id" => "CX-blocker", "title" => "blocker", "status" => "open", "priority" => 2},
        %{
          "id" => "CX-blocked",
          "title" => "blocked",
          "status" => "open",
          "priority" => 2,
          "needs" => [%{"ticket" => "CX-blocker"}]
        }
      ])

    {:ok, _} = Importer.import_issues_jsonl(ctx.root, text, ctx.store)

    ready_ids = Frontier.ready_walk(ctx.root, ctx.store) |> Enum.map(& &1.id)
    assert "CX-blocker" in ready_ids
    refute "CX-blocked" in ready_ids
  end

  test "blocked-by-closed issues ARE in ready (closed blockers don't block)", ctx do
    text =
      issue_jsonl([
        %{"id" => "CX-closed-block", "title" => "done", "status" => "closed", "priority" => 2},
        %{
          "id" => "CX-now-ready",
          "title" => "ready",
          "status" => "open",
          "priority" => 2,
          "needs" => [%{"ticket" => "CX-closed-block"}]
        }
      ])

    {:ok, _} = Importer.import_issues_jsonl(ctx.root, text, ctx.store)

    ready_ids = Frontier.ready_walk(ctx.root, ctx.store) |> Enum.map(& &1.id)
    assert "CX-now-ready" in ready_ids
  end
end
