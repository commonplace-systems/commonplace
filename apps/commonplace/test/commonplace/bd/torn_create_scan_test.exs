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

    assert {:ok, :ui_transition,
            %{
              action: "ticket_torn_creates",
              torn_creates: [{"CX-7cpf", @cx_7cpf_doc, _created_at}],
              auto_link: false
            }} =
             Commonplace.ViewActionDispatch.dispatch("ticket_torn_creates", %{
               root_uuid: ctx.root,
               store: ctx.store,
               args: %{}
             })

    assert Workspace.issue_dir_uuid(ctx.root, "CX-7cpf", ctx.store) == :error
    assert IssueDocIndex.visible_issue_docs(ctx.root, ctx.store) == MapSet.new()
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
