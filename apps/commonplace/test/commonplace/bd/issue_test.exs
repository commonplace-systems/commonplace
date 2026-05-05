defmodule Commonplace.Bd.IssueTest do
  use ExUnit.Case

  alias Commonplace.Bd.{Issue, Workspace}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bd_issue_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    root = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root, update, nil)

    %{store: store, root: root}
  end

  test "create + show round-trip", ctx do
    {:ok, issue, _dir} = Issue.create(ctx.root, %{title: "test", priority: "p1"}, ctx.store)
    assert issue.title == "test"
    assert issue.priority == "p1"
    assert issue.status == "open"
    assert String.starts_with?(issue.id, "CX-")

    {:ok, fetched} = Issue.show(ctx.root, issue.id, ctx.store)
    assert fetched.id == issue.id
    assert fetched.title == "test"
  end

  test "update modifies fields and bumps updated_at", ctx do
    {:ok, issue, _} = Issue.create(ctx.root, %{title: "x"}, ctx.store)
    Process.sleep(15)
    {:ok, updated} = Issue.update(ctx.root, issue.id, %{status: "in_progress", owner: "alice"}, ctx.store)
    assert updated.status == "in_progress"
    assert updated.owner == "alice"
    assert updated.updated_at != issue.updated_at
  end

  test "close sets closed_at and closed_reason", ctx do
    {:ok, issue, _} = Issue.create(ctx.root, %{title: "y"}, ctx.store)
    {:ok, closed} = Issue.close(ctx.root, issue.id, [reason: "did it"], ctx.store)
    assert closed.status == "closed"
    assert is_binary(closed.closed_at)
    assert closed.closed_reason == "did it"
  end

  test "list returns every created issue", ctx do
    {:ok, a, _} = Issue.create(ctx.root, %{title: "a"}, ctx.store)
    {:ok, b, _} = Issue.create(ctx.root, %{title: "b"}, ctx.store)
    {:ok, c, _} = Issue.create(ctx.root, %{title: "c"}, ctx.store)

    ids = Issue.list(ctx.root, ctx.store) |> Enum.map(fn {i, _} -> i.id end) |> Enum.sort()
    assert Enum.sort([a.id, b.id, c.id]) == ids
  end

  test "show returns :not_found for unknown id", ctx do
    assert {:error, :not_found} = Issue.show(ctx.root, "CX-zzzz", ctx.store)
  end

  test "ensure_bd_dir is idempotent", ctx do
    a = Workspace.ensure_bd_dir(ctx.root, ctx.store)
    b = Workspace.ensure_bd_dir(ctx.root, ctx.store)
    assert a == b
  end

  test "description round-trips", ctx do
    {:ok, issue, _} = Issue.create(ctx.root, %{title: "z", description: "the body"}, ctx.store)
    {:ok, body} = Issue.description(ctx.root, issue.id, ctx.store)
    assert body == "the body"
  end
end
