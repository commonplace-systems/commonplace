defmodule Commonplace.Bd.LabelTest do
  use ExUnit.Case

  alias Commonplace.Bd.{Issue, Label}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bd_label_#{:rand.uniform(1_000_000)}")
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

  test "create + list", ctx do
    {:ok, l, _} = Label.create(ctx.root, "bug", %{color: "red"}, ctx.store)
    assert l.name == "bug"
    assert [%{name: "bug", color: "red"}] = Label.list(ctx.root, ctx.store)
  end

  test "create is idempotent — re-create updates the existing label", ctx do
    {:ok, _, _} = Label.create(ctx.root, "perf", %{color: "blue"}, ctx.store)
    {:ok, _, _} = Label.create(ctx.root, "perf", %{color: "green", description: "speed"}, ctx.store)

    [l] = Label.list(ctx.root, ctx.store)
    assert l.color == "green"
    assert l.description == "speed"
  end

  test "assign + unassign", ctx do
    {:ok, _, _} = Label.create(ctx.root, "bug", %{}, ctx.store)
    {:ok, _} = Label.assign(ctx.root, ctx.issue_id, "bug", ctx.store)
    {:ok, issue} = Issue.show(ctx.root, ctx.issue_id, ctx.store)
    assert "bug" in issue.labels

    {:ok, _} = Label.unassign(ctx.root, ctx.issue_id, "bug", ctx.store)
    {:ok, issue2} = Issue.show(ctx.root, ctx.issue_id, ctx.store)
    refute "bug" in issue2.labels
  end

  test "assigning the same label twice is idempotent", ctx do
    {:ok, _, _} = Label.create(ctx.root, "perf", %{}, ctx.store)
    {:ok, _} = Label.assign(ctx.root, ctx.issue_id, "perf", ctx.store)
    {:ok, _} = Label.assign(ctx.root, ctx.issue_id, "perf", ctx.store)
    {:ok, issue} = Issue.show(ctx.root, ctx.issue_id, ctx.store)
    assert issue.labels == ["perf"]
  end
end
