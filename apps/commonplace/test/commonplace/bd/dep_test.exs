defmodule Commonplace.Bd.DepTest do
  use ExUnit.Case

  alias Commonplace.Bd.{Dep, Issue}
  alias Commonplace.Bd.Schemas.Edge
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bd_dep_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    root = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root, update, nil)

    {:ok, a, _} = Issue.create(root, %{title: "A"}, store)
    {:ok, b, _} = Issue.create(root, %{title: "B"}, store)

    %{store: store, root: root, a: a.id, b: b.id}
  end

  test "add + list", ctx do
    {:ok, _} = Dep.add(ctx.root, ctx.a, ctx.b, "blocks", %{}, ctx.store)
    edges = Dep.list(ctx.root, ctx.store)
    assert length(edges) == 1
    e = hd(edges)
    assert e.from == ctx.a
    assert e.to == ctx.b
    assert e.kind == "blocks"
  end

  test "add is idempotent on (from, to, kind)", ctx do
    {:ok, _} = Dep.add(ctx.root, ctx.a, ctx.b, "blocks", %{}, ctx.store)
    {:ok, _} = Dep.add(ctx.root, ctx.a, ctx.b, "blocks", %{}, ctx.store)
    assert length(Dep.list(ctx.root, ctx.store)) == 1
  end

  test "remove drops the edge", ctx do
    {:ok, _} = Dep.add(ctx.root, ctx.a, ctx.b, "blocks", %{}, ctx.store)
    :ok = Dep.remove(ctx.root, ctx.a, ctx.b, "blocks", ctx.store)
    assert Dep.list(ctx.root, ctx.store) == []
  end

  test "incoming/outgoing filter by direction", ctx do
    {:ok, _} = Dep.add(ctx.root, ctx.a, ctx.b, "blocks", %{}, ctx.store)
    assert [e] = Dep.incoming(ctx.root, ctx.b, "blocks", ctx.store)
    assert e.from == ctx.a
    assert [_] = Dep.outgoing(ctx.root, ctx.a, "blocks", ctx.store)
    assert Dep.outgoing(ctx.root, ctx.b, "blocks", ctx.store) == []
  end

  # Spec §5.4: add + remove same edge sequentially — later wins.
  # In the JSON-backed P1 surface, "later" is the literal call order;
  # the YMap-LWW-by-Lamport-tiebreaker semantics live in the substrate
  # path and get exercised once title/description lift to YMap content.
  test "sequential add → remove → add ends with edge present", ctx do
    {:ok, _} = Dep.add(ctx.root, ctx.a, ctx.b, "blocks", %{}, ctx.store)
    :ok = Dep.remove(ctx.root, ctx.a, ctx.b, "blocks", ctx.store)
    {:ok, _} = Dep.add(ctx.root, ctx.a, ctx.b, "blocks", %{}, ctx.store)

    assert [%Edge{from: from, to: to}] = Dep.list(ctx.root, ctx.store)
    assert {from, to} == {ctx.a, ctx.b}
  end
end
