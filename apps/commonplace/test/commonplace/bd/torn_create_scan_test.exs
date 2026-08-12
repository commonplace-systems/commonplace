defmodule Commonplace.Bd.TornCreateScanTest do
  use ExUnit.Case, async: false

  alias Commonplace.Bd.{Issue, IssueDocIndex, Schemas, Workspace}
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.Schema
  alias Commonplace.Document.ContentType
  alias Yelixer.{Doc, Encoding}

  @cx_7cpf_doc "252c2df9-5caf-470d-9e51-fb24bbb9c289"

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_torn_create_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    store = :"torn_create_#{System.unique_integer([:positive])}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    root = UUID.uuid4()
    CommitStore.create_commit(store, root, Encoding.encode_update(Schema.new_schema()), nil)
    _issues = Workspace.issues_dir_uuid(root, store)

    %{store: store, root: root}
  end

  test "TORN-CREATE ARM: commit-1 has index, directory has no link, index-minus-directory returns exactly CX-7cpf",
       ctx do
    issue = Issue.build_with_id("CX-7cpf", %{title: "torn create fixture"})
    write_indexed_issue_doc!(ctx.store, @cx_7cpf_doc, issue)

    assert MapSet.member?(IssueDocIndex.entries(ctx.store), @cx_7cpf_doc)
    assert Workspace.issue_dir_uuid(ctx.root, "CX-7cpf", ctx.store) == :error

    assert [{"CX-7cpf", @cx_7cpf_doc, created_at}] =
             IssueDocIndex.scan(ctx.root, ctx.store)

    assert created_at == issue.created_at
  end

  test "clean create makes the paired empty scan falsifiable", ctx do
    issue = Issue.build_with_id("CX-clean", %{title: "clean"})
    assert {:ok, ^issue, _dir_uuid} = Issue.create_with_id(ctx.root, issue, "", ctx.store)

    assert IssueDocIndex.scan(ctx.root, ctx.store) == []

    assert MapSet.subset?(
             IssueDocIndex.visible_issue_docs(ctx.root, ctx.store),
             IssueDocIndex.entries(ctx.store)
           )
  end

  test "on-demand torn-list action is loud and has NO auto-link path", ctx do
    issue = Issue.build_with_id("CX-7cpf", %{title: "torn create fixture"})
    write_indexed_issue_doc!(ctx.store, @cx_7cpf_doc, issue)
    store_before = store_fingerprint(ctx.store)

    assert {:ok, :ui_transition,
            %{
              action: "ticket_torn_creates",
              torn_creates: [{"CX-7cpf", @cx_7cpf_doc, _created_at}],
              covered_declared_docs: 1,
              outside_coverage: 0,
              coverage_warning:
                "ONLY DECLARED ISSUE DOCS ARE COVERED; MANUALLY REVIEW THE SUPERSEDED SET FOR UNDECLARED DOCS OUTSIDE THIS SCAN",
              auto_link: false
            }} =
             Commonplace.ViewActionDispatch.dispatch("ticket_torn_creates", %{
               root_uuid: ctx.root,
               store: ctx.store,
               args: %{}
             })

    assert store_fingerprint(ctx.store) == store_before
    assert Workspace.issue_dir_uuid(ctx.root, "CX-7cpf", ctx.store) == :error
    assert IssueDocIndex.visible_issue_docs(ctx.root, ctx.store) == MapSet.new()
  end

  test "dispatch coverage counts are read from effective entries and supersessions", ctx do
    covered_issue = Issue.build_with_id("CX-covered", %{title: "covered declaration"})
    write_indexed_issue_doc!(ctx.store, "covered-doc", covered_issue)

    superseded_issue = Issue.build_with_id("CX-superseded", %{title: "superseded declaration"})
    write_indexed_issue_doc!(ctx.store, "superseded-doc", superseded_issue)

    assert :ok =
             CommitStoreClient.append_bd_issue_doc_supersession(
               ctx.store,
               "superseded-doc",
               %{reason: :fixture}
             )

    assert {:ok, :ui_transition,
            %{
              covered_declared_docs: 1,
              outside_coverage: 1,
              coverage_warning:
                "ONLY DECLARED ISSUE DOCS ARE COVERED; MANUALLY REVIEW THE SUPERSEDED SET FOR UNDECLARED DOCS OUTSIDE THIS SCAN"
            }} = dispatch_scan(ctx)
  end

  test "fresh store reports full declared-doc coverage with zero supersessions", ctx do
    assert {:ok, :ui_transition,
            %{
              torn_creates: [],
              covered_declared_docs: 0,
              outside_coverage: 0,
              coverage_warning:
                "ONLY DECLARED ISSUE DOCS ARE COVERED; MANUALLY REVIEW THE SUPERSEDED SET FOR UNDECLARED DOCS OUTSIDE THIS SCAN"
            }} = dispatch_scan(ctx)
  end

  defp dispatch_scan(ctx) do
    Commonplace.ViewActionDispatch.dispatch("ticket_torn_creates", %{
      root_uuid: ctx.root,
      store: ctx.store,
      args: %{}
    })
  end

  defp store_fingerprint(store) do
    doc_uuids = CommitStoreClient.all_doc_uuids(store)

    %{
      doc_uuids: doc_uuids,
      commit_ids: Map.new(doc_uuids, &{&1, CommitStoreClient.commit_ids_for_doc(store, &1)}),
      issue_doc_entries: IssueDocIndex.entries(store),
      supersessions: IssueDocIndex.supersessions(store)
    }
  end

  defp write_indexed_issue_doc!(store, uuid, issue) do
    doc = Doc.new() |> ContentType.create(:text, "metadata")
    doc = ContentType.insert_text(doc, 0, Schemas.encode_issue(issue))

    _commit =
      CommitStoreClient.create_commit(
        store,
        uuid,
        Encoding.encode_update(doc),
        nil,
        IssueDocIndex.creation_metadata()
      )

    :ok
  end
end
