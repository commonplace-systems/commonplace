defmodule Commonplace.Bd.IssueDocIndexTest do
  use ExUnit.Case, async: false

  alias Commonplace.Bd.{Issue, IssueDocIndex, Schemas, Workspace}
  alias Commonplace.Bd.Schemas.Issue, as: IssueRecord
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema
  alias Yelixer.{Doc, Encoding}
  alias Commonplace.Document.ContentType

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_issue_doc_index_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    store = :"issue_doc_index_#{System.unique_integer([:positive])}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    root = UUID.uuid4()
    CommitStore.create_commit(store, root, Encoding.encode_update(Schema.new_schema()), nil)
    _issues = Workspace.issues_dir_uuid(root, store)

    %{store: store, root: root}
  end

  test "clean creates atomically index their issue docs and preserve index superset directory",
       ctx do
    for id <- ["CX-clean1", "CX-clean2", "CX-clean3"] do
      issue = Issue.build_with_id(id, %{title: id})
      assert {:ok, ^issue, _dir_uuid} = Issue.create_with_id(ctx.root, issue, "", ctx.store)
    end

    indexed = IssueDocIndex.entries(ctx.store)
    visible = IssueDocIndex.visible_issue_docs(ctx.root, ctx.store)

    assert MapSet.subset?(visible, indexed)
    assert MapSet.size(visible) == 3
  end

  test "one-time gated backfill accounts LANDED union REFUSED exactly to declared issue docs",
       ctx do
    linked = pre_index_issue_doc!(ctx.store, "legacy-linked-doc", "CX-legacy-linked")
    orphan = pre_index_issue_doc!(ctx.store, "legacy-orphan-doc", "CX-legacy-orphan")
    link_issue_doc!(ctx.root, ctx.store, "CX-legacy-linked", linked)

    assert IssueDocIndex.entries(ctx.store) == MapSet.new()

    assert {:ok, :tree_mutation, report} =
             Commonplace.ViewActionDispatch.dispatch("ticket_issue_index_backfill", %{
               root_uuid: ctx.root,
               store: ctx.store,
               args: %{"confirm" => "BACKFILL ISSUE DOC INDEX"}
             })

    input = MapSet.new(report.input)
    accounted = MapSet.new(report.landed ++ Enum.map(report.refused, & &1.doc_uuid))

    assert input == MapSet.new([linked, orphan])

    assert MapSet.union(
             MapSet.new(report.landed),
             MapSet.new(Enum.map(report.refused, & &1.doc_uuid))
           ) == input

    assert accounted == input
    assert report.refused == []
    assert report.unaccounted == []
    assert IssueDocIndex.entries(ctx.store) == input
    assert [{"CX-legacy-orphan", ^orphan, _created_at}] = IssueDocIndex.scan(ctx.root, ctx.store)
  end

  defp pre_index_issue_doc!(store, uuid, id) do
    issue = %IssueRecord{
      id: id,
      title: id,
      status: "open",
      priority: "p2",
      type: "task",
      created_at: "2026-08-12T00:00:00Z",
      updated_at: "2026-08-12T00:00:00Z",
      labels: [],
      needs: [],
      done_when: "manual",
      done_witness: [],
      extra: %{}
    }

    doc = Doc.new() |> ContentType.create(:text, "metadata")
    doc = ContentType.insert_text(doc, 0, Schemas.encode_issue(issue))
    _commit = CommitStoreClient.create_commit(store, uuid, Encoding.encode_update(doc), nil)
    uuid
  end

  defp link_issue_doc!(root, store, id, issue_doc_uuid) do
    dir_uuid = UUID.uuid4()
    dir_schema = Schema.new_schema() |> Schema.add_file(Schemas.issue_filename(), issue_doc_uuid)

    _commit =
      CommitStoreClient.create_commit(store, dir_uuid, Encoding.encode_update(dir_schema), nil)

    issues_uuid = Workspace.issues_dir_uuid(root, store)
    {:ok, issues_schema} = Schemas.load_dir_schema(issues_uuid, store)
    issues_schema = Schema.add_directory(issues_schema, "#{id}.iss", dir_uuid)

    _commit =
      CommitStoreClient.create_chained_commit(
        store,
        issues_uuid,
        Encoding.encode_update(issues_schema)
      )

    :ok
  end
end
