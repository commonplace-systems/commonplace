defmodule Commonplace.Bd.FrontierTest do
  use ExUnit.Case

  alias Commonplace.Bd.{Frontier, Issue, Ready}
  alias Commonplace.Bd.RetiredGraphError
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bd_frontier_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_frontier_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    root = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root, update, nil)

    %{store: store, root: root}
  end

  defp needs_ticket(id), do: %{"ticket" => id}
  defp needs_repo(repo), do: %{"ticket" => "some-id", "repo" => repo}

  test "satisfied set: needs pointing at closed or wontfix is satisfied", ctx do
    {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
    {:ok, b, _} = Issue.create(ctx.root, %{title: "B", needs: [needs_ticket(a.id)]}, ctx.store)
    {:ok, c, _} = Issue.create(ctx.root, %{title: "C"}, ctx.store)
    {:ok, d, _} = Issue.create(ctx.root, %{title: "D", needs: [needs_ticket(c.id)]}, ctx.store)

    {:ok, _} = Issue.update(ctx.root, a.id, %{status: "closed"}, ctx.store)
    {:ok, _} = Issue.update(ctx.root, c.id, %{status: "wontfix"}, ctx.store)

    ready_ids = Frontier.ready_walk(ctx.root, ctx.store) |> Enum.map(& &1.id)
    assert b.id in ready_ids
    assert d.id in ready_ids
  end

  test "open needs entry is NOT satisfied", ctx do
    {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
    {:ok, b, _} = Issue.create(ctx.root, %{title: "B", needs: [needs_ticket(a.id)]}, ctx.store)

    blocked_ids = Frontier.blocked_walk(ctx.root, ctx.store) |> Enum.map(& &1.id)
    ready_ids = Frontier.ready_walk(ctx.root, ctx.store) |> Enum.map(& &1.id)

    assert b.id in blocked_ids
    refute b.id in ready_ids
  end

  test "unresolvable local-id needs entry blocks (S2 inversion)", ctx do
    {:ok, b, _} =
      Issue.create(ctx.root, %{title: "B", needs: [needs_ticket("CX-doesnotexist")]}, ctx.store)

    blocked_ids = Frontier.blocked_walk(ctx.root, ctx.store) |> Enum.map(& &1.id)
    ready_ids = Frontier.ready_walk(ctx.root, ctx.store) |> Enum.map(& &1.id)

    assert b.id in blocked_ids
    refute b.id in ready_ids
  end

  test "cross-repo needs entry blocks (S2 inversion)", ctx do
    {:ok, b, _} =
      Issue.create(ctx.root, %{title: "B", needs: [needs_repo("some-other-repo")]}, ctx.store)

    blocked_ids = Frontier.blocked_walk(ctx.root, ctx.store) |> Enum.map(& &1.id)
    ready_ids = Frontier.ready_walk(ctx.root, ctx.store) |> Enum.map(& &1.id)

    assert b.id in blocked_ids
    refute b.id in ready_ids
  end

  # Contrast pin, rewritten at the CX-hrbn retirement. This USED to
  # assert that P1 `Bd.Ready` calls the same ticket ready — its
  # unknown-blocker-is-satisfied rule saw no `blocks` edge and said
  # "go" — while Frontier's needs-walk calls it blocked. That inversion
  # is exactly why Ready could not simply be left running next to
  # Frontier: two oracles, opposite answers, one of them reading a
  # graph nothing writes.
  #
  # So the pin now holds the resolution rather than the disagreement:
  # Frontier still calls it blocked, and Ready no longer answers at
  # all. The refusal is the load-bearing half — a Ready that quietly
  # returned `[]` here would look like agreement.
  test "inversion is resolved: Frontier calls it blocked, Ready refuses to answer", ctx do
    {:ok, b, _} =
      Issue.create(ctx.root, %{title: "B", needs: [needs_ticket("CX-doesnotexist")]}, ctx.store)

    ready_under_frontier = Frontier.ready_walk(ctx.root, ctx.store) |> Enum.map(& &1.id)
    refute b.id in ready_under_frontier
    assert b.id in (Frontier.blocked_walk(ctx.root, ctx.store) |> Enum.map(& &1.id))

    err = assert_raise(RetiredGraphError, fn -> Ready.ready(ctx.root, ctx.store) end)
    assert Exception.message(err) =~ "RETIRED"
    assert Exception.message(err) =~ "Frontier"
  end

  test "diamond dedup: D needs A and B, A needs C, B needs C", ctx do
    {:ok, c, _} = Issue.create(ctx.root, %{title: "C"}, ctx.store)
    {:ok, a, _} = Issue.create(ctx.root, %{title: "A", needs: [needs_ticket(c.id)]}, ctx.store)
    {:ok, b, _} = Issue.create(ctx.root, %{title: "B", needs: [needs_ticket(c.id)]}, ctx.store)

    {:ok, d, _} =
      Issue.create(
        ctx.root,
        %{title: "D", needs: [needs_ticket(a.id), needs_ticket(b.id)]},
        ctx.store
      )

    ready0 = Frontier.ready_walk(ctx.root, ctx.store) |> Enum.map(& &1.id)
    assert ready0 == [c.id]

    {:ok, _} = Issue.update(ctx.root, c.id, %{status: "closed"}, ctx.store)

    ready1 = Frontier.ready_walk(ctx.root, ctx.store) |> Enum.map(& &1.id) |> Enum.sort()
    assert ready1 == Enum.sort([a.id, b.id])
    refute d.id in ready1

    {:ok, _} = Issue.update(ctx.root, a.id, %{status: "closed"}, ctx.store)
    {:ok, _} = Issue.update(ctx.root, b.id, %{status: "closed"}, ctx.store)

    ready2 = Frontier.ready_walk(ctx.root, ctx.store) |> Enum.map(& &1.id)
    assert ready2 == [d.id]
  end

  test "compute/2 returns MapSets of ids matching ready_walk/blocked_walk", ctx do
    {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
    {:ok, b, _} = Issue.create(ctx.root, %{title: "B", needs: [needs_ticket(a.id)]}, ctx.store)

    %{ready: ready, blocked: blocked} = Frontier.compute(ctx.root, ctx.store)

    assert ready == MapSet.new(Frontier.ready_walk(ctx.root, ctx.store) |> Enum.map(& &1.id))
    assert blocked == MapSet.new(Frontier.blocked_walk(ctx.root, ctx.store) |> Enum.map(& &1.id))
    assert a.id in ready
    assert b.id in blocked
  end

  test "stranded_components: healthy graph has none", ctx do
    {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
    {:ok, _b, _} = Issue.create(ctx.root, %{title: "B", needs: [needs_ticket(a.id)]}, ctx.store)

    assert Frontier.stranded_components(ctx.root, ctx.store) == []
  end

  test "stranded_components: component with only unresolvable refs is stranded", ctx do
    {:ok, x, _} =
      Issue.create(ctx.root, %{title: "X", needs: [needs_ticket("CX-ghost")]}, ctx.store)

    components = Frontier.stranded_components(ctx.root, ctx.store)
    assert length(components) == 1
    assert x.id in hd(components)
  end

  test "stranded_components: a two-cycle with no external ready entry is stranded", ctx do
    # p needs q, q needs p — a cycle formed after both exist. Build via
    # direct create + update since Issue.create needs both ids upfront.
    {:ok, p, _} = Issue.create(ctx.root, %{title: "P"}, ctx.store)
    {:ok, q, _} = Issue.create(ctx.root, %{title: "Q", needs: [needs_ticket(p.id)]}, ctx.store)
    {:ok, _} = Issue.update(ctx.root, p.id, %{needs: [needs_ticket(q.id)]}, ctx.store)

    components = Frontier.stranded_components(ctx.root, ctx.store)
    assert length(components) == 1
    comp = hd(components)
    assert p.id in comp and q.id in comp
  end
end
