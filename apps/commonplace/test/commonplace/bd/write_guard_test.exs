defmodule Commonplace.Bd.WriteGuardTest do
  @moduledoc """
  Slice S1 Part 3 — `Commonplace.Bd.WriteGuard`, the shared chokepoint
  every ticket-mutating verb funnels through: ref-type shape checks on
  `needs`/`done_witness`/`claimed_by`, protected-field enforcement
  (`status`/`done_witness`/`claimed_by` gate-exclusive unless `allow`d),
  and the cycle gate on growing `needs`.
  """
  use ExUnit.Case

  alias Commonplace.Bd.{Issue, WriteGuard}
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Yelixer.Encoding

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_bd_write_guard_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    store = :"commit_store_#{:rand.uniform(1_000_000)}"
    start_supervised!({CommitStore, data_dir: dir, name: store})
    on_exit(fn -> File.rm_rf!(dir) end)

    root = UUID.uuid4()
    update = Encoding.encode_update(Schema.new_schema())
    CommitStore.create_commit(store, root, update, nil)

    %{store: store, root: root}
  end

  describe "cycle gate" do
    test "a valid DAG edge (A needs B, no prior edges) is accepted", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      {:ok, b, _} = Issue.create(ctx.root, %{title: "B"}, ctx.store)

      new_needs = [%{"ticket" => b.id}]
      assert :ok = WriteGuard.check(a, %{needs: new_needs}, ctx.root, ctx.store, allow: [])
    end

    test "building A needs B then B needs A is refused (direct cycle)", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      {:ok, b, _} = Issue.create(ctx.root, %{title: "B"}, ctx.store)

      {:ok, a} = Issue.update(ctx.root, a.id, %{needs: [%{"ticket" => b.id}]}, ctx.store)

      assert {:error, reason} =
               WriteGuard.check(b, %{needs: [%{"ticket" => a.id}]}, ctx.root, ctx.store, allow: [])

      assert reason =~ "cycle"
    end

    test "a longer loop back to the dependent is refused (A needs B, B needs C, then C needs A)", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      {:ok, b, _} = Issue.create(ctx.root, %{title: "B"}, ctx.store)
      {:ok, c, _} = Issue.create(ctx.root, %{title: "C"}, ctx.store)

      {:ok, _} = Issue.update(ctx.root, a.id, %{needs: [%{"ticket" => b.id}]}, ctx.store)
      {:ok, _} = Issue.update(ctx.root, b.id, %{needs: [%{"ticket" => c.id}]}, ctx.store)

      assert {:error, reason} =
               WriteGuard.check(c, %{needs: [%{"ticket" => a.id}]}, ctx.root, ctx.store, allow: [])

      assert reason =~ "cycle"
    end

    test "a cross-repo-leaf prereq is NOT walked, so it can't spuriously refuse", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      # A "needs" a ticket in another repo — not walkable locally, so
      # even though we can't prove it's cycle-free, it must not refuse.
      new_needs = [%{"ticket" => a.id, "repo" => "other-repo-trust-root"}]
      assert :ok = WriteGuard.check(a, %{needs: new_needs}, ctx.root, ctx.store, allow: [])
    end

    # cp-plan ⛩ required fix: a `"repo"` naming the LOCAL root is a
    # self-repo ref — semantically local, but the cross-repo-leaf
    # classification would skip the cycle walk for it, a gate bypass
    # anyone can reach by naming their own repo. It's refused at the
    # ref-FORM layer (before the walk is even relevant).
    test "a self-repo-form entry (repo == local root) is refused", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      {:ok, b, _} = Issue.create(ctx.root, %{title: "B"}, ctx.store)

      assert {:error, reason} =
               WriteGuard.check(
                 a,
                 %{needs: [%{"ticket" => b.id, "repo" => ctx.root}]},
                 ctx.root,
                 ctx.store,
                 allow: []
               )

      assert reason =~ "self-repo"
    end

    test "the would-be bypass: a self-repo-form edge that WOULD close a cycle is refused by the form rule, not silently walked past",
         ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      {:ok, b, _} = Issue.create(ctx.root, %{title: "B"}, ctx.store)

      # A already needs B (local form).
      {:ok, _} = Issue.update(ctx.root, a.id, %{needs: [%{"ticket" => b.id}]}, ctx.store)

      # Now B tries to need A via the SELF-REPO form. If the form rule
      # weren't there, the "repo" key would classify this as a
      # cross-repo leaf, skip the walk, and let the B→A edge land —
      # closing the A→B, B→A cycle. The form rule refuses it first, so
      # the bypass is impossible; the error is the self-repo form error,
      # NOT the cycle error (proving the form rule fires before the walk).
      assert {:error, reason} =
               WriteGuard.check(
                 b,
                 %{needs: [%{"ticket" => a.id, "repo" => ctx.root}]},
                 ctx.root,
                 ctx.store,
                 allow: []
               )

      assert reason =~ "self-repo"
      refute reason =~ "cycle"
    end
  end

  describe "ref-type violations" do
    test "malformed needs entry: missing ticket key is refused", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      assert {:error, _} =
               WriteGuard.check(a, %{needs: [%{"nope" => "x"}]}, ctx.root, ctx.store, allow: [])
    end

    test "malformed needs entry: non-string ticket is refused", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      assert {:error, _} =
               WriteGuard.check(a, %{needs: [%{"ticket" => 123}]}, ctx.root, ctx.store, allow: [])
    end

    test "malformed needs entry: extra keys are refused", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      assert {:error, _} =
               WriteGuard.check(
                 a,
                 %{needs: [%{"ticket" => "CX-2", "extra" => "nope"}]},
                 ctx.root,
                 ctx.store,
                 allow: []
               )
    end

    test "malformed done_witness: non-hex string is refused", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      assert {:error, _} =
               WriteGuard.check(
                 a,
                 %{done_witness: ["not-hex!"]},
                 ctx.root,
                 ctx.store,
                 allow: [:done_witness]
               )
    end

    test "well-formed done_witness passes ref-type check", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      assert :ok =
               WriteGuard.check(
                 a,
                 %{done_witness: ["deadbeef", "cafe1234"]},
                 ctx.root,
                 ctx.store,
                 allow: [:done_witness]
               )
    end

    test "malformed claimed_by: no @ is refused", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      assert {:error, _} =
               WriteGuard.check(
                 a,
                 %{claimed_by: "no-at-sign"},
                 ctx.root,
                 ctx.store,
                 allow: [:claimed_by]
               )
    end

    test "well-formed claimed_by passes ref-type check", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      assert :ok =
               WriteGuard.check(
                 a,
                 %{claimed_by: "identity-uuid@pubkeyhex"},
                 ctx.root,
                 ctx.store,
                 allow: [:claimed_by]
               )
    end
  end

  describe "protected-field enforcement" do
    test "status write is refused without allow", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      assert {:error, reason} =
               WriteGuard.check(a, %{status: "closed"}, ctx.root, ctx.store, allow: [])

      assert reason =~ "status"
    end

    test "status write succeeds when allowed", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      assert :ok = WriteGuard.check(a, %{status: "closed"}, ctx.root, ctx.store, allow: [:status])
    end

    test "done_witness write is refused without allow", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      assert {:error, _} =
               WriteGuard.check(a, %{done_witness: ["deadbeef"]}, ctx.root, ctx.store, allow: [])
    end

    test "claimed_by write is refused without allow", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      assert {:error, _} =
               WriteGuard.check(
                 a,
                 %{claimed_by: "identity@pub"},
                 ctx.root,
                 ctx.store,
                 allow: []
               )
    end

    test "freely-writable fields (title, priority, needs, legacy_id) succeed with allow: []", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      assert :ok =
               WriteGuard.check(
                 a,
                 %{title: "new title", priority: "p0", legacy_id: "old-1"},
                 ctx.root,
                 ctx.store,
                 allow: []
               )
    end
  end
end
