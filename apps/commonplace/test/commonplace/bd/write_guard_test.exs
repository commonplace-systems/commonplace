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
               WriteGuard.check(b, %{needs: [%{"ticket" => a.id}]}, ctx.root, ctx.store,
                 allow: []
               )

      assert reason =~ "cycle"
    end

    test "a longer loop back to the dependent is refused (A needs B, B needs C, then C needs A)",
         ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      {:ok, b, _} = Issue.create(ctx.root, %{title: "B"}, ctx.store)
      {:ok, c, _} = Issue.create(ctx.root, %{title: "C"}, ctx.store)

      {:ok, _} = Issue.update(ctx.root, a.id, %{needs: [%{"ticket" => b.id}]}, ctx.store)
      {:ok, _} = Issue.update(ctx.root, b.id, %{needs: [%{"ticket" => c.id}]}, ctx.store)

      assert {:error, reason} =
               WriteGuard.check(c, %{needs: [%{"ticket" => a.id}]}, ctx.root, ctx.store,
                 allow: []
               )

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

    test "freely-writable fields (title, priority, needs, legacy_id) succeed with allow: []",
         ctx do
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

  describe "done_when shape validation (Bd P2 S3)" do
    test "\"manual\" is accepted", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      assert :ok =
               WriteGuard.check(a, %{done_when: "manual"}, ctx.root, ctx.store, allow: [])
    end

    test "a well-formed pr_merge map is accepted", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      assert :ok =
               WriteGuard.check(
                 a,
                 %{done_when: %{"type" => "pr_merge", "target" => UUID.uuid4()}},
                 ctx.root,
                 ctx.store,
                 allow: []
               )
    end

    test "a pr_merge map with extra keys is refused", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      assert {:error, _} =
               WriteGuard.check(
                 a,
                 %{done_when: %{"type" => "pr_merge", "target" => UUID.uuid4(), "extra" => "x"}},
                 ctx.root,
                 ctx.store,
                 allow: []
               )
    end

    test "a pr_merge map with an empty target is refused", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      assert {:error, _} =
               WriteGuard.check(
                 a,
                 %{done_when: %{"type" => "pr_merge", "target" => ""}},
                 ctx.root,
                 ctx.store,
                 allow: []
               )
    end

    test "an unknown done_when shape is refused", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      assert {:error, _} =
               WriteGuard.check(a, %{done_when: "auto"}, ctx.root, ctx.store, allow: [])

      assert {:error, _} =
               WriteGuard.check(
                 a,
                 %{done_when: %{"type" => "sign_off"}},
                 ctx.root,
                 ctx.store,
                 allow: []
               )
    end
  end

  describe "done_when monotonicity + param-immutability (Bd P2 S3)" do
    test "manual -> pr_merge (strengthen) is accepted", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      target = UUID.uuid4()

      assert :ok =
               WriteGuard.check(
                 a,
                 %{done_when: %{"type" => "pr_merge", "target" => target}},
                 ctx.root,
                 ctx.store,
                 allow: []
               )
    end

    test "pr_merge -> manual (downgrade) is refused", ctx do
      {:ok, a, _} =
        Issue.create(
          ctx.root,
          %{title: "A", done_when: %{"type" => "pr_merge", "target" => UUID.uuid4()}},
          ctx.store
        )

      assert {:error, reason} =
               WriteGuard.check(a, %{done_when: "manual"}, ctx.root, ctx.store, allow: [])

      assert reason =~ "downgrad"
    end

    test "pr_merge(target A) -> pr_merge(target B) (param change) is refused", ctx do
      target_a = UUID.uuid4()
      target_b = UUID.uuid4()

      {:ok, a, _} =
        Issue.create(
          ctx.root,
          %{title: "A", done_when: %{"type" => "pr_merge", "target" => target_a}},
          ctx.store
        )

      assert {:error, reason} =
               WriteGuard.check(
                 a,
                 %{done_when: %{"type" => "pr_merge", "target" => target_b}},
                 ctx.root,
                 ctx.store,
                 allow: []
               )

      assert reason =~ "params"
    end

    test "pr_merge(target A) -> pr_merge(target A) (no-op) is accepted", ctx do
      target = UUID.uuid4()

      {:ok, a, _} =
        Issue.create(
          ctx.root,
          %{title: "A", done_when: %{"type" => "pr_merge", "target" => target}},
          ctx.store
        )

      assert :ok =
               WriteGuard.check(
                 a,
                 %{done_when: %{"type" => "pr_merge", "target" => target}},
                 ctx.root,
                 ctx.store,
                 allow: []
               )
    end

    test "manual -> manual (no-op) is accepted", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      assert :ok = WriteGuard.check(a, %{done_when: "manual"}, ctx.root, ctx.store, allow: [])
    end
  end

  describe "post-close freeze (Bd P2 S3)" do
    test "the reopen option admits exactly one shape-validated closed-to-open decision", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      closed = %{a | status: "closed"}
      decision = reopen_decision()

      changes = %{
        status: "open",
        extra: Map.put(closed.extra, "status_decisions", [decision])
      }

      assert :ok =
               WriteGuard.check(closed, changes, ctx.root, ctx.store,
                 allow: [:status],
                 reopen: true
               )
    end

    test "the reopen option is a shape, not a token: smuggled deltas remain frozen", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      closed = %{a | status: "closed"}
      decision = reopen_decision()
      reopened_extra = Map.put(closed.extra, "status_decisions", [decision])

      smuggled_changes = [
        %{status: "open", extra: Map.put(reopened_extra, "rider", true)},
        %{status: "open", extra: Map.put(closed.extra, "status_decisions", [decision, decision])},
        %{status: "open", extra: reopened_extra, title: "riding title edit"},
        %{status: "review", extra: reopened_extra}
      ]

      for changes <- smuggled_changes do
        assert {:error, "field :status is frozen: ticket is closed; the one exit is ticket_set_status's closed→open reopen decision"} =
                 WriteGuard.check(closed, changes, ctx.root, ctx.store,
                   allow: [:status],
                   reopen: true
                 )
      end
    end

    test "the reopen option refuses malformed decision records", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      closed = %{a | status: "closed"}

      malformed = [
        Map.put(reopen_decision(), "name", "decision"),
        Map.put(reopen_decision(), "from", "wontfix"),
        Map.put(reopen_decision(), "to", "review"),
        Map.put(reopen_decision(), "actor", nil),
        Map.put(reopen_decision(), "reason", "  "),
        Map.put(reopen_decision(), "at", "not-a-timestamp"),
        Map.put(reopen_decision(), "rider", true)
      ]

      for decision <- malformed do
        changes = %{
          status: "open",
          extra: Map.put(closed.extra, "status_decisions", [decision])
        }

        assert {:error, "field :status is frozen: ticket is closed; the one exit is ticket_set_status's closed→open reopen decision"} =
                 WriteGuard.check(closed, changes, ctx.root, ctx.store,
                   allow: [:status],
                   reopen: true
                 )
      end
    end

    test "a closed ticket refuses a done_when write even with allow", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      closed = %{a | status: "closed"}

      assert {:error, reason} =
               WriteGuard.check(
                 closed,
                 %{done_when: %{"type" => "pr_merge", "target" => UUID.uuid4()}},
                 ctx.root,
                 ctx.store,
                 allow: [:done_when]
               )

      assert reason =~ "frozen"
    end

    test "a closed ticket refuses a done_witness write even with allow", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      closed = %{a | status: "closed"}

      assert {:error, reason} =
               WriteGuard.check(
                 closed,
                 %{done_witness: ["deadbeef"]},
                 ctx.root,
                 ctx.store,
                 allow: [:done_witness]
               )

      assert reason =~ "frozen"
    end

    test "a closed ticket refuses a status write even with allow", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      closed = %{a | status: "closed"}

      assert {:error, reason} =
               WriteGuard.check(closed, %{status: "open"}, ctx.root, ctx.store, allow: [:status])

      assert reason =~ "frozen"
    end

    test "a closed ticket still accepts unrelated field writes (e.g. title)", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)
      closed = %{a | status: "closed"}

      assert :ok =
               WriteGuard.check(closed, %{title: "renamed"}, ctx.root, ctx.store, allow: [])
    end

    test "an OPEN ticket is unaffected by the freeze (control)", ctx do
      {:ok, a, _} = Issue.create(ctx.root, %{title: "A"}, ctx.store)

      assert :ok =
               WriteGuard.check(a, %{status: "closed"}, ctx.root, ctx.store, allow: [:status])
    end
  end

  defp reopen_decision do
    %{
      "type" => "DECISION",
      "name" => "reopen-with-reason",
      "from" => "closed",
      "to" => "open",
      "actor" => "identity@pub",
      "reason" => "new evidence",
      "at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
