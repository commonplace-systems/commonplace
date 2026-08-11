defmodule Commonplace.Bd.TicketVerbsTest do
  @moduledoc """
  Slice S1 Part 4 — the `ticket_add_needs` / `ticket_update`
  `ViewActionDispatch` verbs that exercise `Commonplace.Bd.WriteGuard`.

  Fixture setup mirrors `Commonplace.PrRefreshPreviewTest` — the
  dispatcher's handlers talk to the default-named `CommitStore` via
  `CommitStoreClient`, so this needs the same "root pointer file +
  running default CommitStore" fixture, not a custom-named store the
  dispatcher singleton can't see.
  """
  use ExUnit.Case, async: false

  alias Commonplace.Bd.Issue
  alias Commonplace.Crypto.Signing
  alias Commonplace.Crypto.SigningContext
  alias Commonplace.Store.CommitStore
  alias Commonplace.Tree.Schema
  alias Commonplace.ViewActionDispatch

  setup do
    dir = Path.join(System.tmp_dir!(), "cp_ticket_verbs_test_#{:rand.uniform(1_000_000_000)}")
    File.mkdir_p!(dir)
    prior_data_dir = Application.get_env(:commonplace, :data_dir)
    Application.put_env(:commonplace, :data_dir, dir)

    sup = Commonplace.Store.CommitStoreSupervisor
    _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
    _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)

    {:ok, _pid} =
      Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: dir})

    root_uuid = UUID.uuid4()
    root_doc = Schema.new_schema()
    update = Yelixer.Encoding.encode_update(root_doc)
    CommitStore.create_commit(Commonplace.Store.CommitStore, root_uuid, update, nil)

    Commonplace.Test.WorkspaceFixture.complete_workspace!(dir,
      store: Commonplace.Store.CommitStore
    )

    File.write!(Path.join(dir, "root"), root_uuid)

    on_exit(fn ->
      _ = Supervisor.terminate_child(sup, Commonplace.Store.CommitStore)
      _ = Supervisor.delete_child(sup, Commonplace.Store.CommitStore)
      restored_data_dir = prior_data_dir || "tmp/test_data"
      Application.put_env(:commonplace, :data_dir, restored_data_dir)
      File.rm_rf!(dir)

      {:ok, restored_pid} =
        Supervisor.start_child(sup, {Commonplace.Store.CommitStore, data_dir: restored_data_dir})

      assert Process.alive?(restored_pid)
      assert Process.whereis(Commonplace.Store.CommitStore) == restored_pid

      assert CubDB.data_dir(CommitStore.db_handle(CommitStore)) ==
               Path.join(restored_data_dir, "commits")
    end)

    {pub, priv} = Signing.generate_keypair()

    signing_context = %SigningContext{
      identity_uuid: "test-ticket-verb-invoker",
      private_key: priv,
      public_key: pub
    }

    %{root: root_uuid, signing_context: signing_context}
  end

  defp create_ticket(root_uuid, title) do
    {:ok, issue, _dir} = Issue.create(root_uuid, %{title: title})
    issue
  end

  defp import_ticket(root_uuid, status, ctx) do
    id = "CX-s5v2#{System.unique_integer([:positive])}"

    assert {:ok, :tree_mutation, %{landed: [%{id: ^id}]}} =
             ViewActionDispatch.dispatch("ticket_import", %{
               args: %{
                 "records" => [
                   %{
                     "id" => id,
                     "title" => "S5v2 #{status}",
                     "status" => status,
                     "priority" => 2,
                     "issue_type" => "task"
                   }
                 ]
               },
               root_uuid: root_uuid,
               signing_context: ctx,
               source: "test"
             })

    {:ok, issue} = Issue.show(root_uuid, id)
    issue
  end

  defp set_status(ticket_id, status, reason, ctx) do
    ViewActionDispatch.dispatch("ticket_set_status", %{
      args: %{
        "ticket" => ticket_id,
        "status" => status,
        "reason" => reason,
        "actor" => "client-supplied-and-ignored"
      },
      signing_context: ctx,
      source: "test"
    })
  end

  defp close_ticket(ticket_id, ctx) do
    ViewActionDispatch.dispatch("ticket_close", %{
      args: %{"ticket" => ticket_id, "witnesses" => []},
      signing_context: ctx,
      source: "test"
    })
  end

  describe "ticket_add_needs" do
    test "adds a well-formed local prereq ref", %{root: root, signing_context: ctx} do
      a = create_ticket(root, "A")
      b = create_ticket(root, "B")

      context = %{
        args: %{"ticket" => a.id, "needs_ticket" => b.id},
        signing_context: ctx,
        source: "test"
      }

      assert {:ok, :tree_mutation, details} =
               ViewActionDispatch.dispatch("ticket_add_needs", context)

      assert details.action == "ticket_add_needs"
      assert details.needs == [%{"ticket" => b.id}]

      {:ok, reloaded} = Issue.show(root, a.id)
      assert reloaded.needs == [%{"ticket" => b.id}]
    end

    test "refuses a cycle: A needs B, then B needs A", %{root: root, signing_context: ctx} do
      a = create_ticket(root, "A")
      b = create_ticket(root, "B")

      {:ok, :tree_mutation, _} =
        ViewActionDispatch.dispatch("ticket_add_needs", %{
          args: %{"ticket" => a.id, "needs_ticket" => b.id},
          signing_context: ctx,
          source: "test"
        })

      assert {:error, reason} =
               ViewActionDispatch.dispatch("ticket_add_needs", %{
                 args: %{"ticket" => b.id, "needs_ticket" => a.id},
                 signing_context: ctx,
                 source: "test"
               })

      assert reason =~ "cycle"

      {:ok, b_reloaded} = Issue.show(root, b.id)
      assert b_reloaded.needs == []
    end

    test "accepts a cross-repo-leaf prereq without walking it", %{
      root: root,
      signing_context: ctx
    } do
      a = create_ticket(root, "A")

      context = %{
        args: %{"ticket" => a.id, "needs_ticket" => a.id, "needs_repo" => "other-repo-root"},
        signing_context: ctx,
        source: "test"
      }

      assert {:ok, :tree_mutation, _details} =
               ViewActionDispatch.dispatch("ticket_add_needs", context)

      {:ok, reloaded} = Issue.show(root, a.id)
      assert reloaded.needs == [%{"ticket" => a.id, "repo" => "other-repo-root"}]
    end

    test "unknown ticket is refused", %{root: _root, signing_context: ctx} do
      context = %{
        args: %{"ticket" => "CX-nope", "needs_ticket" => "CX-alsono"},
        signing_context: ctx,
        source: "test"
      }

      assert {:error, _reason} = ViewActionDispatch.dispatch("ticket_add_needs", context)
    end
  end

  describe "ticket_update" do
    test "refuses description instead of silently dropping it", %{
      root: root,
      signing_context: ctx
    } do
      ticket = create_ticket(root, "A")

      context = %{
        args: %{"ticket" => ticket.id, "changes" => %{"description" => "x"}},
        signing_context: ctx,
        source: "test"
      }

      assert {:error, reason} = ViewActionDispatch.dispatch("ticket_update", context)
      assert reason =~ "description"
      assert reason =~ "Bd.Issue.write_description/5"
      assert {:ok, ""} = Issue.description(root, ticket.id)
    end

    test "refuses a mixed valid and unknown change without applying either", %{
      root: root,
      signing_context: ctx
    } do
      ticket = create_ticket(root, "original")

      context = %{
        args: %{
          "ticket" => ticket.id,
          "changes" => %{"title" => "renamed", "description" => "x", "mystery" => true}
        },
        signing_context: ctx,
        source: "test"
      }

      assert {:error, reason} = ViewActionDispatch.dispatch("ticket_update", context)
      assert reason =~ "description"
      assert reason =~ "mystery"
      assert reason =~ "Updatable fields: title, priority"

      {:ok, reloaded} = Issue.show(root, ticket.id)
      assert reloaded.title == "original"
      assert {:ok, ""} = Issue.description(root, ticket.id)
    end

    test "refuses a change touching status", %{root: root, signing_context: ctx} do
      a = create_ticket(root, "A")

      context = %{
        args: %{"ticket" => a.id, "changes" => %{"status" => "closed"}},
        signing_context: ctx,
        source: "test"
      }

      assert {:error, reason} = ViewActionDispatch.dispatch("ticket_update", context)
      assert reason =~ "status"
      assert reason =~ "ticket_close"

      {:ok, reloaded} = Issue.show(root, a.id)
      assert reloaded.status == "open"
    end

    test "refuses a change touching done_witness", %{root: root, signing_context: ctx} do
      a = create_ticket(root, "A")

      context = %{
        args: %{"ticket" => a.id, "changes" => %{"done_witness" => ["deadbeef"]}},
        signing_context: ctx,
        source: "test"
      }

      assert {:error, _reason} = ViewActionDispatch.dispatch("ticket_update", context)
    end

    test "refuses a change touching claimed_by", %{root: root, signing_context: ctx} do
      a = create_ticket(root, "A")

      context = %{
        args: %{"ticket" => a.id, "changes" => %{"claimed_by" => "id@pub"}},
        signing_context: ctx,
        source: "test"
      }

      assert {:error, _reason} = ViewActionDispatch.dispatch("ticket_update", context)
    end

    test "succeeds for title/priority changes", %{root: root, signing_context: ctx} do
      a = create_ticket(root, "A")

      context = %{
        args: %{"ticket" => a.id, "changes" => %{"title" => "renamed", "priority" => "p0"}},
        signing_context: ctx,
        source: "test"
      }

      assert {:ok, :tree_mutation, details} =
               ViewActionDispatch.dispatch("ticket_update", context)

      assert details.action == "ticket_update"

      {:ok, reloaded} = Issue.show(root, a.id)
      assert reloaded.title == "renamed"
      assert reloaded.priority == "p0"
    end
  end

  describe "ticket_close" do
    test "persists the optional reason through the atomic close", %{
      root: root,
      signing_context: ctx
    } do
      ticket = create_ticket(root, "reasoned close")
      reason = "the acceptance evidence is complete"

      assert {:ok, :tree_mutation, %{status: "closed"}} =
               ViewActionDispatch.dispatch("ticket_close", %{
                 args: %{"ticket" => ticket.id, "reason" => reason},
                 signing_context: ctx,
                 source: "test"
               })

      assert {:ok, reloaded} = Issue.show(root, ticket.id)
      assert reloaded.closed_reason == reason
    end

    test "refuses all unknown args before closing", %{root: root, signing_context: ctx} do
      ticket = create_ticket(root, "typo must not close")

      assert {:error,
              "ticket_close refuses unknown argument keys: \"foo\", \"resaon\". " <>
                "Accepted keys: ticket, witnesses, reason."} =
               ViewActionDispatch.dispatch("ticket_close", %{
                 args: %{
                   "ticket" => ticket.id,
                   "reason" => "would otherwise close",
                   "resaon" => "typo",
                   "foo" => true
                 },
                 signing_context: ctx,
                 source: "test"
               })

      assert {:ok, reloaded} = Issue.show(root, ticket.id)
      assert reloaded.status == "open"
      assert reloaded.closed_reason == nil
    end

    test "ticket-only close retains the existing result and nil reason", %{
      root: root,
      signing_context: ctx
    } do
      ticket = create_ticket(root, "reasonless close")

      assert {:ok, :tree_mutation, details} =
               ViewActionDispatch.dispatch("ticket_close", %{
                 args: %{"ticket" => ticket.id},
                 signing_context: ctx,
                 source: "test"
               })

      assert details == %{
               action: "ticket_close",
               ticket: ticket.id,
               status: "closed",
               done_witness: []
             }

      assert {:ok, reloaded} = Issue.show(root, ticket.id)
      assert reloaded.closed_reason == nil
    end
  end

  describe "ticket_set_status" do
    test "the closed-ticket transition path has no bare WriteGuard bypass" do
      source =
        "../../../lib/commonplace/view_action_dispatch.ex"
        |> Path.expand(__DIR__)
        |> File.read!()

      refute source =~
               ~r/defp status_transition_write_guard\(\s*%Commonplace\.Bd\.Schemas\.Issue\{status: "closed"\}/
    end

    test "import-minted in_progress exits through a decision and can then close", %{
      root: root,
      signing_context: ctx
    } do
      ticket = import_ticket(root, "in_progress", ctx)

      assert {:error, "ticket is not open"} = close_ticket(ticket.id, ctx)

      assert {:ok, :tree_mutation, details} =
               set_status(ticket.id, "open", "normalize imported custody artifact", ctx)

      assert details.action == "ticket_set_status"
      assert details.from == "in_progress"
      assert details.status == "open"

      assert {:ok, :tree_mutation, %{status: "closed"}} = close_ticket(ticket.id, ctx)

      {:ok, reloaded} = Issue.show(root, ticket.id)
      assert reloaded.status == "closed"
    end

    test "every named decision edge executes and records server actor plus reason", %{
      root: root,
      signing_context: ctx
    } do
      actor = Signing.signer_id(ctx.identity_uuid, ctx.public_key)

      for from <- ~w(open in_progress blocked review),
          to <- ~w(open blocked review wontfix) do
        ticket = import_ticket(root, from, ctx)
        reason = "decide #{from} to #{to}"

        assert {:ok, :tree_mutation, %{decision: "decision", from: ^from, status: ^to}} =
                 set_status(ticket.id, to, reason, ctx)

        {:ok, reloaded} = Issue.show(root, ticket.id)
        assert reloaded.status == to

        assert List.last(reloaded.extra["status_decisions"]) == %{
                 "type" => "DECISION",
                 "name" => "decision",
                 "from" => from,
                 "to" => to,
                 "actor" => actor,
                 "reason" => reason,
                 "at" => List.last(reloaded.extra["status_decisions"])["at"]
               }
      end
    end

    test "closed and wontfix reopen only to open and record reopen-with-reason", %{
      root: root,
      signing_context: ctx
    } do
      actor = Signing.signer_id(ctx.identity_uuid, ctx.public_key)

      for from <- ~w(closed wontfix) do
        ticket = import_ticket(root, from, ctx)
        reason = "reopen #{from}"

        assert {:ok, :tree_mutation,
                %{decision: "reopen-with-reason", from: ^from, status: "open"}} =
                 set_status(ticket.id, "open", reason, ctx)

        {:ok, reopened} = Issue.show(root, ticket.id)

        assert %{
                 "type" => "DECISION",
                 "name" => "reopen-with-reason",
                 "from" => ^from,
                 "to" => "open",
                 "actor" => ^actor,
                 "reason" => ^reason
               } = List.last(reopened.extra["status_decisions"])

        assert {:ok, :tree_mutation, %{status: "closed"}} = close_ticket(ticket.id, ctx)
      end
    end

    test "in_progress has no inbound edge from any valid state", %{
      root: root,
      signing_context: ctx
    } do
      for from <- ~w(open in_progress blocked review closed wontfix) do
        ticket = import_ticket(root, from, ctx)

        assert {:error, reason} = set_status(ticket.id, "in_progress", "try inbound", ctx)

        assert reason ==
                 "ticket_set_status refuses transition from #{inspect(from)} to \"in_progress\": " <>
                   "in_progress is EXIT-ONLY and has no inbound edges; custody is represented by the claim token; " <>
                   "legal targets from #{from}: #{legal_targets_text(from)}"

        {:ok, unchanged} = Issue.show(root, ticket.id)
        assert unchanged.status == from
      end
    end

    test "non-closed to closed points at ticket_close and all other unnamed edges name the legal set",
         %{
           root: root,
           signing_context: ctx
         } do
      ticket = import_ticket(root, "blocked", ctx)

      assert {:error,
              "ticket_set_status refuses transition from \"blocked\" to \"closed\": " <>
                "use ticket_close; closed keeps one door and ticket_close requires status open; " <>
                "legal targets from blocked: open, blocked, review, wontfix"} =
               set_status(ticket.id, "closed", "skip close gate", ctx)

      closed = import_ticket(root, "closed", ctx)

      assert {:error,
              "ticket_set_status refuses transition from \"closed\" to \"review\": " <>
                "the transition is not named in the closed-by-default table; " <>
                "legal targets from closed: open"} =
               set_status(closed.id, "review", "unnamed", ctx)
    end

    test "missing, empty, and whitespace-only reasons refuse without a write", %{
      root: root,
      signing_context: ctx
    } do
      ticket = import_ticket(root, "review", ctx)

      for reason <- [nil, "", "   "] do
        assert {:error, "ticket_set_status requires a non-empty reason"} =
                 set_status(ticket.id, "open", reason, ctx)
      end

      {:ok, unchanged} = Issue.show(root, ticket.id)
      assert unchanged.status == "review"
      assert unchanged.extra["status_decisions"] == nil
    end
  end

  defp legal_targets_text(from) when from in ~w(open in_progress blocked review),
    do: "open, blocked, review, wontfix"

  defp legal_targets_text(from) when from in ~w(closed wontfix), do: "open"
end
