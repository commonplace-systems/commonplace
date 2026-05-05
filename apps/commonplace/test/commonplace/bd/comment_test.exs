defmodule Commonplace.Bd.CommentTest do
  use ExUnit.Case

  alias Commonplace.Bd.{Comment, Issue}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bd_comment_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    root = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root, update, nil)

    {:ok, issue, _} = Issue.create(root, %{title: "host"}, store)
    %{store: store, root: root, issue_id: issue.id}
  end

  test "add + list", ctx do
    {:ok, c1} = Comment.add(ctx.root, ctx.issue_id, %{body: "first", author: "alice"}, ctx.store)
    {:ok, c2} = Comment.add(ctx.root, ctx.issue_id, %{body: "second", author: "bob"}, ctx.store)

    list = Comment.list(ctx.root, ctx.issue_id, ctx.store)
    ids = Enum.map(list, & &1.id) |> Enum.sort()
    assert ids == Enum.sort([c1.id, c2.id])
  end

  test "edit replaces body and stamps edited_at", ctx do
    {:ok, c} = Comment.add(ctx.root, ctx.issue_id, %{body: "v1"}, ctx.store)
    Process.sleep(10)
    {:ok, edited} = Comment.edit(ctx.root, ctx.issue_id, c.id, "v2", ctx.store)
    assert edited.body == "v2"
    assert is_binary(edited.edited_at)
  end

  test "soft_delete sets flag but list still includes it", ctx do
    {:ok, c} = Comment.add(ctx.root, ctx.issue_id, %{body: "x"}, ctx.store)
    {:ok, _} = Comment.soft_delete(ctx.root, ctx.issue_id, c.id, ctx.store)
    [c2] = Comment.list(ctx.root, ctx.issue_id, ctx.store)
    assert c2.deleted == true
  end
end
