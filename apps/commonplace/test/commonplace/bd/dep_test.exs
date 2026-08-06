defmodule Commonplace.Bd.DepTest do
  @moduledoc """
  CX-hrbn: `/bd/deps.json` — the P1 `blocks` graph — was retired at the
  tix-authority cutover (2026-08-05). Nothing writes it any more, so
  every read of it is frozen data answered as if it were current: the
  silent-underreport trap the design's §8 ruling (condition 4) says to
  close by retiring, repointing, or refusing loudly.

  `Commonplace.Bd.Dep` takes the third option. These tests pin that the
  refusal is LOUD — it raises, and the message names both the
  retirement and the live replacement. The load-bearing negative is
  that it must never return `[]`: an empty list is exactly what a
  frozen-and-cleared graph would look like, and a caller cannot tell
  the two apart.
  """
  use ExUnit.Case

  alias Commonplace.Bd.{Dep, Issue}
  alias Commonplace.Bd.RetiredGraphError
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

  describe "the read surface refuses loudly" do
    test "list/2 raises rather than answering from the frozen graph", ctx do
      err = assert_raise(RetiredGraphError, fn -> Dep.list(ctx.root, ctx.store) end)
      assert_names_retirement_and_replacement(err)
    end

    test "incoming/4 raises", ctx do
      err =
        assert_raise(RetiredGraphError, fn ->
          Dep.incoming(ctx.root, ctx.b, "blocks", ctx.store)
        end)

      assert_names_retirement_and_replacement(err)
    end

    test "outgoing/4 raises", ctx do
      err =
        assert_raise(RetiredGraphError, fn ->
          Dep.outgoing(ctx.root, ctx.a, "blocks", ctx.store)
        end)

      assert_names_retirement_and_replacement(err)
    end

    # The control. Every other assertion here would also pass if the
    # functions had simply been made to return `[]` on an empty store;
    # this one pins the distinction that motivated the change. `[]` is
    # indistinguishable from "the graph is live and has no edges",
    # which is precisely the misreport.
    test "no read surface returns an empty list", ctx do
      for f <- [
            fn -> Dep.list(ctx.root, ctx.store) end,
            fn -> Dep.incoming(ctx.root, ctx.b, "blocks", ctx.store) end,
            fn -> Dep.outgoing(ctx.root, ctx.a, "blocks", ctx.store) end
          ] do
        assert catch_error(f.()).__struct__ == RetiredGraphError
      end
    end
  end

  describe "the write surface refuses loudly" do
    test "add/6 raises and points at the gated verb", ctx do
      err =
        assert_raise(RetiredGraphError, fn ->
          Dep.add(ctx.root, ctx.a, ctx.b, "blocks", %{}, ctx.store)
        end)

      assert_names_retirement_and_replacement(err)
      assert Exception.message(err) =~ "ticket_add_needs"
    end

    test "remove/5 raises", ctx do
      err =
        assert_raise(RetiredGraphError, fn ->
          Dep.remove(ctx.root, ctx.a, ctx.b, "blocks", ctx.store)
        end)

      assert_names_retirement_and_replacement(err)
    end

    # A refusal that silently succeeded would be worse than the frozen
    # read: it would look like the graph still works.
    test "a refused write is not followed by a readable graph", ctx do
      assert_raise(RetiredGraphError, fn ->
        Dep.add(ctx.root, ctx.a, ctx.b, "blocks", %{}, ctx.store)
      end)

      assert_raise(RetiredGraphError, fn -> Dep.list(ctx.root, ctx.store) end)
    end
  end

  defp assert_names_retirement_and_replacement(err) do
    msg = Exception.message(err)

    # Names the retirement, with the date, so the reader can find the
    # cutover rather than guessing at a bug.
    assert msg =~ "RETIRED"
    assert msg =~ "2026-08-05"
    assert msg =~ "/bd/deps.json"

    # Names where the live answer lives.
    assert msg =~ "needs"
    assert msg =~ "Frontier"
  end
end
