defmodule Commonplace.Bd.IssueDocIndexTest do
  use ExUnit.Case, async: false

  alias Commonplace.Bd.{Comment, Issue, IssueDocIndex, Schemas, Workspace}
  alias Commonplace.Bd.Schemas.Issue, as: IssueRecord
  alias Commonplace.Store.{CommitStore, CommitStoreClient}
  alias Commonplace.Tree.{DocBuilder, Schema}
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
    {linked_dir, linked} =
      pre_index_issue_dir!(
        ctx.store,
        "legacy-linked-dir",
        "legacy-linked-doc",
        "CX-legacy-linked"
      )

    {_orphan_dir, orphan} =
      pre_index_issue_dir!(ctx.store, "legacy-orphan-dir", "legacy-orphan-doc", "CX-7cpf")

    link_issue_dir!(ctx.root, ctx.store, "CX-legacy-linked", linked_dir)

    comment_doc =
      pre_index_json_doc!(ctx.store, "legacy-comment-doc", %{
        "id" => "c-XXXX",
        "created_at" => "2026-08-12T00:00:00Z",
        "body" => "shape collision"
      })

    chat_doc =
      pre_index_json_doc!(ctx.store, "legacy-chat-doc", %{
        "id" => "019eb2d7-d95e-7184-a0d6-9de7a813d426",
        "created_at" => "2026-08-12T00:00:00Z",
        "text" => "shape collision"
      })

    assert old_shape_issue_doc?(comment_doc, ctx.store)
    assert old_shape_issue_doc?(chat_doc, ctx.store)
    assert old_shape_issue_doc?(orphan, ctx.store)

    first_backfill_rows = MapSet.new([linked, orphan, comment_doc, chat_doc])

    Enum.each(
      first_backfill_rows,
      &assert(:ok = CommitStoreClient.append_bd_issue_doc(ctx.store, &1))
    )

    assert IssueDocIndex.entries(ctx.store) == first_backfill_rows

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
    assert MapSet.new(report.superseded) == MapSet.new([comment_doc, chat_doc])
    assert report.supersession_refused == []
    assert IssueDocIndex.entries(ctx.store) == input

    assert Map.keys(IssueDocIndex.supersessions(ctx.store)) |> MapSet.new() ==
             MapSet.new([comment_doc, chat_doc])

    assert [{"CX-7cpf", ^orphan, _created_at}] = IssueDocIndex.scan(ctx.root, ctx.store)
  end

  test "fresh comment and issue-shaped chat docs are not backfilled or scanned", ctx do
    issue = Issue.build_with_id("CX-fresh", %{title: "fresh"})
    assert {:ok, ^issue, issue_dir} = Issue.create_with_id(ctx.root, issue, "", ctx.store)

    assert {:ok, _comment} =
             Comment.add(ctx.root, issue.id, %{id: "c-fresh", body: "fresh"}, ctx.store)

    {:ok, issue_schema} = Schemas.load_dir_schema(issue_dir, ctx.store)
    {:ok, comments_entry} = Schema.get_entry(issue_schema, "comments")
    {:ok, comments_schema} = Schemas.load_dir_schema(comments_entry.node_id, ctx.store)
    {:ok, comment_entry} = Schema.get_entry(comments_schema, "c-fresh.json")

    chat_doc =
      pre_index_json_doc!(ctx.store, "fresh-chat-doc", %{
        "id" => "019eb2d7-d95e-7184-a0d6-9de7a813d426",
        "created_at" => "2026-08-12T00:00:00Z",
        "text" => "fresh"
      })

    assert {:ok, report} = IssueDocIndex.backfill(ctx.root, ctx.store)
    refute comment_entry.node_id in report.input
    refute chat_doc in report.input
    assert IssueDocIndex.scan(ctx.root, ctx.store) == []
  end

  defp pre_index_issue_dir!(store, dir_uuid, doc_uuid, id) do
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

    issue_doc = pre_index_json_doc!(store, doc_uuid, Schemas.encode_issue(issue))
    dir_schema = Schema.new_schema() |> Schema.add_file(Schemas.issue_filename(), issue_doc)

    _commit =
      CommitStoreClient.create_commit(store, dir_uuid, Encoding.encode_update(dir_schema), nil)

    {dir_uuid, issue_doc}
  end

  defp link_issue_dir!(root, store, id, dir_uuid) do
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

  defp pre_index_json_doc!(store, uuid, json) when is_map(json),
    do: pre_index_json_doc!(store, uuid, Jason.encode!(json))

  defp pre_index_json_doc!(store, uuid, json) when is_binary(json) do
    doc = Doc.new() |> ContentType.create(:text, "metadata")
    doc = ContentType.insert_text(doc, 0, json)
    _commit = CommitStoreClient.create_commit(store, uuid, Encoding.encode_update(doc), nil)
    uuid
  end

  defp old_shape_issue_doc?(doc_uuid, store) do
    with {:ok, doc} <- DocBuilder.reconstruct_doc(store, doc_uuid),
         json when is_binary(json) <- ContentType.get_content(doc),
         {:ok, issue} <- Schemas.decode_issue(json),
         id when is_binary(id) and id != "" <- issue.id,
         created_at when is_binary(created_at) and created_at != "" <- issue.created_at do
      true
    else
      _ -> false
    end
  end
end
